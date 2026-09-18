//
//  IncompleteEventDetector.swift
//  Argus
//
//  Finds events whose import never finished: stranded mid-analysis by a
//  killed session (analysisIncomplete stamped at launch by
//  ImportFollowUpScheduler), or left with no clip covering their timestamp
//  (a cancelled copy or a file-picker selection that grabbed event.json
//  without its mp4s). Backs the Settings "re-run analysis" / "remove
//  incomplete imports" actions.
//

import Foundation
import SwiftData

enum IncompleteEventDetector {

    /// Whether any clip window covers the timestamp (with the shared trailing
    /// tolerance — Tesla stamps events a few seconds after clips end).
    /// Windows are ~60s clips — a linear scan over a one-shot Settings
    /// action is fine.
    static func hasAssociatedVideo(timestamp: Date, windows: [(start: Date, end: Date)]) -> Bool {
        windows.contains {
            EventClipMatcher.covers(start: $0.start, end: $0.end, timestamp: timestamp)
        }
    }

    /// Every event the library should treat as incomplete: flagged by the
    /// stranded-event rescue, or clipless. Events still queued for analysis
    /// (isPendingAnalysis) are in flight, not incomplete — skip them.
    static func incompleteEvents(modelContext: ModelContext) -> [Event] {
        let events = (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
        guard !events.isEmpty else { return [] }
        let windows = clipWindows(modelContext: modelContext)
        return events.filter { event in
            guard !event.isPendingAnalysis else { return false }
            return event.analysisIncomplete
                || !hasAssociatedVideo(timestamp: event.timestamp, windows: windows)
        }
    }

    /// All clip time windows, fetched once. propertiesToFetch keeps the pass
    /// from materializing bookmarks and marker JSON for every row.
    static func clipWindows(modelContext: ModelContext) -> [(start: Date, end: Date)] {
        var descriptor = FetchDescriptor<VideoRecording>()
        descriptor.propertiesToFetch = [\.startTime, \.endTime]
        let videos = (try? modelContext.fetch(descriptor)) ?? []
        return videos.map { ($0.startTime, $0.endTime) }
    }
}
