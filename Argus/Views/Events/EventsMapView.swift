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
    /// NAV: typed path so the marker popover can push EventDetailView.
    @State private var path: [Event] = []

    var body: some View {
        NavigationStack(path: $path) {
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
                    MapEventPopover(
                        event: event,
                        onOpen: {
                            selectedEvent = nil
                            path.append(event)
                        },
                        onClose: { selectedEvent = nil }
                    )
                    .padding(12)
                }
            }
            .navigationTitle("Map")
            .navigationDestination(for: Event.self) { event in
                EventDetailView(event: event)
            }
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
        // NAV: trip-sibling and mini-map pin taps inside a map-pushed detail
        // view use \.openEvent too — wire it to this tab's stack so they
        // aren't silent no-ops here.
        .environment(\.openEvent, OpenEventAction { event in
            path.append(event)
        })
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
    let onOpen: () -> Void
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
                Text(ScoreBadge.label(for: event.interestingnessScore))
                    .font(.caption)
            }
            if !event.summary.isEmpty {
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            // BUTTON: jump from the marker to the full event page — without
            // this the popover was a dead end.
            Button(action: onOpen) {
                Label("Open event", systemImage: "chevron.right.circle")
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .liquidGlassCard(cornerRadius: 14)
    }
}
