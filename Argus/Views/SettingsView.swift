//
//  SettingsView.swift
//  Argus
//
//  Settings tab. Geofences, watchlist plates, smart lists, bulk operations,
//  iCloud sync, and on-device summary controls.
//
//  Sub-components:
//   - SettingsGeofenceSection — list + add + "Suggest Home"
//   - WatchlistSection        — manage plate watchlist
//   - GeofencePickerSheet     — the "Add zone" modal sheet
//
//  Search keywords: UI:settings, TEXT:settings, BUTTON:settings
//

import SwiftUI
import SwiftData
import CoreLocation

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showPicker: Bool = false
    @State private var summaryRunner = AutoSummaryRunner()
    /// Shown in the bulk-actions footer. A cached count instead of an
    /// @Query over every Event — the query materialized the whole library
    /// each time the Settings tab appeared.
    @State private var eventCount: Int = 0
    /// Confirmation gate for the destructive "Delete all events" action.
    @State private var confirmDeleteAll: Bool = false

    @AppStorage(ArgusApp.iCloudSyncDefaultsKey)
    private var iCloudSyncEnabled: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                SettingsGeofenceSection(showPicker: $showPicker)
                WatchlistSection()
                bulkActionsSection
                aiSection
                iCloudSection
            }
            .formStyle(.grouped)
            // TEXT: navigation title at top of the Settings tab
            .navigationTitle("Settings")
            .onAppear { refreshEventCount() }
            .sheet(isPresented: $showPicker) {
                GeofencePickerSheet { name, coord, radius, colorHex, iconSymbol in
                    let fence = Geofence(
                        name: name,
                        latitude: coord.latitude,
                        longitude: coord.longitude,
                        radiusMeters: radius,
                        colorHex: colorHex,
                        iconSymbol: iconSymbol
                    )
                    modelContext.insert(fence)
                    // New zones apply immediately — no manual recompute needed.
                    SettingsBulkActions.recomputeZones(modelContext: modelContext)
                }
            }
        }
    }

    // MARK: - Bulk actions

    private var bulkActionsSection: some View {
        Section("Bulk actions") {
            // BUTTON: walk every event and reclassify its zone
            Button("Recompute zones for all events") {
                SettingsBulkActions.recomputeZones(modelContext: modelContext)
            }
            // BUTTON: regroup events into trips
            Button("Regroup trips") {
                SettingsBulkActions.regroupTrips(events: fetchAllEvents())
            }
            // BUTTON: dedupe events + videos
            Button("Remove duplicate events and videos") {
                SettingsBulkActions.removeDuplicates(events: fetchAllEvents(), modelContext: modelContext)
                refreshEventCount()
            }
            // BUTTON: wipe the library (events + clip records; footage on
            // disk is untouched). Geofences and watchlist entries are kept.
            Button("Delete all events…", role: .destructive) {
                confirmDeleteAll = true
            }
            .disabled(eventCount == 0)
            .confirmationDialog(
                "Delete all \(eventCount) events?",
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete all events", role: .destructive) {
                    EventDeleter.deleteAll(modelContext: modelContext)
                    refreshEventCount()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every event and clip from the library. Your geofences, watchlist, and the video files on disk are kept. This can't be undone.")
            }
            Text("\(eventCount) events in library")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Bulk actions genuinely need every event — fetch on demand inside the
    /// button action instead of holding the whole library in an @Query.
    private func fetchAllEvents() -> [Event] {
        (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
    }

    private func refreshEventCount() {
        eventCount = (try? modelContext.fetchCount(FetchDescriptor<Event>())) ?? 0
    }

    // MARK: - AI summaries

    private var aiSection: some View {
        Section("On-device summaries") {
            // BUTTON: backfill summaries for every event without one
            Button {
                SettingsBulkActions.summarizeAll(
                    events: fetchAllEvents(),
                    modelContext: modelContext,
                    runner: summaryRunner
                )
            } label: {
                Label("Generate summaries for all events", systemImage: "sparkles")
            }
            .disabled(!EventSummarizer.isAvailable || summaryRunner.isRunning)

            if summaryRunner.isRunning {
                ProgressView(value: summaryRunner.progress) {
                    Text(summaryRunner.currentLabel)
                        .font(.caption.monospacedDigit())
                }
                Button("Cancel") { summaryRunner.cancel() }
                    .buttonStyle(.bordered)
            }

            if !EventSummarizer.isAvailable {
                Text("Apple Intelligence isn't available on this device, so AI summaries can't be generated. Events show a short built-in description instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - iCloud

    private var iCloudSection: some View {
        Section("iCloud") {
            Toggle("Sync events & geofences via iCloud", isOn: $iCloudSyncEnabled)
            // Honest status: the container is built once at launch, so report
            // what actually happened rather than what the toggle implies.
            if iCloudSyncEnabled && ArgusApp.cloudSyncRequestedAtLaunch && !ArgusApp.cloudSyncActive {
                Label("iCloud sync isn't active — the app couldn't start CloudKit (missing iCloud capability or signed-out account). Events, geofences, and watchlist entries are staying on this device only.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if iCloudSyncEnabled != ArgusApp.cloudSyncRequestedAtLaunch {
                Label("Restart the app to apply this change.",
                      systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if ArgusApp.cloudSyncActive {
                Label("Sync is active. Synced data includes event GPS locations, plate reads, and geofence coordinates (stored in your private iCloud database).",
                      systemImage: "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Requires iCloud capability enabled in Signing & Capabilities. Video files and their bookmarks always stay local (security-scoped bookmarks aren't portable).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
