//
//  EventsMapTripLines.swift
//  Argus
//
//  Trip polylines for the events map: each trip (grouped by TripGrouper's
//  tripID) draws as a line through its events in drive order. Direction is
//  shown by opacity — translucent at the start of the drive, opaque at the
//  end — using one short polyline per leg, since a single MapPolyline can
//  only take one stroke style.
//  Search keywords: UI:map-trips, COLOR:map-trips, TUNING:map-trips
//

import SwiftUI
import MapKit

// MARK: - Builder (pure, testable)

/// One drawable trip: its events' coordinates in chronological order.
struct TripLine: Identifiable {
    let id: UUID // the trip's tripID
    let coordinates: [CLLocationCoordinate2D]
}

enum TripPolylineBuilder {
    /// TUNING: consecutive points closer than this (degrees, ~11 m) collapse
    /// into one — a parked Sentry session is a dot, not a drive.
    static let duplicateEpsilonDegrees = 0.0001

    /// Groups events by tripID (events without one are skipped), orders each
    /// group chronologically, collapses consecutive same-spot points, and
    /// keeps only trips left with 2+ distinct locations — a stack of Sentry
    /// events at one parking spot can't draw a line. Sorted by tripID for
    /// stable identity.
    static func tripLines(events: [Event]) -> [TripLine] {
        var groups: [UUID: [Event]] = [:]
        for event in events {
            guard let tripID = event.tripID else { continue }
            groups[tripID, default: []].append(event)
        }
        return groups.compactMap { tripID, members -> TripLine? in
            let coordinates = members
                .sorted { $0.timestamp < $1.timestamp }
                .compactMap { MarkerStyle.coordinate($0) }
            // Consecutive-only dedupe so loops (A → B → back to A) survive.
            var distinct: [CLLocationCoordinate2D] = []
            for coord in coordinates {
                if let last = distinct.last,
                   abs(last.latitude - coord.latitude) < duplicateEpsilonDegrees,
                   abs(last.longitude - coord.longitude) < duplicateEpsilonDegrees {
                    continue
                }
                distinct.append(coord)
            }
            guard distinct.count >= 2 else { return nil }
            return TripLine(id: tripID, coordinates: distinct)
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Splits a trip line into per-leg segments with opacity ramping from
    /// translucent (drive start) to opaque (drive end).
    static func segments(for line: TripLine) -> [TripSegment] {
        let legCount = line.coordinates.count - 1
        guard legCount >= 1 else { return [] }
        return (0..<legCount).map { leg in
            let progress = legCount > 1 ? Double(leg) / Double(legCount - 1) : 1
            return TripSegment(
                id: "\(line.id.uuidString)-\(leg)",
                start: line.coordinates[leg],
                end: line.coordinates[leg + 1],
                // TUNING: opacity ramp — first leg 0.3, last leg 0.9.
                opacity: 0.3 + 0.6 * progress
            )
        }
    }
}

/// One leg of a trip line, drawn as its own polyline so the opacity ramp can
/// convey direction.
struct TripSegment: Identifiable {
    let id: String
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let opacity: Double
}

// MARK: - Map content

@MainActor
@MapContentBuilder
func tripPolylines(lines: [TripLine]) -> some MapContent {
    let segments = lines.flatMap { TripPolylineBuilder.segments(for: $0) }
    ForEach(segments) { segment in
        MapPolyline(coordinates: [segment.start, segment.end])
            .stroke(
                // COLOR: orange — accent blue blended into map roads/water
                // and the blue pins.
                Color.orange.opacity(segment.opacity),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
    }
}
