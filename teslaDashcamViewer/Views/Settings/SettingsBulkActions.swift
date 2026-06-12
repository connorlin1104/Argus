//
//  SettingsBulkActions.swift
//  teslaDashcamViewer
//
//  Pure helpers behind the "Bulk actions" buttons in SettingsView. Kept
//  in their own file so the settings view stays focused on layout.
//

import Foundation
import SwiftData

enum SettingsBulkActions {

    // MARK: - Recompute zones

    /// Walk every event and reclassify its `zone` against the current geofence list.
    static func recomputeZones(events: [Event], fences: [Geofence]) {
        for event in events {
            event.zone = GeofenceClassifier.classify(
                latString: event.estLatitude,
                lonString: event.estLongitude,
                fences: fences
            )
        }
    }

    // MARK: - Trip grouping

    /// Re-cluster every event into trips based on time + location gaps.
    static func regroupTrips(events: [Event]) {
        TripGrouper.regroup(events: events)
    }

    // MARK: - AI summary backfill

    /// Kick off an AutoSummaryRunner over every event without a summary.
    @MainActor
    static func summarizeAll(events: [Event],
                             modelContext: ModelContext,
                             runner: AutoSummaryRunner) {
        runner.run(events: events, modelContext: modelContext)
    }

    // MARK: - Dedupe

    /// Remove duplicate events (by source|camera|timestamp-sec) and duplicate
    /// videos (by URL path), keeping the earliest insertion of each.
    static func removeDuplicates(events: [Event], modelContext: ModelContext) {
        removeDuplicateEvents(events: events, modelContext: modelContext)
        removeDuplicateVideos(modelContext: modelContext)
        try? modelContext.save()
    }

    private static func removeDuplicateEvents(events: [Event], modelContext: ModelContext) {
        var seen: Set<String> = []
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = "\(event.source)|\(event.camera)|\(Int(event.timestamp.timeIntervalSince1970))"
            if seen.contains(key) {
                modelContext.delete(event)
            } else {
                seen.insert(key)
            }
        }
    }

    private static func removeDuplicateVideos(modelContext: ModelContext) {
        let videoDescriptor = FetchDescriptor<VideoRecording>()
        let videos = (try? modelContext.fetch(videoDescriptor)) ?? []
        var seen: Set<String> = []
        for video in videos {
            let key = video.url.path
            if seen.contains(key) {
                modelContext.delete(video)
            } else {
                seen.insert(key)
            }
        }
    }
}
