//
//  ImportFollowUpScheduler.swift
//  Argus
//
//  Queues the autonomous post-import work (AI summaries + Vision clip scans)
//  so it only starts once importing has fully settled. Big imports used to
//  race their own follow-up work: each import kicked off a scan immediately,
//  and any import that landed while a scan was running had its batch dropped
//  (the analyzer is single-flight). Now every import enqueues its fresh
//  models here; the drain waits for all in-flight imports plus a quiet
//  period, merges the queued batches, and runs the follow-ups once.
//

import Foundation
import SwiftData

@MainActor
final class ImportFollowUpScheduler {

    static let shared = ImportFollowUpScheduler()

    /// TUNING: quiet period after the last import before auto-work starts.
    /// Long enough to bridge back-to-back picker sessions, short enough that
    /// a single import doesn't feel unresponsive.
    private let settleSeconds: Double = 5

    private var activeImports = 0
    private var pendingEvents: [Event] = []
    private var pendingVideos: [VideoRecording] = []
    private var drainTask: Task<Void, Never>? = nil

    /// Call when an import begins. Pauses any scheduled (not yet started)
    /// drain so the follow-up work never overlaps a running import.
    func importWillStart() {
        activeImports += 1
        drainTask?.cancel()
        drainTask = nil
    }

    /// Call when an import finishes, with the models it actually inserted.
    /// Schedules the merged follow-up pass once no imports remain in flight.
    func importDidFinish(events: [Event], videos: [VideoRecording], modelContext: ModelContext) {
        pendingEvents.append(contentsOf: events)
        pendingVideos.append(contentsOf: videos)
        activeImports = max(0, activeImports - 1)
        scheduleDrain(modelContext: modelContext)
    }

    private func scheduleDrain(modelContext: ModelContext) {
        guard activeImports == 0 else { return }
        guard !pendingEvents.isEmpty || !pendingVideos.isEmpty else { return }
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.settleSeconds ?? 0))
            guard !Task.isCancelled, let self else { return }
            await self.drain(modelContext: modelContext)
        }
    }

    private func drain(modelContext: ModelContext) async {
        // Another import may have started during the quiet period; it will
        // reschedule us when it finishes.
        guard activeImports == 0 else { return }
        let events = pendingEvents
        let videos = pendingVideos
        pendingEvents = []
        pendingVideos = []
        drainTask = nil

        // Wait out any manually started scan/summary run instead of dropping
        // the batch (both runners are single-flight).
        while VideoAnalyzer.shared.isAnalyzing || EventsImportRunner.autoSummaryRunner.isRunning {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }

        // AI: backfill summaries for freshly imported events when the
        // on-device model is available.
        if EventSummarizer.isAvailable && !events.isEmpty {
            EventsImportRunner.autoSummaryRunner.run(events: events, modelContext: modelContext)
        }

        // Vision: auto-scan the new clips for people / vehicles / plates so
        // detection markers and tags appear without pressing "Scan clips".
        if !videos.isEmpty {
            await VideoAnalysisRunner.runAnalysis(
                videos: videos,
                analyzer: VideoAnalyzer.shared,
                modelContext: modelContext
            )
        }
    }
}
