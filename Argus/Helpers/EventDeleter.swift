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
}
