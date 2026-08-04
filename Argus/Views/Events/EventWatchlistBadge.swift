//
//  EventWatchlistBadge.swift
//  Argus
//
//  Watchlist chips for an event. Every watchlist entry the event's footage
//  detected gets its own bubble in that entry's color; fuzzy matches
//  (partial read, one misread character) are prefixed "Possibly". Plates
//  that aren't on the watchlist don't chip — they'd drown the row on a
//  busy street, and search still finds them.
//

import SwiftUI
import SwiftData

/// One chip per matched watchlist entry. Emits multiple chips, so place it
/// inside a chip row/flow layout.
struct EventPlateChips: View {
    let event: Event
    let watchlist: [Watchlist]

    var body: some View {
        ForEach(
            WatchlistMatcher.matches(event: event, in: watchlist),
            id: \.entry.persistentModelID
        ) { match in
            EventWatchlistBadge(entry: match.entry, isExact: match.isExact)
        }
    }
}

/// A single watchlist bubble: the entry's plate in the entry's color with an
/// eye icon, prefixed "Possibly" when the read wasn't exact.
struct EventWatchlistBadge: View {
    let entry: Watchlist
    var isExact: Bool = true

    var body: some View {
        let tint = GeofenceStyle.color(hex: entry.colorHex) ?? .red
        HStack(spacing: 4) {
            Image(systemName: "eye.fill")
                .font(.caption2)
            Text(isExact ? entry.plateText.uppercased() : "Possibly \(entry.plateText.uppercased())")
                .font(.caption2.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .liquidGlassChip(tint: tint)
        .help(entry.note.isEmpty ? "Watchlist match" : entry.note)
    }
}
