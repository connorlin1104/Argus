//
//  EventsMapMarkers.swift
//  teslaDashcamViewer
//
//  Marker builder for the events map. Prefers the matching geofence's
//  user-chosen color + SF Symbol when the event is inside a zone; falls
//  back to the existing tag-based scheme otherwise.
//

import SwiftUI
import MapKit

@MainActor
@MapContentBuilder
func eventMarkers(events: [Event],
                  fences: [Geofence]) -> some MapContent {
    ForEach(events) { event in
        if let coord = MarkerStyle.coordinate(event) {
            Marker(
                MarkerStyle.title(for: event),
                systemImage: MarkerStyle.symbol(for: event, fences: fences),
                coordinate: coord
            )
            .tint(MarkerStyle.color(for: event, fences: fences))
            .tag(event as Event?)
        }
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
