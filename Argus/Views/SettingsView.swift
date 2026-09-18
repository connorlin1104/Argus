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
    /// Feedback for the incomplete-imports actions. Like the summary button,
    /// they always respond to a tap: with nothing incomplete, the tap says so
    /// instead of silently doing nothing.
    @State private var incompleteNotice: String = ""
    @State private var showIncompleteNotice: Bool = false
    /// Incomplete events pending removal; non-empty drives the confirmation.
    @State private var pendingIncompleteRemoval: [Event] = []
    /// Migration of legacy drive-referenced clips into app storage. The
    /// button always responds: with nothing to copy, the tap says so.
    @State private var isCopyingClips: Bool = false
    @State private var clipStorageNotice: String = ""
    @State private var showClipStorageNotice: Bool = false

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

    private var librarySection: some View {
        Section {
            // BUTTON: re-queue incomplete events through the normal
            // post-import scan + summary pipeline.
            Button {
                handleRerunIncompleteTap()
            } label: {
                Label("Re-run Analysis on Incomplete Events", systemImage: "arrow.clockwise")
            }
            // BUTTON: delete incomplete events (and any clips only they
            // reference) after confirmation.
            Button(role: .destructive) {
                handleRemoveIncompleteTap()
            } label: {
                Label("Remove Incomplete Imports…", systemImage: "trash.slash")
            }
            .alert("Incomplete Imports", isPresented: $showIncompleteNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(incompleteNotice)
            }
            .confirmationDialog(
                "Remove \(pendingIncompleteRemoval.count) incomplete event\(pendingIncompleteRemoval.count == 1 ? "" : "s")?",
                isPresented: Binding(
                    get: { !pendingIncompleteRemoval.isEmpty },
                    set: { if !$0 { pendingIncompleteRemoval = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Incomplete Imports", role: .destructive) {
                    EventDeleter.delete(events: pendingIncompleteRemoval, modelContext: modelContext)
                    pendingIncompleteRemoval = []
                    refreshCounts()
                }
                Button("Cancel", role: .cancel) { pendingIncompleteRemoval = [] }
            } message: {
                Text("These events never finished importing — the app quit mid-import or their video clips were never selected. Original files on disk are untouched, so you can import them again.")
            }
            // BUTTON: copy legacy drive-referenced clips into app storage so
            // they keep playing after the drive is unplugged. New imports
            // are copied automatically; this migrates older libraries.
            Button {
                handleCopyClipsTap()
            } label: {
                if isCopyingClips {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Saving clips in the app…")
                    }
                } else {
                    Label("Save Clips in the App", systemImage: "internaldrive")
                }
            }
            .disabled(isCopyingClips)
            .alert("Video Storage", isPresented: $showClipStorageNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(clipStorageNotice)
            }
            // BUTTON: wipe everything (events + video records + the app's
            // stored clip copies). Geofences and watchlist entries are kept.
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
                Text("This removes every video and event from the app, including the app's stored copies of your clips. Geofences, watchlist entries, and the original files on your drive are kept. This can't be undone.")
            }
            Text("\(eventCount) events · \(videoCount) videos · \(storedSizeText) saved in the app")
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

    // MARK: - Incomplete imports

    /// Hide the incomplete events again and feed them back through the same
    /// scheduler pipeline imports use — scan, summarize, reveal one by one.
    private func handleRerunIncompleteTap() {
        let incomplete = IncompleteEventDetector.incompleteEvents(modelContext: modelContext)
        guard !incomplete.isEmpty else {
            incompleteNotice = "No incomplete imports found — every event finished analyzing."
            showIncompleteNotice = true
            return
        }
        // Each event's clips, deduped across events sharing a window.
        var videos: [VideoRecording] = []
        var seenIDs: Set<PersistentIdentifier> = []
        for event in incomplete {
            let t = event.timestamp
            let cutoff = EventClipMatcher.earliestClipEnd(for: t)
            let descriptor = FetchDescriptor<VideoRecording>(
                predicate: #Predicate<VideoRecording> { v in
                    v.startTime <= t && v.endTime >= cutoff
                }
            )
            for video in (try? modelContext.fetch(descriptor)) ?? []
            where seenIDs.insert(video.persistentModelID).inserted {
                videos.append(video)
            }
        }
        for event in incomplete { event.isPendingAnalysis = true }
        try? modelContext.save()
        ImportFollowUpScheduler.shared.importWillStart()
        ImportFollowUpScheduler.shared.importDidFinish(
            events: incomplete,
            videos: videos,
            modelContext: modelContext
        )
        incompleteNotice = "Re-analyzing \(incomplete.count) event\(incomplete.count == 1 ? "" : "s"). Each one reappears in the Events list as soon as it finishes."
        showIncompleteNotice = true
    }

    private var storedSizeText: String {
        ByteCountFormatter.string(fromByteCount: ClipStore.totalBytes(), countStyle: .file)
    }

    /// Copy every legacy drive-referenced clip into ClipStore. The file
    /// copies run off the main actor (gigabytes over USB); only Sendable
    /// bookmark data crosses over, and the model writes happen back here.
    private func handleCopyClipsTap() {
        guard !isCopyingClips else { return }
        let descriptor = FetchDescriptor<VideoRecording>(
            predicate: #Predicate<VideoRecording> { $0.localFileName == "" }
        )
        let legacy = (try? modelContext.fetch(descriptor)) ?? []
        guard !legacy.isEmpty else {
            clipStorageNotice = "All your clips are already saved in the app."
            showClipStorageNotice = true
            return
        }
        struct CopyItem: Sendable {
            let id: PersistentIdentifier
            let bookmark: Data
        }
        let items = legacy.map { CopyItem(id: $0.persistentModelID, bookmark: $0.bookmark) }
        isCopyingClips = true
        Task {
            // Copy in small chunks, saving filenames after each one, so a
            // quit mid-run keeps everything copied so far (an all-at-the-end
            // write-back once orphaned a whole run's worth of files).
            let chunkSize = 20
            var savedCount = 0
            for chunkStart in stride(from: 0, to: items.count, by: chunkSize) {
                let chunk = Array(items[chunkStart..<min(chunkStart + chunkSize, items.count)])
                let copied: [(id: PersistentIdentifier, fileName: String)] =
                    await Task.detached(priority: .utility) {
                        var out: [(PersistentIdentifier, String)] = []
                        for item in chunk {
                            guard let source = BookmarkResolver.resolve(item.bookmark)?.url else {
                                continue
                            }
                            let didAccess = source.startAccessingSecurityScopedResource()
                            let fileName = try? ClipStore.importCopy(from: source)
                            if didAccess { source.stopAccessingSecurityScopedResource() }
                            if let fileName { out.append((item.id, fileName)) }
                        }
                        return out
                    }.value
                for entry in copied {
                    if let video = modelContext.model(for: entry.id) as? VideoRecording {
                        video.localFileName = entry.fileName
                    }
                }
                try? modelContext.save()
                savedCount += copied.count
            }
            isCopyingClips = false
            let failed = legacy.count - savedCount
            if failed == 0 {
                clipStorageNotice = "Saved \(savedCount) clip\(savedCount == 1 ? "" : "s") in the app. Videos now play even with the drive unplugged."
            } else {
                clipStorageNotice = "Saved \(savedCount) of \(legacy.count) clips in the app. \(failed) couldn't be read — plug in the drive they were imported from, make sure there's enough free space, and try again."
            }
            showClipStorageNotice = true
        }
    }

    private func handleRemoveIncompleteTap() {
        let incomplete = IncompleteEventDetector.incompleteEvents(modelContext: modelContext)
        if incomplete.isEmpty {
            incompleteNotice = "No incomplete imports found — every event finished analyzing."
            showIncompleteNotice = true
        } else {
            pendingIncompleteRemoval = incomplete
        }
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
