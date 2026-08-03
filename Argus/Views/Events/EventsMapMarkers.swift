//
//  EventsMapMarkers.swift
//  Argus
//
//  Marker + cluster builder for the events map. Events that sit close
//  together at the current zoom level are grouped into one count badge that
//  splits apart as the user zooms in. Single events keep the geofence/tag
//  styling. Search keywords: UI:map-cluster, COLOR:map-marker, ICON:map-marker
//

import SwiftUI
import SwiftData
import MapKit

// MARK: - Cluster model

/// A zoom-dependent group of events drawn as one annotation. Rebuilt every
/// time the camera settles, so groups split naturally as the user zooms in.
struct EventCluster: Identifiable {
    private(set) var events: [Event]
    private(set) var center: CLLocationCoordinate2D

    /// Identity follows the lead event so SwiftUI can match annotations
    /// across camera changes when the grouping didn't actually change.
    var id: PersistentIdentifier { representative.persistentModelID }

    /// The member whose name the badge shows — prefer a user-named event,
    /// then the highest-activity one.
    var representative: Event {
        events.first(where: { !$0.customName.isEmpty })
            ?? events.max(by: { $0.interestingnessScore < $1.interestingnessScore })
            ?? events[0]
    }

    /// Geographic spread of the members in degrees. Used to decide whether
    /// zooming in can split the cluster or the pins share one location.
    var spread: (lat: Double, lon: Double) {
        let coords = events.compactMap { MarkerStyle.coordinate($0) }
        guard let first = coords.first else { return (0, 0) }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords.dropFirst() {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return (maxLat - minLat, maxLon - minLon)
    }

    mutating func absorb(_ event: Event, at coord: CLLocationCoordinate2D) {
        // Keep the badge at the running mean of its members so it sits
        // between the pins it stands in for.
        let n = Double(events.count)
        center.latitude = (center.latitude * n + coord.latitude) / (n + 1)
        center.longitude = (center.longitude * n + coord.longitude) / (n + 1)
        events.append(event)
    }
}

enum EventClusterer {
    /// TUNING: pins closer together than this fraction of the visible span
    /// are merged into one badge. Bigger = more aggressive grouping.
    static let mergeFraction = 0.05

    /// Greedy proximity grouping relative to the visible region. With no
    /// region yet (first frame), only events at the exact same spot merge —
    /// that still fixes identical-location pins hiding each other.
    static func clusters(events: [Event],
                         visibleRegion: MKCoordinateRegion?) -> [EventCluster] {
        let latGap = (visibleRegion?.span.latitudeDelta ?? 0) * mergeFraction
        let lonGap = (visibleRegion?.span.longitudeDelta ?? 0) * mergeFraction
        var clusters: [EventCluster] = []
        for event in events {
            guard let coord = MarkerStyle.coordinate(event) else { continue }
            if let index = clusters.firstIndex(where: {
                abs($0.center.latitude - coord.latitude) <= latGap &&
                abs($0.center.longitude - coord.longitude) <= lonGap
            }) {
                clusters[index].absorb(event, at: coord)
            } else {
                clusters.append(EventCluster(events: [event], center: coord))
            }
        }
        return clusters
    }
}

// MARK: - Map content

@MainActor
@MapContentBuilder
func eventMarkers(clusters: [EventCluster],
                  fences: [Geofence],
                  onClusterTap: @escaping (EventCluster) -> Void) -> some MapContent {
    ForEach(clusters) { cluster in
        if cluster.events.count == 1,
           let event = cluster.events.first,
           let coord = MarkerStyle.coordinate(event) {
            Marker(
                MarkerStyle.title(for: event),
                systemImage: MarkerStyle.symbol(for: event, fences: fences),
                coordinate: coord
            )
            .tint(MarkerStyle.color(for: event, fences: fences))
            .tag(event as Event?)
        } else {
            // TEXT: cluster label — lead event's name plus how many more.
            Annotation(
                "\(MarkerStyle.title(for: cluster.representative)) +\(cluster.events.count - 1)",
                coordinate: cluster.center
            ) {
                ClusterBadge(
                    count: cluster.events.count,
                    tint: MarkerStyle.color(for: cluster.representative, fences: fences)
                )
                .onTapGesture { onClusterTap(cluster) }
            }
        }
    }
}

/// UI: circular count badge standing in for a group of pins.
private struct ClusterBadge: View {
    let count: Int
    let tint: Color

    var body: some View {
        Text("\(count)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            // LAYOUT: badge size — grows slightly for 3+ digit counts.
            .padding(8)
            .frame(minWidth: 30, minHeight: 30)
            .background(tint.gradient, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }
}

enum MarkerStyle {

    static func title(for event: Event) -> String {
        if !event.customName.isEmpty { return event.customName }
        if !event.reason.isEmpty { return EventSummarizer.humanizeReason(event.reason) }
        if !event.city.isEmpty { return event.city }
        return event.timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    static func symbol(for event: Event, fences: [Geofence]) -> String {
        if let zoneSym = GeofenceStyle.symbol(forZone: event.zone, in: fences) {
            return zoneSym
        }
        switch event.tag {
        case "touched":    return "hand.tap.fill"
        case "lingered":   return "person.fill.viewfinder"
        case "approached": return "figure.walk.arrival"
        case "passing":    return "figure.walk"
        case "vehicle":    return "car.fill"
        case "noise":      return "questionmark.circle"
        default:           return "mappin"
        }
    }

    static func color(for event: Event, fences: [Geofence]) -> Color {
        if let zoneColor = GeofenceStyle.color(forZone: event.zone, in: fences) {
            return zoneColor
        }
        switch event.tag {
        case "touched":    return .red
        case "lingered":   return .orange
        case "approached": return .yellow
        case "passing":    return .blue
        case "vehicle":    return .purple
        case "noise":      return .gray
        default:           return .accentColor
        }
    }

    static func coordinate(_ event: Event) -> CLLocationCoordinate2D? {
        guard let lat = Double(event.estLatitude), let lon = Double(event.estLongitude) else { return nil }
        if abs(lat) < 0.0001 && abs(lon) < 0.0001 { return nil }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coord) else { return nil }
        return coord
    }
}
