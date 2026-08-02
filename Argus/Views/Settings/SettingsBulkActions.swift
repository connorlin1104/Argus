//
//  SettingsBulkActions.swift
//  Argus
//
//  Library-wide maintenance helpers. Zone recompute and the AI summary
//  backfill run automatically (on import / geofence changes) with the
//  summary backfill also exposed as a button in SettingsView.
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

    /// Convenience overload that fetches the current events + fences itself.
    /// Called automatically whenever the geofence list changes so zone labels
    /// never go stale.
    static func recomputeZones(modelContext: ModelContext) {
        let events = (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
        let fences = (try? modelContext.fetch(FetchDescriptor<Geofence>())) ?? []
        recomputeZones(events: events, fences: fences)
    }

    // MARK: - AI summary backfill

    /// Kick off an AutoSummaryRunner over every event without a summary.
    @MainActor
    static func summarizeAll(events: [Event],
                             modelContext: ModelContext,
                             runner: AutoSummaryRunner) {
        runner.run(events: events, modelContext: modelContext)
    }

}
