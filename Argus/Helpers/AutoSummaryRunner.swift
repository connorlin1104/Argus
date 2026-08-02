//
//  AutoSummaryRunner.swift
//  Argus
//
//  Sequentially backfills Event.summary by calling EventSummarizer on each
//  event whose summary is empty. Mirrors VideoAnalyzer's observable progress
//  pattern so the toolbar can show a live indicator.
//

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class AutoSummaryRunner {
    /// Live progress state (drives toolbar UI).
    var isRunning: Bool = false
    var progress: Double = 0
    var currentLabel: String = ""
    var totalEvents: Int = 0
    var completedEvents: Int = 0

    private var task: Task<Void, Never>? = nil

    /// Process every event with an empty summary. Reuses
    /// EventSummarizer.summarize(event:detection:) per event with a per-event
    /// 25 s timeout so a stalled model can't hang the whole batch.
    func run(events: [Event], modelContext: ModelContext) {
        guard !isRunning else { return }
        // Placeholders count as unsummarized so a backfill can upgrade
        // "no activity detected yet" text once clips have real markers.
        let candidates = events.filter { EventSummarizer.isPlaceholderSummary($0.summary) }
        guard !candidates.isEmpty, EventSummarizer.isAvailable else { return }

        isRunning = true
        totalEvents = candidates.count
        completedEvents = 0
        progress = 0
        currentLabel = "Starting summaries…"

        task = Task { [weak self] in
            guard let self else { return }
            for event in candidates {
                if Task.isCancelled { break }
                self.currentLabel = "Summarizing \(event.timestamp.formatted(date: .abbreviated, time: .shortened))"
                // Build facts here on the main actor so the @Sendable closure
                // below only captures a Sendable Facts value — the @Model-backed
                // `event` never crosses the actor boundary. Matched clips'
                // detection markers give the model a timeline to narrate.
                let facts = EventSummarizer.makeFacts(
                    event: event,
                    detection: nil,
                    videos: matchedVideos(for: event, modelContext: modelContext)
                )
                let summary = await withTimeout(seconds: 25) {
                    await EventSummarizer.summarize(facts: facts)
                }
                if let summary, !summary.isEmpty {
                    event.summary = summary
                    try? modelContext.save()
                }
                self.completedEvents += 1
                self.progress = Double(self.completedEvents) / Double(max(1, self.totalEvents))
            }
            self.finish()
        }
    }

    /// Awaitable variant used by the post-import pipeline so each event's
    /// summary is written right after its clips are scanned, before the next
    /// event's scan begins. No-op (returns immediately) when nothing needs
    /// summarizing or another batch is already running.
    func runAndWait(events: [Event], modelContext: ModelContext) async {
        run(events: events, modelContext: modelContext)
        await task?.value
    }

    func cancel() {
        task?.cancel()
        finish()
    }

    /// Clips whose recording window covers this event's timestamp.
    private func matchedVideos(for event: Event,
                               modelContext: ModelContext) -> [VideoRecording] {
        let t = event.timestamp
        let descriptor = FetchDescriptor<VideoRecording>(
            predicate: #Predicate { video in
                video.startTime <= t && video.endTime >= t
            }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func finish() {
        isRunning = false
        currentLabel = ""
        progress = 0
        totalEvents = 0
        completedEvents = 0
        task = nil
    }
}

/// Per-call timeout for the FoundationModels session. Returns nil if the
/// `body` hasn't finished within `seconds`.
private func withTimeout<T: Sendable>(seconds: Double,
                                      body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
