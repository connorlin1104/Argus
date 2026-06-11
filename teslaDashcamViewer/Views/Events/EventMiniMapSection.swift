//
//  EventMiniMapSection.swift
//  teslaDashcamViewer
//
//  Square mini-map in EventDetailView. Centers on the current event and
//  pins every starred event for orientation/cross-navigation.
//  Search keywords: UI:event-detail, UI:mini-map, NAV:event, COLOR:map-marker
//

import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Square mini-map shown next to the Details card. Centers on the current
/// event so the user can see roughly where this (non-starred) event happened,
/// and pins every starred event for orientation/cross-navigation.
///
/// LAYOUT: caller is expected to give this view a square frame (the map fills
/// its container). Internally everything uses `maxWidth: .infinity` so it
/// adapts to whatever square the parent allocates.
///
/// NAV: pin taps push another EventDetailView via the `\.openEvent`
/// environment action. When multiple starred events share the same coordinate
/// (rounded to ~11m), a small popover lists them so the user can choose.
struct EventMiniMapSection: View {
    let event: Event

    /// All favorited events — the persistent reference set drawn as pins.
    @Query(filter: #Predicate<Event> { $0.isFavorite })
    private var favoriteEvents: [Event]

    /// NAV: action injected by EventsListView's NavigationStack.
    @Environment(\.openEvent) private var openEvent

    /// Map camera state. Recentered whenever the current event changes.
    @State private var cameraPosition: MapCameraPosition = .automatic

    /// Tracks the currently-selected marker id (from Map's `selection:`).
    @State private var selectedClusterID: String?

    /// Cluster shown in the disambiguation popover, when multiple favorites
    /// share the same rounded coordinate.
    @State private var pickerCluster: FavoriteCluster?

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if let center = currentCoord {
            mapBody(center: center)
        } else if let firstFav = favoriteClusters.first {
            // No coords on this event — fall back to centering on a favorite
            // so the user still sees their reference points.
            mapBody(center: firstFav.coord)
        } else {
            // No coords anywhere — explain why the map is empty.
            VStack(spacing: 8) {
                Image(systemName: "mappin.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No location data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
        }
    }

    @ViewBuilder
    private func mapBody(center: CLLocationCoordinate2D) -> some View {
        // LAYOUT: 1:1 aspect — the parent column controls actual size.
        Map(position: $cameraPosition, selection: $selectedClusterID) {
            // Pin the current event (distinct accent tint + "location" glyph)
            // so users can read this map at a glance even before they look
            // at the favorites.
            if let currentCoord {
                Marker(currentTitle,
                       systemImage: "location.fill",
                       coordinate: currentCoord)
                    .tint(Color.accentColor)
                    .tag(Self.currentMarkerID)
            }
            // One marker per favorite cluster.
            ForEach(favoriteClusters) { cluster in
                Marker(cluster.title,
                       systemImage: cluster.symbol,
                       coordinate: cluster.coord)
                    .tint(.yellow)
                    .tag(cluster.id)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .aspectRatio(1.2, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if let cluster = pickerCluster {
                clusterPicker(cluster)
                    .padding(8)
            }
        }
        .onAppear { recenter(on: center) }
        .onChange(of: currentCoord?.latitude) { _, _ in
            if let c = currentCoord { recenter(on: c) }
        }
        .onChange(of: selectedClusterID) { _, newID in
            handleSelection(newID)
        }
    }

    // MARK: - Cluster picker overlay

    @ViewBuilder
    private func clusterPicker(_ cluster: FavoriteCluster) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(cluster.events.count) starred events here")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    pickerCluster = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            ForEach(cluster.events) { ev in
                Button {
                    pickerCluster = nil
                    openEvent(ev)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text(displayName(for: ev))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5)
        )
    }

    // MARK: - Selection handling

    private func handleSelection(_ id: String?) {
        guard let id else { return }
        // Tapping the current event's own pin is a no-op.
        if id == Self.currentMarkerID {
            selectedClusterID = nil
            return
        }
        guard let cluster = favoriteClusters.first(where: { $0.id == id }) else {
            selectedClusterID = nil
            return
        }
        // Always reset the Map's selection so re-taps re-fire onChange.
        selectedClusterID = nil
        if cluster.events.count == 1, let only = cluster.events.first {
            pickerCluster = nil
            openEvent(only)
        } else {
            pickerCluster = cluster
        }
    }

    private func recenter(on coord: CLLocationCoordinate2D) {
        // TUNING: span ≈ 800m across so the current event has neighborhood
        // context without zooming so far that pins overlap.
        let span = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        cameraPosition = .region(MKCoordinateRegion(center: coord, span: span))
    }

    // MARK: - Coordinate / cluster helpers

    /// Marker id used for the current event so we can distinguish it from
    /// favorite-cluster ids on selection change.
    private static let currentMarkerID = "__current__"

    private var currentCoord: CLLocationCoordinate2D? {
        Self.validCoord(latString: event.estLatitude, lonString: event.estLongitude)
    }

    private var currentTitle: String {
        Self.displayName(for: event)
    }

    /// Favorites with valid coords, grouped by rounded (lat,lon) so multiple
    /// starred events at "the same spot" collapse into a single map pin.
    /// Excludes the current event so a starred current event doesn't render
    /// twice (once as the accent "current" pin, once as a yellow cluster pin).
    private var favoriteClusters: [FavoriteCluster] {
        var buckets: [String: [Event]] = [:]
        var order: [String] = []
        for fav in favoriteEvents where fav !== event {
            guard let coord = Self.validCoord(
                latString: fav.estLatitude,
                lonString: fav.estLongitude
            ) else { continue }
            let key = Self.clusterKey(coord)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(fav)
        }
        return order.compactMap { key -> FavoriteCluster? in
            guard let events = buckets[key], let first = events.first,
                  let coord = Self.validCoord(
                    latString: first.estLatitude,
                    lonString: first.estLongitude
                  )
            else { return nil }
            // Stable id derived from the rounded coord — survives re-renders.
            return FavoriteCluster(
                id: "fav:\(key)",
                coord: coord,
                events: events.sorted(by: { $0.timestamp > $1.timestamp })
            )
        }
    }

    /// Round to ~4 decimal places (≈11m) so genuinely "same location" events
    /// merge into one pin while events even one parking-spot apart stay
    /// separate.
    private static func clusterKey(_ coord: CLLocationCoordinate2D) -> String {
        let lat = (coord.latitude * 10_000).rounded() / 10_000
        let lon = (coord.longitude * 10_000).rounded() / 10_000
        return "\(lat),\(lon)"
    }

    /// Parses + validates the string-encoded coords on Event.
    /// Internal so `FavoriteCluster` (in its own file) can share this helper.
    static func validCoord(latString: String, lonString: String) -> CLLocationCoordinate2D? {
        guard let lat = Double(latString), let lon = Double(lonString) else { return nil }
        if abs(lat) < 0.0001 && abs(lon) < 0.0001 { return nil }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coord) else { return nil }
        return coord
    }

    /// Title used on every map pin: user-set name if any, else humanized
    /// trigger, else a timestamp fallback.
    /// Internal so `FavoriteCluster` (in its own file) can share this helper.
    static func displayName(for event: Event) -> String {
        if !event.customName.isEmpty { return event.customName }
        if !event.reason.isEmpty { return EventSummarizer.humanizeReason(event.reason) }
        return event.timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    private func displayName(for event: Event) -> String {
        Self.displayName(for: event)
    }
}
