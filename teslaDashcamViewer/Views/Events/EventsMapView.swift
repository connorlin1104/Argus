//
//  EventsMapView.swift
//  teslaDashcamViewer
//
//  Shows all imported events on a Map, color-coded by behavior tag.
//  Search keywords: UI:map, COLOR:map-marker, ICON:map-marker, TEXT:map
//

import SwiftUI
import SwiftData
import MapKit

struct EventsMapView: View {
    @Query private var events: [Event]
    @State private var selectedEvent: Event?

    var body: some View {
        NavigationStack {
            // UI: full-screen Map with one Marker per geocoded event
            Map(selection: $selectedEvent) {
                ForEach(eventsWithLocation) { event in
                    Marker(markerTitle(event),
                           systemImage: markerSymbol(event),
                           coordinate: coordinate(event))
                        .tint(markerColor(event))
                        .tag(event as Event?)
                }
            }
            // TUNING: realistic elevation makes the map look 3D; swap to .flat
            // for a faster/simpler look.
            .mapStyle(.standard(elevation: .realistic))
            // UI: floating event popover anchored to top-leading
            .overlay(alignment: .topLeading) {
                if let event = selectedEvent {
                    MapEventPopover(event: event) { selectedEvent = nil }
                        // LAYOUT: outer padding from the map edge
                        .padding(12)
                }
            }
            // TEXT: navigation title at top of the Map tab
            .navigationTitle("Map")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Coordinate filtering

    private var eventsWithLocation: [Event] {
        events.filter { coordinateIfValid($0) != nil }
    }

    private func coordinateIfValid(_ event: Event) -> CLLocationCoordinate2D? {
        guard let lat = Double(event.estLatitude), let lon = Double(event.estLongitude) else { return nil }
        if abs(lat) < 0.0001 && abs(lon) < 0.0001 { return nil }
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func coordinate(_ event: Event) -> CLLocationCoordinate2D {
        coordinateIfValid(event) ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    // MARK: - Marker styling

    /// TEXT: marker title — city if known, otherwise timestamp.
    private func markerTitle(_ event: Event) -> String {
        if !event.city.isEmpty { return event.city }
        return event.timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    /// ICON: SF Symbol used for each tag's map marker.
    private func markerSymbol(_ event: Event) -> String {
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

    /// COLOR: marker tint per tag.
    private func markerColor(_ event: Event) -> Color {
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
}

// MARK: - Popover

/// UI: small info card shown when a map marker is selected.
private struct MapEventPopover: View {
    let event: Event
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // UI: header row with timestamp + close button
            HStack {
                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Spacer()
                // BUTTON: close popover
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill") // ICON: close
                        .foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
            // TEXT: optional city/behavior/score/summary lines
            if !event.city.isEmpty { Text(event.city).font(.subheadline) }
            if event.tag != "unknown" {
                Text("Behavior: \(event.tag.capitalized)").font(.caption)
            }
            if event.interestingnessScore > 0 {
                Text(String(format: "Score: %.0f", event.interestingnessScore * 100))
                    .font(.caption.monospacedDigit())
            }
            if !event.summary.isEmpty {
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        // LAYOUT: popover padding + max width
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        // COLOR: glass card
        .liquidGlassCard(cornerRadius: 14)
    }
}
