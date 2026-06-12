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
        let candidates = events.filter { $0.summary.isEmpty }
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
                let summary = await withTimeout(seconds: 25) {
                    await EventSummarizer.summarize(event: event, detection: nil)
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

    func cancel() {
        task?.cancel()
        finish()
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
