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
    /// Groups events by tripID (events without one are skipped), orders each
    /// group chronologically, and keeps only trips with 2+ locatable events —
    /// a single point can't draw a line. Sorted by tripID for stable identity.
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
            guard coordinates.count >= 2 else { return nil }
            return TripLine(id: tripID, coordinates: coordinates)
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
func tripPolylines(events: [Event]) -> some MapContent {
    let segments = TripPolylineBuilder.tripLines(events: events)
        .flatMap { TripPolylineBuilder.segments(for: $0) }
    ForEach(segments) { segment in
        MapPolyline(coordinates: [segment.start, segment.end])
            .stroke(
                Color.accentColor.opacity(segment.opacity),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
    }
}
