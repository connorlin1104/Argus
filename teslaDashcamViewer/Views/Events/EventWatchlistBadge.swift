//
//  EventWatchlistBadge.swift
//  teslaDashcamViewer
//
//  Small chip rendered when an event's first observed plate matches a
//  Watchlist entry. Color and text come from the matching entry.
//

import SwiftUI

struct EventWatchlistBadge: View {
    let entry: Watchlist

    var body: some View {
        let tint = GeofenceStyle.color(hex: entry.colorHex) ?? .red
        HStack(spacing: 4) {
            Image(systemName: "eye.fill")
                .font(.caption2)
            Text(entry.plateText.isEmpty ? "Watched" : entry.plateText.uppercased())
                .font(.caption2.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .liquidGlassChip(tint: tint)
        .help(entry.note.isEmpty ? "Watchlist match" : entry.note)
    }
}
