//
//  EventSearchMatcher.swift
//  teslaDashcamViewer
//
//  Tokenized event search + plate normalization. Shared by EventsListView's
//  search bar and WatchlistMatcher (so a user-typed "B8C-123" matches an
//  OCR'd "BBC123" once both are normalized).
//

import Foundation

enum EventSearchMatcher {

    /// True when every whitespace-separated token in `query` appears in some
    /// field of the event. Empty query matches everything.
    static func matches(event: Event, query: String) -> Bool {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return true }

        let haystack = haystack(for: event)
        return tokens.allSatisfy { token in
            haystack.contains { $0.contains(token) }
        }
    }

    /// All searchable text fields, lowercased and deduplicated. Order doesn't
    /// matter — we only test `contains` on each token.
    private static func haystack(for event: Event) -> [String] {
        var fields: [String] = [
            event.city, event.reason, event.zone, event.summary, event.address,
            event.tag, event.camera, event.notes, event.customName
        ]
        // Plate normalized form so "B0C123" still matches even if the user
        // typed it without ambiguous-glyph folding.
        let plate = normalizePlate(event.summary)
        if !plate.isEmpty { fields.append(plate) }
        return fields.filter { !$0.isEmpty }.map { $0.lowercased() }
    }

    /// Strip non-alphanumeric characters and fold common OCR confusions so
    /// the watchlist can match plates regardless of formatting noise.
    /// - O/Q ↔ 0
    /// - I/L ↔ 1
    /// - B ↔ 8
    /// - S ↔ 5
    /// - Z ↔ 2
    static func normalizePlate(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            guard CharacterSet.alphanumerics.contains(scalar) else { continue }
            let ch = Character(scalar)
            switch ch {
            case "O", "o", "Q", "q": out.append("0")
            case "I", "i", "L", "l": out.append("1")
            case "B", "b":           out.append("8")
            case "S", "s":           out.append("5")
            case "Z", "z":           out.append("2")
            default:                 out.append(Character(scalar).uppercased())
            }
        }
        return out
    }
}
