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
    /// Camera binding so tapping a cluster can zoom into it.
    @State private var camera: MapCameraPosition = .automatic
    /// Last settled viewport — clusters are recomputed against its span, so
    /// pins merge when zoomed out and split apart as the user zooms in.
    @State private var visibleRegion: MKCoordinateRegion?
    /// Cluster whose pins share one spot — zooming can't split those, so we
    /// show a member list to pick from instead.
    @State private var pickedCluster: EventCluster?

    var body: some View {
        NavigationStack(path: $path) {
            // UI: full-screen Map with markers (and optional density overlay).
            Map(position: $camera, selection: $selectedEvent) {
                if showDensity {
                    densityCircles(events: eventsWithLocation)
                }
                eventMarkers(
                    clusters: EventClusterer.clusters(
                        events: eventsWithLocation,
                        visibleRegion: visibleRegion
                    ),
                    fences: fences,
                    onClusterTap: handleClusterTap
                )
            }
            .mapStyle(.standard(elevation: .realistic))
            // Recompute clusters only once the camera settles — doing it on
            // every frame of a pinch would churn annotations mid-gesture.
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
            // Picking a marker replaces any open cluster list.
            .onChange(of: selectedEvent) { _, newValue in
                if newValue != nil { pickedCluster = nil }
            }
            .overlay(alignment: .topLeading) {
                if let cluster = pickedCluster {
                    MapClusterPopover(
                        events: cluster.events.sorted { $0.timestamp > $1.timestamp },
                        onPick: { event in
                            pickedCluster = nil
                            selectedEvent = event
                        },
                        onClose: { pickedCluster = nil }
                    )
                    .padding(12)
                } else if let event = selectedEvent {
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

    /// Zoom into a tapped cluster so its pins separate. Members at (nearly)
    /// the same spot can never separate by zooming, so list them instead.
    private func handleClusterTap(_ cluster: EventCluster) {
        selectedEvent = nil
        let spread = cluster.spread
        // TUNING: ~0.0002° ≈ 20 m — below this, treat as one shared location.
        if spread.lat < 0.0002 && spread.lon < 0.0002 {
            pickedCluster = cluster
        } else {
            pickedCluster = nil
            withAnimation(.easeInOut) {
                camera = .region(MKCoordinateRegion(
                    center: cluster.center,
                    // LAYOUT: pad the cluster's bounding box so split pins
                    // land comfortably inside the viewport.
                    span: MKCoordinateSpan(
                        latitudeDelta: max(spread.lat * 3, 0.001),
                        longitudeDelta: max(spread.lon * 3, 0.001)
                    )
                ))
            }
        }
    }
}

// MARK: - Cluster member list

/// UI: card listing the events stacked on one location so the user can pick
/// one — these pins would otherwise hide each other forever.
private struct MapClusterPopover: View {
    let events: [Event]
    let onPick: (Event) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // TEXT: cluster list header
                Text("\(events.count) events here")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events) { event in
                        Button {
                            onPick(event)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(MarkerStyle.title(for: event))
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
            // LAYOUT: cap the list so a big stack doesn't cover the map.
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .liquidGlassCard(cornerRadius: 14)
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
