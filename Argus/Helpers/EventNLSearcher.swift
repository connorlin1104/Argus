//
//  EventNLSearcher.swift
//  Argus
//
//  Natural-language search over events. Pressing Return in the events-list
//  search field runs a two-stage pass on the on-device FoundationModels
//  stack (same availability gating as EventSummarizer):
//    1. One model call turns the query into a Plan — synonym search terms,
//       a days-back window, behavior tags, time of day. Summaries say "rear
//       camera", not "trunk", and never mention time or date, so literal
//       matching can't satisfy queries like "near the trunk at night".
//    2. A deterministic prefilter applies the plan and keeps the top 25
//       candidates — the model's 4k-token context fits only ~60 summary
//       lines, and the library holds more.
//    3. One model call reranks the numbered candidate lines semantically.
//  Every stage degrades deterministically: a failed plan falls back to the
//  raw query tokens, a failed rerank returns the prefiltered order. Junk
//  model output can only misrank results, never crash or hang (15s timeout
//  per call).
//

import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

enum EventNLSearcher {

    /// Sendable snapshot of one event, built on the main actor so the
    /// @Model never crosses an actor boundary (same rule as
    /// EventSummarizer.Facts).
    struct Candidate: Sendable, Identifiable {
        let id: PersistentIdentifier
        let timestamp: Date
        let tag: String
        /// Display name of the triggering camera ("" when unknown).
        let camera: String
        /// Summary prose; "" when the stored summary is a placeholder, so
        /// boilerplate never reaches the model or scores term hits.
        let summary: String
        /// Lowercased searchable fields (EventSearchMatcher's haystack).
        let haystack: [String]
        /// Whether EventSearchMatcher matches the raw query — keeps literal
        /// hits (plates especially) ranked even if the model drops them.
        let matchesRawQuery: Bool
    }

    /// What stage 1 extracts from the query. Applied deterministically by
    /// `prefilter`, so a junk plan can only misrank, never break.
    struct Plan: Sendable, Equatable {
        var terms: [String] = []
        var daysBack: Int? = nil
        var tags: [String] = []
        var timeOfDay: TimeOfDay? = nil
    }

    enum TimeOfDay: String, Sendable, CaseIterable {
        case night, morning, afternoon, evening

        /// Hour band [start, end) — night wraps around midnight.
        var hours: (start: Int, end: Int) {
            switch self {
            case .night:     return (21, 6)
            case .morning:   return (6, 12)
            case .afternoon: return (12, 17)
            case .evening:   return (17, 21)
            }
        }

        func contains(hour: Int) -> Bool {
            let (start, end) = hours
            return start <= end ? (hour >= start && hour < end)
                                : (hour >= start || hour < end)
        }
    }

    /// TUNING: candidates sent to the stage-2 rerank. A candidate line is
    /// ~50 tokens, so 25 lines + instructions + schema ≈ 1,600 tokens —
    /// under half the model's 4,096 context. Don't raise past ~40.
    static let candidateLimit = 25
    /// TUNING: summary length inside a stage-2 candidate line.
    static let summaryClipLength = 150

    static var isAvailable: Bool { EventSummarizer.isAvailable }

    /// Search-worded availability copy (EventSummarizer's own strings talk
    /// about generating summaries). The availability LOGIC stays there.
    static var unavailabilityExplanation: String? {
        isAvailable ? nil :
        "AI search needs Apple Intelligence, which isn't available right now. Keyword matches are shown instead."
    }

    // MARK: - Main-actor snapshot

    /// Snapshot the events into Sendable candidates. Runs on the main actor
    /// while the caller still holds the SwiftData models; everything after
    /// this point works on plain values.
    @MainActor
    static func makeCandidates(events: [Event], query: String) -> [Candidate] {
        events.map { event in
            Candidate(
                id: event.persistentModelID,
                timestamp: event.timestamp,
                tag: event.tag,
                camera: TeslaCamera.displayName(for: event.camera),
                summary: EventSummarizer.isPlaceholderSummary(event.summary) ? "" : event.summary,
                haystack: EventSearchMatcher.haystack(for: event),
                matchesRawQuery: EventSearchMatcher.matches(event: event, query: query)
            )
        }
    }

    // MARK: - Deterministic pipeline (no model)

    /// Plan used when the model can't produce one: the raw query tokens
    /// become the search terms.
    static func fallbackPlan(query: String) -> Plan {
        Plan(terms: tokens(in: query))
    }

    static func tokens(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Term hits count 1 each; a matching behavior tag counts extra because
    /// it's a confirmed classification, not prose luck; a raw-query match
    /// (plates especially) outranks both.
    static func score(_ candidate: Candidate, plan: Plan) -> Int {
        var score = 0
        for term in plan.terms
        where candidate.haystack.contains(where: { $0.contains(term) }) {
            score += 1
        }
        if plan.tags.contains(candidate.tag) { score += 2 }
        if candidate.matchesRawQuery { score += 3 }
        return score
    }

    /// Apply the plan's hard time filters, score what's left, keep the top
    /// `limit` (score desc, then newest first). A time filter that empties
    /// the pool is treated as hallucinated and relaxed — wrong-but-nonempty
    /// results beat a silent zero.
    static func prefilter(_ candidates: [Candidate], plan: Plan,
                          now: Date = .now,
                          limit: Int = candidateLimit) -> [Candidate] {
        var pool = candidates
        if let daysBack = plan.daysBack {
            let cutoff = now.addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
            let windowed = pool.filter { $0.timestamp >= cutoff }
            if !windowed.isEmpty { pool = windowed }
        }
        if let timeOfDay = plan.timeOfDay {
            let calendar = Calendar.current
            let banded = pool.filter {
                timeOfDay.contains(hour: calendar.component(.hour, from: $0.timestamp))
            }
            if !banded.isEmpty { pool = banded }
        }
        return pool
            .map { (candidate: $0, score: score($0, plan: plan)) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.candidate.timestamp > $1.candidate.timestamp
            }
            .prefix(limit)
            .map(\.candidate)
    }

    /// Numbered compact lines for the stage-2 prompt:
    /// `3 | Nov 12, 2025 at 9:41 PM | lingered | Rear | A person stayed…`
    static func promptLines(for candidates: [Candidate]) -> [String] {
        candidates.enumerated().map { index, candidate in
            var parts = [
                "\(index)",
                candidate.timestamp.formatted(date: .abbreviated, time: .shortened)
            ]
            if candidate.tag != "unknown" { parts.append(candidate.tag) }
            if !candidate.camera.isEmpty { parts.append(candidate.camera) }
            parts.append(candidate.summary.isEmpty
                         ? "(no summary)"
                         : clip(candidate.summary, to: summaryClipLength))
            return parts.joined(separator: " | ")
        }
    }

    /// Truncate at a word boundary so the prompt never ends mid-word.
    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        if let lastSpace = prefix.lastIndex(where: \.isWhitespace) {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }

    /// Model indices → candidate IDs: out-of-range dropped, duplicates
    /// deduped, order preserved.
    static func mapIndices(_ indices: [Int],
                           candidates: [Candidate]) -> [PersistentIdentifier] {
        var seen = Set<Int>()
        var out: [PersistentIdentifier] = []
        for index in indices
        where candidates.indices.contains(index) && seen.insert(index).inserted {
            out.append(candidates[index].id)
        }
        return out
    }

    // MARK: - Orchestrator

    /// The full two-stage search. Returns ranked IDs; [] means the search
    /// ran and found nothing. Safe off-actor — candidates are Sendable.
    static func search(query: String,
                       candidates: [Candidate]) async -> [PersistentIdentifier] {
        guard !candidates.isEmpty else { return [] }

        // Stage 1: model query plan (nil on failure/timeout/unavailable).
        var plan: Plan? = nil
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            plan = (await withTimeout(seconds: 15) { await generatePlan(query: query) }) ?? nil
        }
        #endif
        var merged = plan ?? fallbackPlan(query: query)
        // Union the raw tokens so a literal the model dropped (a plate, an
        // exact word) still scores.
        for token in tokens(in: query) where !merged.terms.contains(token) {
            merged.terms.append(token)
        }
        if Task.isCancelled { return [] }

        let shortlist = prefilter(candidates, plan: merged)
        guard !shortlist.isEmpty else { return [] }

        // Stage 2: semantic rerank. nil = call failed → prefiltered order;
        // [] = the model ran and says nothing matches → honest empty result.
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            if let ranked = (await withTimeout(seconds: 15) {
                await rerank(query: query, shortlist: shortlist)
            }) ?? nil {
                return Task.isCancelled ? [] : ranked
            }
        }
        #endif
        if Task.isCancelled { return [] }
        return shortlist.map(\.id)
    }
}

// MARK: - Model calls

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
extension EventNLSearcher {

    /// Keep @Guide descriptions short — the generated schema counts against
    /// the model's context window.
    @Generable(description: "A plan for searching dashcam security events")
    struct QueryPlan {
        @Guide(description: "Words likely to appear in event summaries, including synonyms (trunk means rear)", .maximumCount(8))
        var searchTerms: [String]
        @Guide(description: "Days back the query covers, like 7 for last week. Omit when no timeframe is mentioned.")
        var daysBack: Int?
        @Guide(description: "Behavior tags the query implies", .maximumCount(3))
        var tags: [SearchTag]
        @Guide(description: "Time of day the query mentions, if any")
        var timeOfDay: SearchTimeOfDay?
    }

    /// Constrained sampling can't produce a case outside these — no need to
    /// validate the model's tag strings. `unknown` is deliberately absent
    /// (useless as a filter).
    @Generable(description: "A detected behavior kind")
    enum SearchTag {
        case touched, lingered, approached, passing, vehicle, noise
    }

    @Generable(description: "A part of the day")
    enum SearchTimeOfDay {
        case night, morning, afternoon, evening
    }

    @Generable(description: "Events that match the search")
    struct RankedMatches {
        @Guide(description: "Index numbers of matching events, most relevant first. Empty when none match.", .maximumCount(10))
        var indices: [Int]
    }

    /// Stage 1: query → Plan. Nil on any failure — the caller falls back to
    /// raw tokens.
    static func generatePlan(query: String) async -> Plan? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
            Convert a search query about Tesla dashcam security events into \
            a search plan. Event summaries describe people and vehicles seen \
            near a parked car by its Front, Rear, Left, and Right cameras. \
            Extract only what the query states — never invent a timeframe, \
            tag, or time of day the query doesn't mention.
            """)
        do {
            let response = try await session.respond(
                to: query,
                generating: QueryPlan.self,
                options: GenerationOptions(sampling: .greedy))
            let generated = response.content
            var plan = Plan()
            plan.terms = generated.searchTerms
                .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let daysBack = generated.daysBack {
                plan.daysBack = min(max(daysBack, 1), 365)
            }
            plan.tags = generated.tags.map { String(describing: $0) }
            plan.timeOfDay = generated.timeOfDay
                .flatMap { TimeOfDay(rawValue: String(describing: $0)) }
            return plan
        } catch {
            print("EventNLSearcher: query plan failed: \(error)")
            return nil
        }
    }

    /// Stage 2: rank the shortlist against the query. Nil on call failure
    /// (caller shows prefiltered order); empty when the model says nothing
    /// matches.
    static func rerank(query: String,
                       shortlist: [Candidate]) async -> [PersistentIdentifier]? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
            You match a search query against a numbered list of dashcam \
            security events. Return the index numbers of the events that \
            match the query's meaning, most relevant first. Include only \
            events that actually relate to the query; return no indices \
            when none do.
            """)
        let prompt = """
        Query: \(query)

        Events:
        \(promptLines(for: shortlist).joined(separator: "\n"))
        """
        do {
            let response = try await session.respond(
                to: prompt,
                generating: RankedMatches.self,
                options: GenerationOptions(sampling: .greedy))
            return mapIndices(response.content.indices, candidates: shortlist)
        } catch {
            print("EventNLSearcher: rerank failed: \(error)")
            return nil
        }
    }
}
#endif
