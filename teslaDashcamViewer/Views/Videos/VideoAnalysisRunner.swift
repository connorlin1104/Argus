//
//  VideoAnalysisRunner.swift
//  teslaDashcamViewer
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

            if let proximityMs = analyzer.firstProximityEvent(in: detections),
               let startTime {
                let event = buildEvent(
                    cameraName: cameraName,
                    startTime: startTime,
                    summary: summary,
                    tag: tag,
                    proximityMs: proximityMs
                )
                let llmSummary = await EventSummarizer.summarize(event: event, detection: summary)
                event.summary = llmSummary
                modelContext.insert(event)
                do { try modelContext.save() } catch { print("save failed: \(error)") }
            }
            analyzer.tickBatch(label: "Done \(videoURL.lastPathComponent)")
        }
    }

    /// Build the Event that gets inserted when a video trips the proximity check.
    private static func buildEvent(cameraName: String,
                                   startTime: Date,
                                   summary: DetectionSummary,
                                   tag: EventTag,
                                   proximityMs: Int) -> Event {
        let closest = summary.closestHumanMeters ?? 0
        var reason = String(
            format: "human within %.1fm at %dms (presence %.1fs)",
            closest, proximityMs, summary.humanPresenceSeconds
        )
        if let plate = summary.firstPlateText {
            reason += " · plate \(plate)"
        }
        return Event(
            source: "App",
            camera: cameraName,
            city: "unknown",
            estLatitude: "0",
            estLongitude: "0",
            reason: reason,
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
