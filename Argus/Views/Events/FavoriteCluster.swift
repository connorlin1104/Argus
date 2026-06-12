//
//  FavoriteCluster.swift
//  Argus
//
//  One pin's worth of favorited events on the detail-view mini map.
//  Multiple events at the "same" coordinate (rounded to ~11m) collapse into
//  a single cluster so the map shows one marker per place rather than a stack.
//  Search keywords: UI:mini-map, CLUSTER:favorites
//

import Foundation
import CoreLocation

/// One pin's worth of favorites — multiple events collapsed by location.
struct FavoriteCluster: Identifiable, Hashable {
    let id: String
    let coord: CLLocationCoordinate2D
    let events: [Event]

    /// Single-event clusters get the star glyph; multi-event ones get a
    /// numbered badge style via a generic glyph + count in the title.
    var symbol: String {
        events.count > 1 ? "star.circle.fill" : "star.fill"
    }

    /// Marker label. For multi-event clusters we prefix with the count so
    /// users see "3 · Driveway" rather than just "Driveway" for a stack.
    var title: String {
        let base = EventMiniMapSection.displayName(for: events[0])
        return events.count > 1 ? "\(events.count) · \(base)" : base
    }

    static func == (lhs: FavoriteCluster, rhs: FavoriteCluster) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
