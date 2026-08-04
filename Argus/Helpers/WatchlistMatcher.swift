//
//  WatchlistMatcher.swift
//  Argus
//
//  Matches an event's plate text against a Watchlist using the OCR-tolerant
//  normalization in EventSearchMatcher. Entry-centric: every watched plate
//  the event's footage detected gets its own match, each carrying a
//  confidence tier — exact reads badge plainly, near-misses (partial reads,
//  one misread character like M↔N) badge as "Possibly".
//

import Foundation

enum WatchlistMatcher {

    /// A watchlist hit on an event. `isExact` is false for the fuzzy tiers
    /// (containment / one-character substitution) — the UI prefixes those
    /// with "Possibly".
    struct Match {
        let entry: Watchlist
        let isExact: Bool
    }

    /// TUNING: minimum normalized length before a one-character substitution
    /// counts as a possible match. At 4 chars a single wrong character is a
    /// 25% miss — too loose, it flagged unrelated plates.
    private static let minLengthForSubstitution = 5

    /// Every watchlist entry the event's plate reads matched, in watchlist
    /// order, one match per entry with the exact tier preferred. Candidates
    /// come from the OCR text the scan stored on the event AND plate-like
    /// words in the AI summary — search checks both, so the chips should
    /// too. Matching is per-plate-word: the old whole-summary substring
    /// match let a short entry like "8Y" flag any event whose summary said
    /// someone "walked by".
    static func matches(event: Event, in watchlist: [Watchlist]) -> [Match] {
        let candidates = (EventSearchMatcher.plateCandidates(in: event.plateText)
            + EventSearchMatcher.plateCandidates(in: event.summary))
            .map { EventSearchMatcher.normalizePlate($0) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return [] }

        var results: [Match] = []
        for entry in watchlist {
            let needle = EventSearchMatcher.normalizePlate(entry.plateText)
            guard !needle.isEmpty else { continue }
            if candidates.contains(needle) {
                results.append(Match(entry: entry, isExact: true))
                continue
            }
            // Below plausible-plate length only an exact match counts.
            guard needle.count >= 4 else { continue }
            // Bidirectional containment tolerates partial OCR reads (a
            // 5-char read of a 6-char watched plate). One substitution at
            // equal length tolerates a misread character the normalization
            // map doesn't cover (M↔N, E↔F).
            let isPossible = candidates.contains { candidate in
                candidate.contains(needle) || needle.contains(candidate)
                    || isOneSubstitutionApart(candidate, needle)
            }
            if isPossible {
                results.append(Match(entry: entry, isExact: false))
            }
        }
        return results
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
