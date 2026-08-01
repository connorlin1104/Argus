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

    /// TUNING: how many clips run through Vision at once. Detection is
    /// CPU/Neural-Engine heavy, so a small window overlaps file I/O with
    /// compute without starving the UI; higher values give diminishing
    /// returns and can thrash on thermally-limited devices.
    private static let maxConcurrentScans = 2

    /// The Sendable slice of a VideoRecording that the off-main detection
    /// tasks need — @Model objects themselves must stay on the main actor.
    private struct ScanItem: Sendable {
        let index: Int
        let url: URL
        let vfovDegrees: Double
    }

    @MainActor
    static func runAnalysis(
        videos: [VideoRecording],
        analyzer: VideoAnalyzer,
        modelContext: ModelContext
    ) async {
        analyzer.beginBatch(total: videos.count)
        defer { analyzer.endBatch() }

        // Resolve bookmarks up front on the main actor; only Sendable data
        // (URL + FOV) crosses into the detection tasks.
        var items: [ScanItem] = []
        for (index, video) in videos.enumerated() {
            guard let url = BookmarkResolver.resolveURL(for: video) else {
                analyzer.tickBatch(label: "Skipped (bookmark)")
                continue
            }
            let (_, cameraName) = parseFilename(url.lastPathComponent)
            items.append(ScanItem(
                index: index,
                url: url,
                vfovDegrees: TeslaCamera.verticalFOVDegrees(for: cameraName)
            ))
        }

        // Sliding window: at most maxConcurrentScans clips are in Vision at
        // any moment. Results are applied on the main actor as each clip
        // finishes, so the model writes stay serialized while detection
        // overlaps across clips.
        await withTaskGroup(of: (index: Int, detections: [Detection]).self) { group in
            var next = 0
            func addNextScan() {
                guard next < items.count else { return }
                let item = items[next]
                next += 1
                group.addTask {
                    let didAccess = item.url.startAccessingSecurityScopedResource()
                    defer { if didAccess { item.url.stopAccessingSecurityScopedResource() } }
                    let detections = await DetectionEngine.runDetections(
                        url: item.url,
                        vfovDegrees: item.vfovDegrees
                    )
                    return (item.index, detections)
                }
            }
            for _ in 0..<maxConcurrentScans { addNextScan() }

            while let result = await group.next() {
                addNextScan()
                let video = videos[result.index]
                await apply(
                    detections: result.detections,
                    to: video,
                    analyzer: analyzer,
                    modelContext: modelContext
                )
                analyzer.tickBatch(label: "Done \(video.url.lastPathComponent)")
            }
        }
    }

    /// Write one clip's detection results back into the store: markers on the
    /// VideoRecording, plus an enriched or freshly inserted Event when a
    /// human came within the proximity threshold.
    @MainActor
    private static func apply(
        detections: [Detection],
        to video: VideoRecording,
        analyzer: VideoAnalyzer,
        modelContext: ModelContext
    ) async {
        let summary = VideoAnalyzer.summarize(detections: detections)
        let tag = classifyEventTag(summary)
        let (startTime, cameraName) = parseFilename(video.url.lastPathComponent)

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

}
