//
//  WatchlistMatcher.swift
//  Argus
//
//  Matches an event's stored plate reads against a Watchlist using the
//  OCR-tolerant normalization in EventSearchMatcher. Matches carry a
//  confidence tier: exact reads badge plainly, near-misses (partial reads,
//  one misread character like M↔N) badge as "Possibly".
//

import Foundation

enum WatchlistMatcher {

    /// A watchlist hit for one plate read. `isExact` is false for the fuzzy
    /// tiers (containment / one-character substitution) — the UI prefixes
    /// those with "Possibly".
    struct Match {
        let entry: Watchlist
        let isExact: Bool
    }

    /// TUNING: minimum normalized length before a one-character substitution
    /// counts as a possible match. At 4 chars a single wrong character is a
    /// 25% miss — too loose, it flagged unrelated plates.
    private static let minLengthForSubstitution = 5

    /// Returns the best watchlist match across the event's plate reads, or
    /// nil. Reads come from the OCR text the scan stored on the event;
    /// plate-like words in the AI summary are a fallback for events saved
    /// before plate text was persisted. Matching is per-plate-word — the old
    /// whole-summary substring match let a short entry like "8Y" flag any
    /// event whose summary said someone "walked by".
    static func match(event: Event, in watchlist: [Watchlist]) -> Match? {
        var candidates = EventSearchMatcher.plateCandidates(in: event.plateText)
        if candidates.isEmpty {
            candidates = EventSearchMatcher.plateCandidates(in: event.summary)
        }
        var possible: Match? = nil
        for candidate in candidates {
            guard let match = match(plateRead: candidate, in: watchlist) else { continue }
            if match.isExact { return match }
            possible = possible ?? match
        }
        return possible
    }

    /// Match a single OCR plate read against the watchlist. Used by the
    /// per-plate chips so each read can carry its own entry's color.
    static func match(plateRead: String, in watchlist: [Watchlist]) -> Match? {
        let candidate = EventSearchMatcher.normalizePlate(plateRead)
        guard !candidate.isEmpty else { return nil }

        var possible: Match? = nil
        for entry in watchlist {
            let needle = EventSearchMatcher.normalizePlate(entry.plateText)
            guard !needle.isEmpty else { continue }
            if candidate == needle {
                return Match(entry: entry, isExact: true)
            }
            // Below plausible-plate length only an exact match counts.
            guard needle.count >= 4, possible == nil else { continue }
            // Bidirectional containment tolerates partial OCR reads (a
            // 5-char read of a 6-char watched plate). One substitution at
            // equal length tolerates a misread character the normalization
            // map doesn't cover (M↔N, E↔F).
            if candidate.contains(needle) || needle.contains(candidate)
                || isOneSubstitutionApart(candidate, needle) {
                possible = Match(entry: entry, isExact: false)
            }
        }
        return possible
    }

    /// True when the strings have equal length and differ in exactly one
    /// position — the shape of a single misread character.
    private static func isOneSubstitutionApart(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count, a.count >= minLengthForSubstitution else { return false }
        var diffs = 0
        for (x, y) in zip(a, b) where x != y {
            diffs += 1
            if diffs > 1 { return false }
        }
        return diffs == 1
    }
}
