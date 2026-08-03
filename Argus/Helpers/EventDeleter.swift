//
//  EventDeleter.swift
//  Argus
//
//  Shared deletion helper behind the row context menu's Delete, the
//  multi-select "Delete selected" action, and Settings' "Delete all events".
//
//  Events and their clips have no SwiftData relationship — clips are matched
//  by timestamp window (the same predicate EventExporter/EventDetailView
//  use), so plain modelContext.delete(event) would strand VideoRecording
//  rows in the Videos tab. This helper removes an event's clips too, unless
//  another remaining event still falls inside the clip's window.
//
//  Only library records are removed. The video files themselves stay where
//  they were imported from (security-scoped bookmarks point at the
//  originals) — deletion here never touches the user's footage on disk.
//

import Foundation
import SwiftData

enum EventDeleter {

    /// Delete the given events plus any of their clips that no remaining
    /// event references.
    static func delete(events: [Event], modelContext: ModelContext) {
        guard !events.isEmpty else { return }

        // Collect candidate clips before the events disappear.
        var candidates: [VideoRecording] = []
        var seenIDs: Set<PersistentIdentifier> = []
        for event in events {
            let t = event.timestamp
            let descriptor = FetchDescriptor<VideoRecording>(
                predicate: #Predicate<VideoRecording> { v in
                    v.startTime <= t && v.endTime >= t
                }
            )
            for video in (try? modelContext.fetch(descriptor)) ?? [] {
                if seenIDs.insert(video.persistentModelID).inserted {
                    candidates.append(video)
                }
            }
        }

        for event in events {
            modelContext.delete(event)
        }
        try? modelContext.save()

        // With the events gone, a candidate clip is orphaned when no event
        // timestamp falls inside its window anymore.
        for video in candidates {
            let start = video.startTime
            let end = video.endTime
            let descriptor = FetchDescriptor<Event>(
                predicate: #Predicate<Event> { e in
                    e.timestamp >= start && e.timestamp <= end
                }
            )
            if ((try? modelContext.fetchCount(descriptor)) ?? 0) == 0 {
                modelContext.delete(video)
            }
        }
        try? modelContext.save()
    }

    /// Remove every event and every clip record from the library. Geofences
    /// and watchlist entries are kept — they describe the user's world, not
    /// the imported footage. Row-by-row (not a batch delete) so CloudKit
    /// sync sees each deletion.
    static func deleteAll(modelContext: ModelContext) {
        let events = (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
        for event in events {
            modelContext.delete(event)
        }
        let videos = (try? modelContext.fetch(FetchDescriptor<VideoRecording>())) ?? []
        for video in videos {
            modelContext.delete(video)
        }
        try? modelContext.save()
    }

    /// Clips no event's timestamp falls inside — the surrounding minutes of
    /// footage that only surface in the Videos tab. Every clip an event's
    /// detail view would open is excluded.
    static func videosWithoutEvents(modelContext: ModelContext) -> [VideoRecording] {
        let videos = (try? modelContext.fetch(FetchDescriptor<VideoRecording>())) ?? []
        guard !videos.isEmpty else { return [] }
        // One sorted timestamp list + binary search per clip instead of a
        // count query per clip — per-clip fetches crawl on large libraries.
        let events = (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
        let timestamps = events.map(\.timestamp).sorted()
        return videos.filter { video in
            !containsTimestamp(from: video.startTime, to: video.endTime, sorted: timestamps)
        }
    }

    /// Remove every clip no event references, keeping all event footage.
    /// Only library records go — files on the source drive are untouched.
    /// Returns how many clip records were removed.
    @discardableResult
    static func deleteVideosWithoutEvents(modelContext: ModelContext) -> Int {
        let unattached = videosWithoutEvents(modelContext: modelContext)
        for video in unattached {
            modelContext.delete(video)
        }
        try? modelContext.save()
        return unattached.count
    }

    /// Whether any timestamp in the sorted list lands inside [start, end].
    private static func containsTimestamp(from start: Date, to end: Date,
                                          sorted timestamps: [Date]) -> Bool {
        var lo = 0
        var hi = timestamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if timestamps[mid] < start { lo = mid + 1 } else { hi = mid }
        }
        return lo < timestamps.count && timestamps[lo] <= end
    }
}
