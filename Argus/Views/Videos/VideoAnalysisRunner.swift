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

    /// - Parameter manageBatch: pass false when the caller drives the
    ///   analyzer's batch lifecycle itself (the post-import scheduler runs
    ///   several per-event slices under one batch so the progress chip
    ///   doesn't restart per event). Ticks are emitted either way.
    /// - Parameter maxConcurrent: how many clips run through Vision at once.
    ///   Defaults to the thermally-safe bulk value; the post-import scheduler
    ///   passes a higher value for the small per-event priority slices so the
    ///   event the user is waiting on finishes sooner.
    @MainActor
    static func runAnalysis(
        videos: [VideoRecording],
        analyzer: VideoAnalyzer,
        modelContext: ModelContext,
        manageBatch: Bool = true,
        maxConcurrent: Int = maxConcurrentScans
    ) async {
        if manageBatch { analyzer.beginBatch(total: videos.count) }
        defer { if manageBatch { analyzer.endBatch() } }

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

        // Sliding window: at most maxConcurrent clips are in Vision at any
        // moment. Results are applied on the main actor as each clip
        // finishes, so the model writes stay serialized while detection
        // overlaps across clips.
        await withTaskGroup(of: (index: Int, scan: ClipScanResult).self) { group in
            var next = 0
            func addNextScan() {
                guard next < items.count else { return }
                let item = items[next]
                next += 1
                group.addTask {
                    let didAccess = item.url.startAccessingSecurityScopedResource()
                    defer { if didAccess { item.url.stopAccessingSecurityScopedResource() } }
                    let scan = await DetectionEngine.runDetections(
                        url: item.url,
                        vfovDegrees: item.vfovDegrees
                    )
                    return (item.index, scan)
                }
            }
            for _ in 0..<max(1, maxConcurrent) { addNextScan() }

            while let result = await group.next() {
                addNextScan()
                let video = videos[result.index]
                await apply(
                    scan: result.scan,
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
        scan: ClipScanResult,
        to video: VideoRecording,
        analyzer: VideoAnalyzer,
        modelContext: ModelContext
    ) async {
        let detections = scan.detections
        let summary = VideoAnalyzer.summarize(detections: detections)
        let tag = classifyEventTag(summary)
        let (startTime, cameraName) = parseFilename(video.url.lastPathComponent)

        // Persist detection markers so the scrubber can show them later.
        let markers = detections.map {
            DetectionMarker(kind: $0.kind.rawValue, timestampMs: $0.timestampMs)
        }
        video.setMarkers(markers)
        // Carried items / companions seen alongside people — the summarizer
        // reads this off the clip so it can say what the person had with them.
        video.humanContext = scan.humanContext.joined(separator: ", ")

        // Store plate reads on whichever event covers this clip, so watchlist
        // matching works off OCR text instead of hoping the AI summary quotes
        // it. Plates attach regardless of human proximity — a drive-by car
        // never trips the proximity check.
        let plateReads = detections.compactMap {
            $0.kind == .licensePlate ? $0.licensePlateText : nil
        }
        if !plateReads.isEmpty, let startTime {
            let wideWindow = startTime.addingTimeInterval(-incidentWindowSeconds)...video.endTime.addingTimeInterval(incidentWindowSeconds)
            if let existing = existingEvent(inWindow: wideWindow, modelContext: modelContext) {
                merge(plateReads: plateReads, into: existing)
                do { try modelContext.save() } catch { print("save failed: \(error)") }
            }
        }

        if let proximityMs = analyzer.firstProximityEvent(in: detections),
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
                        detection: summary,
                        videos: [video]
                    )
                }
            } else if existingEvent(
                inWindow: startTime.addingTimeInterval(-incidentWindowSeconds)...video.endTime.addingTimeInterval(incidentWindowSeconds),
                modelContext: modelContext
            ) != nil {
                // Same incident, different minute: Sentry saves ~10 minutes of
                // clips per event, so a clip whose own window doesn't contain
                // the trigger timestamp is still the same footage. Creating an
                // event here duplicated real Sentry events minute-by-minute.
            } else {
                // Timestamp the event at the proximity moment itself, clamped
                // slightly inside the clip. Using the clip's raw start time put
                // the event exactly on the seam shared with the previous clip,
                // and the detail view's clip-matching query then pulled in two
                // minutes of footage for every camera.
                let clipSeconds = video.endTime.timeIntervalSince(startTime)
                let insetSeconds = min(
                    max(0.5, Double(proximityMs) / 1000.0),
                    max(0.5, clipSeconds - 0.5)
                )
                let event = buildEvent(
                    cameraName: cameraName,
                    startTime: startTime.addingTimeInterval(insetSeconds),
                    summary: summary,
                    tag: tag
                )
                merge(plateReads: plateReads, into: event)
                event.summary = await EventSummarizer.summarize(
                    event: event,
                    detection: summary,
                    videos: [video]
                )
                modelContext.insert(event)
            }
            do { try modelContext.save() } catch { print("save failed: \(error)") }
        }
    }

    /// TUNING: how far (seconds) around a clip's window an existing event's
    /// timestamp suppresses creating a new scan event. Sentry records up to
    /// ~10 minutes of clips per incident with the trigger timestamp near the
    /// end, so neighboring minutes of an imported event are the same incident.
    private static let incidentWindowSeconds: TimeInterval = 10 * 60

    /// Append new plate reads to the event's stored plate text, deduped by
    /// normalized form so re-scans don't accumulate the same plate twice.
    @MainActor
    private static func merge(plateReads: [String], into event: Event) {
        var reads = event.plateText.split(separator: " ").map(String.init)
        var seen = Set(reads.map { EventSearchMatcher.normalizePlate($0) })
        for read in plateReads {
            let normalized = EventSearchMatcher.normalizePlate(read)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            reads.append(read.replacingOccurrences(of: " ", with: ""))
        }
        event.plateText = reads.joined(separator: " ")
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
