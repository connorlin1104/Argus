//
//  EventSearchMatcher.swift
//  Argus
//
//  Tokenized event search + plate normalization. Shared by EventsListView's
//  search bar and WatchlistMatcher. Plate matching is word-wise: plate-like
//  words are extracted and normalized on both sides, so a user-typed
//  "B8C-123" matches an OCR'd "BBC123" without the whole summary being
//  folded into one string (which made "50" match "person" → "PER50N").
//

import Foundation

enum EventSearchMatcher {

    /// True when every whitespace-separated token in `query` appears in some
    /// field of the event, either as plain text or as a normalized plate
    /// match. Empty query matches everything.
    static func matches(event: Event, query: String) -> Bool {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return true }

        let haystack = haystack(for: event)
        let plates = plateCandidates(in: event.plateText) + plateCandidates(in: event.summary)
        return tokens.allSatisfy { token in
            if haystack.contains(where: { $0.contains(token) }) { return true }
            // Normalize the query token the same way stored plates are
            // normalized, so dashes and OCR-ambiguous glyphs don't block the
            // match. Require 3+ chars — shorter fragments false-match wildly.
            let normalizedToken = normalizePlate(token)
            guard normalizedToken.count >= 3 else { return false }
            return plates.contains { $0.contains(normalizedToken) }
        }
    }

    /// All searchable text fields, lowercased and deduplicated. Order doesn't
    /// matter — we only test `contains` on each token.
    private static func haystack(for event: Event) -> [String] {
        let fields: [String] = [
            event.city, event.reason, event.zone, event.summary, event.address,
            event.tag, event.camera, event.notes, event.customName, event.plateText
        ]
        return fields.filter { !$0.isEmpty }.map { $0.lowercased() }
    }

    /// Normalized plate-like words found in `text`. A word qualifies when its
    /// dash-stripped form is 4–8 alphanumeric characters with at least one
    /// digit and one letter — the same shape DetectionEngine accepts from OCR.
    /// Working word-by-word (instead of normalizing the whole text) keeps
    /// prose from producing phantom plates.
    static func plateCandidates(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
        var out: [String] = []
        for word in words {
            let stripped = word.replacingOccurrences(of: "-", with: "")
            guard (4...8).contains(stripped.count),
                  stripped.contains(where: \.isNumber),
                  stripped.contains(where: \.isLetter) else { continue }
            let normalized = normalizePlate(String(word))
            if !normalized.isEmpty && !out.contains(normalized) {
                out.append(normalized)
            }
        }
        return out
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
