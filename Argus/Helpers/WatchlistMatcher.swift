//
//  WatchlistMatcher.swift
//  Argus
//
//  Matches an event's stored plate reads against a Watchlist using the
//  OCR-tolerant normalization in EventSearchMatcher.
//

import Foundation

enum WatchlistMatcher {

    /// Returns the first watchlist entry matching one of the event's plate
    /// reads, or nil. Reads come from the OCR text the scan stored on the
    /// event; plate-like words in the AI summary are a fallback for events
    /// saved before plate text was persisted. Matching is per-plate-word —
    /// the old whole-summary substring match let a short entry like "8Y"
    /// flag any event whose summary said someone "walked by".
    static func match(event: Event, in watchlist: [Watchlist]) -> Watchlist? {
        var candidates = EventSearchMatcher.plateCandidates(in: event.plateText)
        if candidates.isEmpty {
            candidates = EventSearchMatcher.plateCandidates(in: event.summary)
        }
        guard !candidates.isEmpty else { return nil }

        for entry in watchlist {
            let needle = EventSearchMatcher.normalizePlate(entry.plateText)
            guard !needle.isEmpty else { continue }
            if needle.count < 4 {
                // Below plausible-plate length only an exact match counts.
                if candidates.contains(needle) { return entry }
                continue
            }
            // Bidirectional containment tolerates partial OCR reads (a
            // 5-char read of a 6-char watched plate still matches).
            if candidates.contains(where: { $0 == needle || $0.contains(needle) || needle.contains($0) }) {
                return entry
            }
        }
        return nil
    }
}
