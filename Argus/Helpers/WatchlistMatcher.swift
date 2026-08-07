//
//  WatchlistMatcher.swift
//  Argus
//
//  Matches an event's plate text against a Watchlist. Entry-centric: every
//  watched plate the event's footage detected gets its own match, each
//  carrying a confidence tier. Exact means the read is literally the watched
//  plate; "Possibly" means the read differs only by look-alike characters
//  (1/L, 5/S, 8/B, M/N…) or is a partial read. Characters that don't look
//  alike never match — a blurry 8SNY185 read as 8SNYLBS should badge as
//  "Possibly", and an unrelated plate shouldn't badge at all.
//

import Foundation

enum WatchlistMatcher {

    /// A watchlist hit on an event. `isExact` is false for the fuzzy tiers
    /// (look-alike characters / partial read) — the UI prefixes those with
    /// "Possibly".
    struct Match {
        let entry: Watchlist
        let isExact: Bool
    }

    /// Glyphs OCR plausibly confuses with each other on a plate. Two
    /// characters are interchangeable for the "Possibly" tier when they share
    /// a class; anything else is a real mismatch and kills the match.
    private static let lookAlikeClasses: [String] = [
        "0OQD", "1IL", "2Z", "5S", "8B", "6G", "CG", "MN", "EF", "UV",
    ]

    /// Every watchlist entry the event's plate reads matched, in watchlist
    /// order, one match per entry with the exact tier preferred. Candidates
    /// come from the OCR text the scan stored on the event, plus plate-like
    /// words in the AI summary, the event's name, and its notes — every
    /// text field the search bar can find a plate in should also chip.
    /// Matching is per-plate-word: the old whole-summary substring match
    /// let a short entry like "8Y" flag any event whose summary said
    /// someone "walked by".
    static func matches(event: Event, in watchlist: [Watchlist]) -> [Match] {
        let candidates = EventSearchMatcher.plateWords(in: event.plateText)
            + EventSearchMatcher.plateWords(in: event.summary)
            + EventSearchMatcher.plateWords(in: event.customName)
            + EventSearchMatcher.plateWords(in: event.notes)
        guard !candidates.isEmpty else { return [] }

        var results: [Match] = []
        for entry in watchlist {
            let needle = canonicalPlate(entry.plateText)
            guard !needle.isEmpty else { continue }
            if candidates.contains(needle) {
                results.append(Match(entry: entry, isExact: true))
                continue
            }
            // Below plausible-plate length only an exact match counts.
            guard needle.count >= 4 else { continue }
            if candidates.contains(where: { looksLike($0, needle) }) {
                results.append(Match(entry: entry, isExact: false))
            }
        }
        return results
    }

    /// The watchlist entry uppercased with formatting stripped, so a user-
    /// typed "8sny-185" compares as "8SNY185".
    private static func canonicalPlate(_ raw: String) -> String {
        String(raw.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    /// True when the shorter string appears somewhere in the longer with
    /// every character equal or a look-alike. Equal lengths compare the whole
    /// string (a misread character or three); unequal lengths slide a window
    /// (a partial read of a longer plate).
    private static func looksLike(_ a: String, _ b: String) -> Bool {
        let long = Array(a.count >= b.count ? a : b)
        let short = Array(a.count >= b.count ? b : a)
        guard short.count >= 4 else { return false }
        for start in 0...(long.count - short.count) {
            var matched = true
            for i in 0..<short.count where !isLookAlike(long[start + i], short[i]) {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    private static func isLookAlike(_ a: Character, _ b: Character) -> Bool {
        if a == b { return true }
        return lookAlikeClasses.contains { $0.contains(a) && $0.contains(b) }
    }
}
