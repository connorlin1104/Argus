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
    /// NAV: opening an event from the map switches to the Events tab and
    /// pushes it there — the map itself never hosts detail pages.
    let openInEventsTab: (Event) -> Void

    @Query private var events: [Event]
    @Query(sort: \Geofence.name) private var fences: [Geofence]
    @State private var selectedEvent: Event?
    @State private var showDensity: Bool = false
    /// Timeline scrubber toggle — the window itself intentionally resets
    /// when toggled off (not persisted).
    @State private var showTimeline: Bool = false
    @State private var timelineWindow: TimelineWindow?
    /// Camera binding so tapping a cluster can zoom into it.
    @State private var camera: MapCameraPosition = .automatic
    /// Last settled viewport — clusters are recomputed against its span, so
    /// pins merge when zoomed out and split apart as the user zooms in.
    @State private var visibleRegion: MKCoordinateRegion?
    /// Cluster whose pins share one spot — zooming can't split those, so we
    /// show a member list to pick from instead.
    @State private var pickedCluster: EventCluster?

    var body: some View {
        NavigationStack {
            // UI: full-screen Map with markers (and optional density overlay).
            Map(position: $camera) {
                if showDensity {
                    densityCircles(events: windowedEvents, visibleRegion: visibleRegion)
                }
                eventMarkers(
                    clusters: EventClusterer.clusters(
                        events: windowedEvents,
                        visibleRegion: visibleRegion
                    ),
                    fences: fences,
                    onEventTap: handleEventTap,
                    onClusterTap: handleClusterTap
                )
            }
            .mapStyle(.standard(elevation: .realistic))
            // Recompute clusters only once the camera settles — doing it on
            // every frame of a pinch would churn annotations mid-gesture.
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
            .overlay(alignment: .topLeading) {
                if let cluster = pickedCluster {
                    MapClusterPopover(
                        events: cluster.events.sorted { $0.timestamp > $1.timestamp },
                        onPick: { event in
                            // Picking from the list is already deliberate —
                            // open the event directly, no second dialog.
                            pickedCluster = nil
                            openInEventsTab(event)
                        },
                        onClose: { pickedCluster = nil }
                    )
                    .padding(12)
                }
            }
            // UI: tapping a pin asks before opening — a small dialog with the
            // event's name, time, and an Open Event button.
            .confirmationDialog(
                selectedEvent.map { MarkerStyle.title(for: $0) } ?? "Event",
                isPresented: Binding(
                    get: { selectedEvent != nil },
                    set: { if !$0 { selectedEvent = nil } }
                ),
                titleVisibility: .visible,
                presenting: selectedEvent
            ) { event in
                // BUTTON: open the tapped pin's full event page (Events tab)
                Button("Open Event") {
                    selectedEvent = nil
                    openInEventsTab(event)
                }
                Button("Cancel", role: .cancel) { selectedEvent = nil }
            } message: { event in
                Text(pinDialogMessage(for: event))
            }
            // UI: timeline scrubber card — safeAreaInset (not overlay) so it
            // never covers the tab bar or steals its taps.
            .safeAreaInset(edge: .bottom) {
                if showTimeline {
                    timelineCard
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            .onChange(of: showTimeline) { _, isOn in
                // Opening resets to the full span. The window is deliberately
                // kept (inert) on toggle-off: nil-ing it here crashed the
                // card's unwrapped binding while the inset animated out.
                if isOn { timelineWindow = fullSpanWindow }
            }
            // Toggled on while the library was still empty → the card sat in
            // its empty state; give it a window once events exist.
            .onChange(of: events.count) { _, _ in
                if showTimeline && timelineWindow == nil {
                    timelineWindow = fullSpanWindow
                }
            }
            .navigationTitle("Map")
            .toolbar {
                ToolbarItem {
                    // BUTTON: layers menu — one labeled menu instead of three
                    // bare icon toggles nobody could decipher.
                    Menu {
                        Toggle(isOn: $showDensity) {
                            Label("Density", systemImage: "circle.hexagongrid.fill")
                        }
                        Toggle(isOn: $showTimeline) {
                            Label("Timeline", systemImage: "clock")
                        }
                    } label: {
                        Label("Map Layers", systemImage: "square.3.layers.3d")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var eventsWithLocation: [Event] {
        events.filter { MarkerStyle.coordinate($0) != nil }
    }

    /// What the pins/density/clusters actually show: all located events, or
    /// only those inside the timeline window while the scrubber is on.
    private var windowedEvents: [Event] {
        guard showTimeline, let window = timelineWindow else { return eventsWithLocation }
        return eventsWithLocation.filter { window.contains($0.timestamp) }
    }

    private var fullSpanWindow: TimelineWindow? {
        let stamps = eventsWithLocation.map(\.timestamp)
        guard let first = stamps.min(), let last = stamps.max() else { return nil }
        return TimelineWindow(start: first, end: last)
    }

    @ViewBuilder
    private var timelineCard: some View {
        if let windowBinding = Binding($timelineWindow) {
            EventsMapTimelineCard(
                events: eventsWithLocation,
                visibleCount: windowedEvents.count,
                window: windowBinding
            )
        } else {
            // 2.1a: the toggle always shows something, even with no events.
            // TEXT: timeline empty state
            Text("No events to scrub yet — import footage first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .liquidGlassCard(cornerRadius: 14)
        }
    }

    /// TEXT: pin dialog message — time, then city when known.
    private func pinDialogMessage(for event: Event) -> String {
        let time = event.timestamp.formatted(date: .abbreviated, time: .shortened)
        return event.city.isEmpty ? time : "\(time) • \(event.city)"
    }

    private func handleEventTap(_ event: Event) {
        pickedCluster = nil
        selectedEvent = event
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

