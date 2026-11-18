//
//  EventNLSearcherTests.swift
//  ArgusTests
//
//  Pure-logic coverage of the natural-language search pipeline: plan
//  application, scoring, prompt building, and index mapping. The model
//  stages are never invoked — tests exercise everything deterministic
//  around them, following the SummaryQualityTests pattern.
//

import Foundation
import Testing
@testable import Argus

@MainActor
struct EventNLSearcherTests {

    // MARK: - Helpers

    private func event(summary: String = "",
                       tag: String = "unknown",
                       plateText: String = "",
                       timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Event {
        let event = Event(source: "Tesla", camera: "front", city: "Austin",
                          estLatitude: "30.0", estLongitude: "-97.0",
                          reason: "sentry_aware_object_detection",
                          timestamp: timestamp)
        event.summary = summary
        event.tag = tag
        event.plateText = plateText
        return event
    }

    private func candidates(_ events: [Event],
                            query: String = "") -> [EventNLSearcher.Candidate] {
        EventNLSearcher.makeCandidates(events: events, query: query)
    }

    /// A date at the given local hour, so time-of-day band tests aren't
    /// timezone-dependent.
    private func date(hour: Int, day: Int = 10) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 6, day: day, hour: hour, minute: 30))!
    }

    // MARK: - Fallback plan

    @Test func fallbackPlanTokenizesAndLowercases() {
        let plan = EventNLSearcher.fallbackPlan(query: "  Someone NEAR the Car ")
        #expect(plan.terms == ["someone", "near", "the", "car"])
        #expect(plan.daysBack == nil)
        #expect(plan.tags.isEmpty)
        #expect(plan.timeOfDay == nil)
    }

    // MARK: - Scoring

    @Test func scoreCountsTermsTagsAndRawMatch() {
        let plain = candidates([event(summary: "A person stayed near the rear camera.")])[0]
        let plan = EventNLSearcher.Plan(terms: ["person", "rear", "banana"])
        // Two term hits, no tag, no raw match.
        #expect(EventNLSearcher.score(plain, plan: plan) == 2)

        var tagged = plan
        tagged.tags = ["lingered"]
        let lingerer = candidates([event(summary: "A person stayed near the rear camera.",
                                         tag: "lingered")])[0]
        #expect(EventNLSearcher.score(lingerer, plan: tagged) == 4)
    }

    @Test func rawQueryMatchOutranksTermHits() {
        // The plate event matches the raw query (+3) and should beat an
        // event with a single term hit — a typed plate must surface even if
        // the model's expanded terms ignore it.
        let plateEvent = event(plateText: "8SNY185")
        let proseEvent = event(summary: "A vehicle passed by.")
        let pool = candidates([proseEvent, plateEvent], query: "8sny185")
        let plan = EventNLSearcher.Plan(terms: ["vehicle"])
        let ranked = EventNLSearcher.prefilter(pool, plan: plan)
        #expect(ranked.first?.id == pool[1].id)
    }

    // MARK: - Prefilter

    @Test func prefilterRanksByScoreThenRecency() {
        let older = event(summary: "A person approached.",
                          timestamp: Date(timeIntervalSince1970: 1_000))
        let newer = event(summary: "A person approached.",
                          timestamp: Date(timeIntervalSince1970: 2_000))
        let noHit = event(summary: "Nothing happened.",
                          timestamp: Date(timeIntervalSince1970: 3_000))
        let pool = candidates([older, noHit, newer])
        let plan = EventNLSearcher.Plan(terms: ["person"])
        let ranked = EventNLSearcher.prefilter(pool, plan: plan)
        #expect(ranked.map(\.id) == [pool[2].id, pool[0].id, pool[1].id])
    }

    @Test func prefilterAppliesDaysBackWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = event(summary: "x", timestamp: now.addingTimeInterval(-2 * 86_400))
        let old = event(summary: "x", timestamp: now.addingTimeInterval(-30 * 86_400))
        let pool = candidates([recent, old])
        var plan = EventNLSearcher.Plan()
        plan.daysBack = 7
        let ranked = EventNLSearcher.prefilter(pool, plan: plan, now: now)
        #expect(ranked.map(\.id) == [pool[0].id])
    }

    @Test func nightBandWrapsAroundMidnight() {
        let lateEvening = event(timestamp: date(hour: 23))
        let earlyMorning = event(timestamp: date(hour: 3))
        let noon = event(timestamp: date(hour: 12))
        let pool = candidates([lateEvening, earlyMorning, noon])
        var plan = EventNLSearcher.Plan()
        plan.timeOfDay = .night
        let ranked = EventNLSearcher.prefilter(pool, plan: plan)
        #expect(Set(ranked.map(\.id)) == Set([pool[0].id, pool[1].id]))
    }

    @Test func emptyingTimeFiltersAreRelaxed() {
        // Every event is months old — a hallucinated "last week" must not
        // produce zero results; the window is dropped instead.
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = event(summary: "A person approached.",
                        timestamp: now.addingTimeInterval(-90 * 86_400))
        let pool = candidates([old])
        var plan = EventNLSearcher.Plan(terms: ["person"])
        plan.daysBack = 7
        let ranked = EventNLSearcher.prefilter(pool, plan: plan, now: now)
        #expect(ranked.count == 1)
    }

    @Test func prefilterCapsAtLimit() {
        let pool = candidates((0..<40).map { i in
            event(timestamp: Date(timeIntervalSince1970: Double(i)))
        })
        let ranked = EventNLSearcher.prefilter(pool, plan: EventNLSearcher.Plan())
        #expect(ranked.count == EventNLSearcher.candidateLimit)
    }

    // MARK: - Prompt lines

    @Test func promptLinesNumberEntriesAndClipSummaries() {
        let long = String(repeating: "word ", count: 60)  // 300 chars
        let pool = candidates([
            event(summary: "Short summary.", tag: "lingered"),
            event(summary: long),
        ])
        let lines = EventNLSearcher.promptLines(for: pool)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("0 | "))
        #expect(lines[0].contains("lingered"))
        #expect(lines[0].contains("Short summary."))
        #expect(lines[1].hasPrefix("1 | "))
        #expect(lines[1].hasSuffix("…"))
        // Word-boundary truncation never cuts mid-word: the clipped text is
        // whole "word" repetitions.
        #expect(!lines[1].contains("wor…"))
    }

    @Test func placeholderSummariesNeverReachThePrompt() {
        // Empty summaries are placeholders; the candidate line carries the
        // metadata only.
        let pool = candidates([event(summary: "", tag: "touched")])
        #expect(pool[0].summary.isEmpty)
        let lines = EventNLSearcher.promptLines(for: pool)
        #expect(lines[0].contains("(no summary)"))
    }

    @Test func clipKeepsShortTextAndTruncatesLongText() {
        #expect(EventNLSearcher.clip("short", to: 150) == "short")
        let clipped = EventNLSearcher.clip("aaa bbb ccc ddd", to: 11)
        #expect(clipped == "aaa bbb…")
    }

    // MARK: - Index mapping

    @Test func mapIndicesDropsJunkAndPreservesOrder() {
        let pool = candidates([event(), event(), event()])
        let ids = EventNLSearcher.mapIndices([5, 1, 1, -1, 0, 99], candidates: pool)
        #expect(ids == [pool[1].id, pool[0].id])
        #expect(EventNLSearcher.mapIndices([], candidates: pool).isEmpty)
    }

    // MARK: - Candidate snapshot

    @Test func makeCandidatesMirrorsSearchFields() {
        let source = event(summary: "A person approached the car.",
                           tag: "approached", plateText: "8SNY185")
        source.customName = "Parking lot visitor"
        let snapshot = candidates([source], query: "austin")[0]
        #expect(snapshot.haystack.contains("austin"))
        #expect(snapshot.haystack.contains("a person approached the car."))
        #expect(snapshot.haystack.contains("parking lot visitor"))
        #expect(snapshot.matchesRawQuery)
        #expect(snapshot.camera == "Front")
    }
}
