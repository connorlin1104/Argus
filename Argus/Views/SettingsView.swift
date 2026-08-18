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
    @State private var showAddPlate: Bool = false
    @State private var summaryRunner = AutoSummaryRunner()
    /// Shown in the delete-all footer. Cached counts instead of @Querys —
    /// a query materialized every Event each time the Settings tab appeared.
    @State private var eventCount: Int = 0
    @State private var videoCount: Int = 0
    /// Confirmation gate for the destructive "Delete all events" action.
    @State private var confirmDeleteAll: Bool = false
    /// Alert shown when the summary button can't start a run (model
    /// unavailable, nothing to summarize). The button must always respond
    /// to a tap — App Review flagged the old silent no-op as a bug.
    @State private var summaryNotice: String = ""
    @State private var showSummaryNotice: Bool = false

    @AppStorage(ArgusApp.iCloudSyncDefaultsKey)
    private var iCloudSyncEnabled: Bool = false

    @AppStorage(AppearanceSetting.defaultsKey)
    private var appearance: AppearanceSetting = .system

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                SettingsGeofenceSection(showPicker: $showPicker)
                WatchlistSection(showAddSheet: $showAddPlate)
                librarySection
                aiSection
                iCloudSection
            }
            .formStyle(.grouped)
            // TEXT: navigation title at top of the Settings tab
            .navigationTitle("Settings")
            .onAppear { refreshCounts() }
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
            .sheet(isPresented: $showAddPlate) {
                WatchlistAddSheet { plate, note, colorHex in
                    let entry = Watchlist(plateText: plate, note: note, colorHex: colorHex)
                    modelContext.insert(entry)
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                ForEach(AppearanceSetting.allCases, id: \.self) { setting in
                    Text(setting.label).tag(setting)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Library

    // Zone recompute, trip regrouping, and dedupe all happen automatically on
    // import (and on geofence changes), so the only manual action left is the
    // full wipe — no section title needed for a single button.
    private var librarySection: some View {
        Section {
            // BUTTON: wipe everything (events + video records; footage on
            // disk is untouched). Geofences and watchlist entries are kept.
            Button("Delete All Videos…", role: .destructive) {
                confirmDeleteAll = true
            }
            .disabled(eventCount == 0 && videoCount == 0)
            .confirmationDialog(
                "Delete all \(videoCount) videos and \(eventCount) events?",
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All Videos", role: .destructive) {
                    EventDeleter.deleteAll(modelContext: modelContext)
                    refreshCounts()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every video and event from the app. Your geofences, watchlist, and the original video files on disk are kept. This can't be undone.")
            }
            Text("\(eventCount) events · \(videoCount) videos")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Bulk actions genuinely need every event — fetch on demand inside the
    /// button action instead of holding the whole library in an @Query.
    private func fetchAllEvents() -> [Event] {
        (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
    }

    private func refreshCounts() {
        eventCount = (try? modelContext.fetchCount(FetchDescriptor<Event>())) ?? 0
        videoCount = (try? modelContext.fetchCount(FetchDescriptor<VideoRecording>())) ?? 0
    }

    // MARK: - AI summaries

    // Always visible, even on devices without Apple Intelligence, so the
    // feature is discoverable rather than looking concealed. The button is
    // always tappable: when a run can't start (model unavailable, nothing
    // to summarize) the tap explains why in an alert instead of silently
    // doing nothing — App Review filed the old inert row as "app not
    // responsive".
    private var aiSection: some View {
        Section("On-device summaries") {
            // BUTTON: backfill summaries for every event without one
            Button {
                handleSummarizeAllTap()
            } label: {
                Label("Generate summaries for all events", systemImage: "sparkles")
            }
            .disabled(summaryRunner.isRunning)
            .alert("On-Device Summaries", isPresented: $showSummaryNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(summaryNotice)
            }

            if summaryRunner.isRunning {
                ProgressView(value: summaryRunner.progress) {
                    Text(summaryRunner.currentLabel)
                        .font(.caption.monospacedDigit())
                }
                Button("Cancel") { summaryRunner.cancel() }
                    .buttonStyle(.bordered)
            } else if let reason = EventSummarizer.unavailabilityExplanation {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func handleSummarizeAllTap() {
        if let reason = EventSummarizer.unavailabilityExplanation {
            summaryNotice = reason
            showSummaryNotice = true
            return
        }
        let events = fetchAllEvents()
        let pending = events.filter { EventSummarizer.isPlaceholderSummary($0.summary) }
        if events.isEmpty {
            summaryNotice = "There are no events to summarize yet. Import dashcam footage from the Events tab first."
            showSummaryNotice = true
        } else if pending.isEmpty {
            summaryNotice = "All \(events.count) events already have summaries."
            showSummaryNotice = true
        } else {
            SettingsBulkActions.summarizeAll(
                events: events,
                modelContext: modelContext,
                runner: summaryRunner
            )
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
