//
//  EventWatchlistBadge.swift
//  Argus
//
//  Plate chips for an event. Every OCR'd plate read gets its own bubble so
//  the user can see that detection actually worked; reads matching a
//  Watchlist entry render in that entry's color with an eye icon, other
//  reads stay neutral gray. Fuzzy matches (partial read, one misread
//  character) are prefixed "Possibly".
//

import SwiftUI
import SwiftData

/// One chip per stored plate read, watchlist matches first. Emits multiple
/// chips, so place it inside a chip row/flow layout.
struct EventPlateChips: View {
    let event: Event
    let watchlist: [Watchlist]

    /// TUNING: cap on unmatched plate chips per event — a busy street scan
    /// can store several reads and the row shouldn't drown in gray bubbles.
    /// Watchlist matches are never capped.
    private static let maxUnmatched = 3

    private struct Chip {
        let plate: String
        let entry: Watchlist?
        let isExact: Bool
    }

    var body: some View {
        ForEach(chips, id: \.plate) { chip in
            EventWatchlistBadge(plate: chip.plate, entry: chip.entry, isExact: chip.isExact)
        }
    }

    private var chips: [Chip] {
        let reads = event.plateText.split(separator: " ").map(String.init)
        guard !reads.isEmpty else {
            // Events saved before plate text was persisted: the match (if
            // any) came from the AI summary, so show the entry's own plate.
            if let match = WatchlistMatcher.match(event: event, in: watchlist) {
                return [Chip(plate: match.entry.plateText, entry: match.entry, isExact: match.isExact)]
            }
            return []
        }

        // Several reads of the same plate collapse into one chip per
        // watchlist entry, keeping the exact read over a fuzzy one.
        var watchedByEntry: [PersistentIdentifier: Chip] = [:]
        var watchedOrder: [PersistentIdentifier] = []
        var unmatched: [Chip] = []
        for read in reads {
            if let match = WatchlistMatcher.match(plateRead: read, in: watchlist) {
                let id = match.entry.persistentModelID
                if let existing = watchedByEntry[id] {
                    if match.isExact && !existing.isExact {
                        watchedByEntry[id] = Chip(plate: read, entry: match.entry, isExact: true)
                    }
                } else {
                    watchedByEntry[id] = Chip(plate: read, entry: match.entry, isExact: match.isExact)
                    watchedOrder.append(id)
                }
            } else {
                unmatched.append(Chip(plate: read, entry: nil, isExact: false))
            }
        }
        let watched = watchedOrder.compactMap { watchedByEntry[$0] }
        return watched + unmatched.prefix(Self.maxUnmatched)
    }
}

/// A single plate bubble. With a watchlist entry it takes the entry's color
/// and an eye icon (prefixed "Possibly" when the read wasn't exact); without
/// one it's a neutral "plate detected" chip.
struct EventWatchlistBadge: View {
    let plate: String
    let entry: Watchlist?
    var isExact: Bool = true

    var body: some View {
        if let entry {
            let tint = GeofenceStyle.color(hex: entry.colorHex) ?? .red
            chipLabel(
                icon: "eye.fill",
                text: isExact ? plate.uppercased() : "Possibly \(plate.uppercased())"
            )
            .foregroundStyle(tint)
            .liquidGlassChip(tint: tint)
            .help(entry.note.isEmpty ? "Watchlist match" : entry.note)
        } else {
            chipLabel(icon: plateSymbol, text: plate.uppercased())
                .foregroundStyle(.secondary)
                .liquidGlassChip(tint: .gray)
                .help("Plate detected")
        }
    }

    /// "licenseplate" arrived with SF Symbols 6 — fall back on older OSes.
    private var plateSymbol: String {
        if #available(iOS 18.0, macOS 15.0, *) {
            return "licenseplate"
        }
        return "car.rear"
    }

    private func chipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}
