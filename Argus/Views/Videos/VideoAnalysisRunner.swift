//
//  VideoAnalysisRunner.swift
//  Argus
//
//  Pulls the "Analyze all" batch loop out of VideoListView so the view stays small.
//  Walks each VideoRecording, runs DetectionEngine, writes back detection markers,
//  and inserts a new Event when a human comes within the proximity threshold.
//

import Foundation
import SwiftData

enum VideoAnalysisRunner {

    @MainActor
    static func runAnalysis(
        videos: [VideoRecording],
        analyzer: VideoAnalyzer,
        modelContext: ModelContext
    ) async {
        analyzer.beginBatch(total: videos.count)
        defer { analyzer.endBatch() }

        for video in videos {
            guard let videoURL = resolveBookmark(bookmarkData: video.bookmark) else {
                analyzer.tickBatch(label: "Skipped (bookmark)")
                continue
            }
            let didAccess = videoURL.startAccessingSecurityScopedResource()
            defer { if didAccess { videoURL.stopAccessingSecurityScopedResource() } }

            analyzer.currentTaskLabel = "Analyzing \(videoURL.lastPathComponent)"
            let (startTime, cameraName) = parseFilename(videoURL.lastPathComponent)
            let detections = await analyzer.analyzeVideo(url: videoURL, cameraID: cameraName)
            let summary = VideoAnalyzer.summarize(detections: detections)
            let tag = classifyEventTag(summary)

            // Persist detection markers so the scrubber can show them later.
            let markers = detections.map {
                DetectionMarker(kind: $0.kind.rawValue, timestampMs: $0.timestampMs)
            }
            video.setMarkers(markers)

            if analyzer.firstProximityEvent(in: detections) != nil,
               let startTime {
                // Dedupe: if an existing event's timestamp falls within this
                // video's recording window, enrich it instead of inserting a
                // duplicate. Imported Sentry events already cover the incident;
                // the scan just adds the score/tag/AI summary.
                if let existing = existingEvent(
                    inWindow: startTime...video.endTime,
                    modelContext: modelContext
                ) {
                    if summary.score > existing.interestingnessScore {
                        existing.interestingnessScore = summary.score
                    }
                    if existing.tag == "unknown" {
                        existing.tag = tag.rawValue
                    }
                    if existing.summary.isEmpty {
                        existing.summary = await EventSummarizer.summarize(
                            event: existing,
                            detection: summary
                        )
                    }
                } else {
                    let event = buildEvent(
                        cameraName: cameraName,
                        startTime: startTime,
                        summary: summary,
                        tag: tag
                    )
                    event.summary = await EventSummarizer.summarize(event: event, detection: summary)
                    modelContext.insert(event)
                }
                do { try modelContext.save() } catch { print("save failed: \(error)") }
            }
            analyzer.tickBatch(label: "Done \(videoURL.lastPathComponent)")
        }
    }

    /// Look up an existing Event whose timestamp falls inside the given window.
    /// Used to avoid creating scan-duplicates of imported Sentry events.
    @MainActor
    private static func existingEvent(
        inWindow window: ClosedRange<Date>,
        modelContext: ModelContext
    ) -> Event? {
        let lower = window.lowerBound
        let upper = window.upperBound
        let descriptor = FetchDescriptor<Event>(
            predicate: #Predicate<Event> { event in
                event.timestamp >= lower && event.timestamp <= upper
            }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// Build the Event that gets inserted when a video trips the proximity
    /// check and no existing event covers this window. Reason is a short
    /// human-readable phrase — detection metrics live on `interestingnessScore`
    /// and the AI summary, not in the trigger label.
    private static func buildEvent(cameraName: String,
                                   startTime: Date,
                                   summary: DetectionSummary,
                                   tag: EventTag) -> Event {
        return Event(
            source: "App",
            camera: cameraName,
            city: "unknown",
            estLatitude: "0",
            estLongitude: "0",
            reason: "Detected nearby person",
            timestamp: startTime,
            interestingnessScore: summary.score,
            tag: tag.rawValue
        )
    }

    private static func resolveBookmark(bookmarkData: Data) -> URL? {
        do {
            var isStale = false
            #if os(iOS)
            return try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
            #else
            return try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            #endif
        } catch {
            print("Bookmark resolution error: \(error)")
            return nil
        }
    }
}
