//
//  WatchlistMatcher.swift
//  teslaDashcamViewer
//
//  Matches an event's first observed plate text against a Watchlist using
//  the OCR-tolerant normalization in EventSearchMatcher.
//

import Foundation

enum WatchlistMatcher {

    /// Returns the first watchlist entry whose plate normalizes to a substring
    /// of (or equal to) the event's normalized plate text, or nil.
    static func match(event: Event, in watchlist: [Watchlist]) -> Watchlist? {
        let plate = EventSearchMatcher.normalizePlate(event.summary)
        guard !plate.isEmpty else { return nil }
        for entry in watchlist {
            let needle = EventSearchMatcher.normalizePlate(entry.plateText)
            guard !needle.isEmpty else { continue }
            if plate.contains(needle) || needle.contains(plate) {
                return entry
            }
        }
        return nil
    }
}
