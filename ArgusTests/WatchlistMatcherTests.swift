//
//  WatchlistMatcherTests.swift
//  ArgusTests
//
//  Pure-logic tests for watchlist plate matching and the per-plate match
//  counts shown in Settings. Models are plain instances — WatchlistMatcher
//  never touches a ModelContext.
//

import Foundation
import Testing
@testable import Argus

@MainActor
struct WatchlistMatcherTests {

    private func event(plateText: String = "", summary: String = "",
                       customName: String = "", notes: String = "") -> Event {
        let event = Event(source: "Tesla", camera: "front", city: "Austin",
                          estLatitude: "30.0", estLongitude: "-97.0",
                          reason: "sentry_aware_object_detection",
                          timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        event.plateText = plateText
        event.summary = summary
        event.customName = customName
        event.notes = notes
        return event
    }

    @Test func exactMatchCountsAcrossEvents() {
        let entry = Watchlist(plateText: "8sny-185", note: "", colorHex: "#FF0000")
        let events = [
            event(plateText: "8SNY185"),          // exact via OCR field
            event(summary: "A sedan with plate 8SNY185 lingered."), // exact via summary
            event(plateText: "XYZ9876"),          // unrelated
        ]
        #expect(WatchlistMatcher.matchCount(entry: entry, events: events) == 2)
    }

    @Test func lookAlikeGlyphsCountAsMatch() {
        // L↔1 and B↔8 are look-alike classes — a blurry read still matches.
        let entry = Watchlist(plateText: "8SNY185", note: "", colorHex: "#FF0000")
        let events = [event(plateText: "8SNYLB5")]
        #expect(WatchlistMatcher.matchCount(entry: entry, events: events) == 1)
        let matches = WatchlistMatcher.matches(event: events[0], in: [entry])
        #expect(matches.count == 1)
        #expect(matches[0].isExact == false)
    }

    @Test func nonLookAlikeCharactersNeverMatch() {
        // 7 and 1 share no glyph class — this is a different plate.
        let entry = Watchlist(plateText: "8SNY785", note: "", colorHex: "#FF0000")
        let events = [event(plateText: "8SNY185")]
        #expect(WatchlistMatcher.matchCount(entry: entry, events: events) == 0)
    }

    @Test func unrelatedEventsCountZero() {
        let entry = Watchlist(plateText: "8SNY185", note: "", colorHex: "#FF0000")
        let events = [
            event(plateText: "ABC1234"),
            event(summary: "Nothing plate-like here."),
            event(),
        ]
        #expect(WatchlistMatcher.matchCount(entry: entry, events: events) == 0)
    }

    @Test func shortEntryNeverFuzzyMatches() {
        // Below plausible-plate length, prose words must not badge — plate
        // candidates are 4+ chars, so a 2-char entry can't match anything.
        let entry = Watchlist(plateText: "8Y", note: "", colorHex: "#FF0000")
        let events = [event(summary: "Someone walked by the car 8YKR221.")]
        #expect(WatchlistMatcher.matchCount(entry: entry, events: events) == 0)
    }

    @Test func nameAndNotesFieldsAreMatched() {
        let entry = Watchlist(plateText: "8SNY185", note: "", colorHex: "#FF0000")
        let byName = event(customName: "White truck 8SNY185 again")
        let byNotes = event(notes: "Saw 8SNY185 parked across the street")
        #expect(WatchlistMatcher.matchCount(entry: entry, events: [byName, byNotes]) == 2)
    }
}
