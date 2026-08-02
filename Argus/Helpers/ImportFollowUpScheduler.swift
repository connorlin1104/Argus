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

    /// TUNING: concurrent clip scans for the per-event priority slices.
    #if os(iOS)
    private let priorityConcurrency = 2
    #else
    private let priorityConcurrency = 4
    #endif

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

        // Event-by-event: scan one event's clips, summarize that event, then
        // move to the next. Scanning the entire import before writing any
        // summary left every event with an empty scrubber and a placeholder
        // summary until the whole batch finished (minutes on big imports);
        // this way the newest event is fully usable within seconds.
        var remaining = videos
        var chunks: [(event: Event, videos: [VideoRecording])] = []
        for event in events.sorted(by: { $0.timestamp > $1.timestamp }) {
            let t = event.timestamp
            let matched = remaining.filter { $0.startTime <= t && $0.endTime >= t }
            remaining.removeAll { clip in matched.contains { $0 === clip } }
            // The trigger camera's clip is the one the user opens first —
            // scan it ahead of the other angles.
            let triggerCam = TeslaCamera.canonical(event.camera)
            let ordered = matched.sorted { a, b in
                (TeslaCamera.canonical(a.camera) == triggerCam ? 0 : 1)
                    < (TeslaCamera.canonical(b.camera) == triggerCam ? 0 : 1)
            }
            chunks.append((event, ordered))
        }

        // One batch across all chunks so the Videos-tab progress chip shows
        // overall progress instead of restarting per event.
        let matchedCount = chunks.reduce(0) { $0 + $1.videos.count }
        VideoAnalyzer.shared.beginBatch(total: matchedCount)
        for chunk in chunks {
            if !chunk.videos.isEmpty {
                await VideoAnalysisRunner.runAnalysis(
                    videos: chunk.videos,
                    analyzer: VideoAnalyzer.shared,
                    modelContext: modelContext,
                    manageBatch: false,
                    // A chunk is one event's camera angles (~4 clips) and the
                    // user is actively waiting on it. On the Mac, scan them
                    // all at once; iPhones can't afford 4 concurrent decode
                    // pipelines while the user may also be playing clips.
                    maxConcurrent: priorityConcurrency
                )
            }
            if EventSummarizer.isAvailable {
                await EventsImportRunner.autoSummaryRunner.runAndWait(
                    events: [chunk.event],
                    modelContext: modelContext
                )
            }
        }
        // Clips no event's timestamp falls inside (the other minutes of a
        // Sentry save) are NOT scanned automatically — sweeping the whole
        // library pegged the phone for the better part of an hour on big
        // imports, and the timeline already surfaces those clips. The
        // Videos tab's manual scan covers them if the user wants markers.
        VideoAnalyzer.shared.endBatch()
    }
}
