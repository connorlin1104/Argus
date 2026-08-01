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
    @Query private var allEvents: [Event]

    @State private var showPicker: Bool = false
    @State private var summaryRunner = AutoSummaryRunner()

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
                let fences = (try? modelContext.fetch(FetchDescriptor<Geofence>())) ?? []
                SettingsBulkActions.recomputeZones(events: allEvents, fences: fences)
            }
            // BUTTON: regroup events into trips
            Button("Regroup trips") {
                SettingsBulkActions.regroupTrips(events: allEvents)
            }
            // BUTTON: dedupe events + videos
            Button("Remove duplicate events and videos") {
                SettingsBulkActions.removeDuplicates(events: allEvents, modelContext: modelContext)
            }
            Text("\(allEvents.count) events in library")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - AI summaries

    private var aiSection: some View {
        Section("On-device summaries") {
            // BUTTON: backfill summaries for every event without one
            Button {
                SettingsBulkActions.summarizeAll(
                    events: allEvents,
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
                Text("Apple Intelligence isn't available on this device. Summaries will fall back to a plain-text dump.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - iCloud

    private var iCloudSection: some View {
        Section("iCloud") {
            Toggle("Sync events & geofences via iCloud", isOn: $iCloudSyncEnabled)
            Text("Requires iCloud capability enabled in Signing & Capabilities. Restart the app after toggling. VideoRecording stays local (security-scoped bookmarks aren't portable).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
