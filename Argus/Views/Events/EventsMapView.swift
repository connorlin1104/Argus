//
//  EventsMapView.swift
//  Argus
//
//  Shows all imported events on a Map, color-coded by zone (when present)
//  or behavior tag. Includes a density-layer toggle that surfaces clusters
//  as translucent circles.
//  Search keywords: UI:map, COLOR:map-marker, ICON:map-marker, TEXT:map
//

import SwiftUI
import SwiftData
import MapKit

struct EventsMapView: View {
    @Query private var events: [Event]
    @Query(sort: \Geofence.name) private var fences: [Geofence]
    @State private var selectedEvent: Event?
    @State private var showDensity: Bool = false

    var body: some View {
        NavigationStack {
            // UI: full-screen Map with markers (and optional density overlay).
            Map(selection: $selectedEvent) {
                if showDensity {
                    densityCircles(events: eventsWithLocation)
                }
                eventMarkers(events: eventsWithLocation, fences: fences)
            }
            .mapStyle(.standard(elevation: .realistic))
            .overlay(alignment: .topLeading) {
                if let event = selectedEvent {
                    MapEventPopover(event: event) { selectedEvent = nil }
                        .padding(12)
                }
            }
            .navigationTitle("Map")
            .toolbar {
                ToolbarItem {
                    // BUTTON: density toggle
                    Toggle(isOn: $showDensity) {
                        Label("Density", systemImage: "circle.hexagongrid.fill")
                    }
                    .toggleStyle(.button)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var eventsWithLocation: [Event] {
        events.filter { MarkerStyle.coordinate($0) != nil }
    }
}

// MARK: - Popover

/// UI: small info card shown when a map marker is selected.
private struct MapEventPopover: View {
    let event: Event
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
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
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .liquidGlassCard(cornerRadius: 14)
    }
}
