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

/// Sendable slice of a legacy clip handed to the off-main sizing and copy
/// work — @Model objects themselves must stay on the main actor.
private struct ClipCopyItem: Sendable {
    let id: PersistentIdentifier
    let bookmark: Data
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showPicker: Bool = false
    @State private var showAddPlate: Bool = false
    @State private var summaryRunner = AutoSummaryRunner()
    /// Shown in the delete-all footer. Cached counts instead of @Querys —
    /// a query materialized every Event each time the Settings tab appeared.
    @State private var eventCount: Int = 0
    @State private var videoCount: Int = 0
    /// Stored-clip bytes for the footer. @State (not computed inline) so the
    /// footer refreshes when this view re-appears — Keep/Remove happens on
    /// other tabs, and a computed label only re-rendered on relaunch.
    @State private var storedBytes: Int64 = 0
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

    /// Unkept-footage cleanup confirmation; non-zero count drives the dialog.
    @State private var pendingUnkeptCleanupCount: Int = 0
    /// Bytes that cleanup would free — quoted in the confirmation.
    @State private var pendingUnkeptCleanupBytes: Int64 = 0

    /// Save-clips confirmation: items and their total size are gathered on
    /// tap (sizing thousands of files touches the drive, hence the spinner),
    /// the dialog shows when items land, and the copy starts on confirm.
    @State private var pendingCopyItems: [ClipCopyItem] = []
    @State private var pendingCopyBytes: Int64 = 0
    @State private var isSizingCopy: Bool = false

    /// Targeted plate scan: analyzes only the never-scanned clips covering an
    /// event. A quit or unplug during the post-import pass leaves events
    /// without plate reads, so watchlist/search match on nothing — and the
    /// Videos tab's fix for that is a full-library scan nobody runs on
    /// thousands of clips.
    @State private var isPlateScanning: Bool = false
    @State private var plateScanNotice: String = ""
    @State private var showPlateScanNotice: Bool = false

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
                analysisSection
                storageSection
                deleteSection
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

    // MARK: - Analysis

    /// Everything that (re)computes data about the library: plate scans,
    /// rescuing incomplete imports, and AI summaries. Grouped by what the
    /// user is trying to do, not by which subsystem runs it.
    private var analysisSection: some View {
        Section("Analysis") {
            // BUTTON: scan event-covering clips that were never analyzed so
            // plate text lands on events and watchlist/search can match.
            // Always responds: with nothing to scan, the tap says so.
            Button {
                handlePlateScanTap()
            } label: {
                if isPlateScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning event clips…")
                    }
                } else {
                    Label("Scan Event Clips for Plates", systemImage: "text.viewfinder")
                }
            }
            .disabled(isPlateScanning)
            .alert("Plate Scan", isPresented: $showPlateScanNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(plateScanNotice)
            }
            // BUTTON: re-queue incomplete events through the normal
            // post-import scan + summary pipeline.
            Button {
                handleRerunIncompleteTap()
            } label: {
                Label("Re-run Analysis on Incomplete Events", systemImage: "arrow.clockwise")
            }
            .alert("Incomplete Imports", isPresented: $showIncompleteNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(incompleteNotice)
            }
            // BUTTON: backfill summaries for every event without one. Always
            // visible, even on devices without Apple Intelligence, so the
            // feature is discoverable rather than looking concealed; when a
            // run can't start the tap explains why in an alert instead of
            // silently doing nothing — App Review filed the old inert row
            // as "app not responsive".
            Button {
                handleSummarizeAllTap()
            } label: {
                Label("Generate Summaries for All Events", systemImage: "sparkles")
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

    // MARK: - Storage

    /// Everything about where footage lives on this device: saving copies in
    /// the app and freeing the space they take.
    private var storageSection: some View {
        Section {
            // BUTTON: copy legacy drive-referenced clips into app storage so
            // they keep playing after the drive is unplugged. New imports
            // reference the drive; Keep on Device saves per event — this
            // migrates older libraries wholesale. Tap sizes the copy first,
            // then a confirmation quotes what it costs.
            Button {
                handleCopyClipsTap()
            } label: {
                if isCopyingClips {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Saving clips in the app…")
                    }
                } else if isSizingCopy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking size…")
                    }
                } else {
                    Label("Save Clips in the App", systemImage: "internaldrive")
                }
            }
            .disabled(isCopyingClips || isSizingCopy)
            .alert("Video Storage", isPresented: $showClipStorageNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(clipStorageNotice)
            }
            .confirmationDialog(
                "Save \(pendingCopyItems.count) clip\(pendingCopyItems.count == 1 ? "" : "s") in the app?",
                isPresented: Binding(
                    get: { !pendingCopyItems.isEmpty },
                    set: { if !$0 { pendingCopyItems = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button("Save Clips") {
                    let items = pendingCopyItems
                    pendingCopyItems = []
                    startClipCopy(items: items)
                }
                Button("Cancel", role: .cancel) { pendingCopyItems = [] }
            } message: {
                Text(copyConfirmMessage)
            }
            // BUTTON: free the space taken by saved copies no kept event
            // needs (footage saved before Keep existed, or left behind by
            // partial Keep attempts). Always responds: with nothing to
            // reclaim, the tap says so.
            Button {
                handleRemoveUnkeptTap()
            } label: {
                Label("Remove Footage for Unkept Events…", systemImage: "externaldrive.badge.minus")
            }
            .confirmationDialog(
                "Remove saved footage for \(pendingUnkeptCleanupCount) clip\(pendingUnkeptCleanupCount == 1 ? "" : "s")?",
                isPresented: Binding(
                    get: { pendingUnkeptCleanupCount > 0 },
                    set: { if !$0 { pendingUnkeptCleanupCount = 0 } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Saved Footage", role: .destructive) {
                    let removed = EventFootageKeeper.removeUnkeptFootage(modelContext: modelContext)
                    pendingUnkeptCleanupCount = 0
                    refreshCounts()
                    clipStorageNotice = "Removed the app's saved copies of \(removed) clip\(removed == 1 ? "" : "s"). Events kept on this device are untouched."
                    showClipStorageNotice = true
                }
                Button("Cancel", role: .cancel) { pendingUnkeptCleanupCount = 0 }
            } message: {
                Text("These clips belong to events not marked Keep on Device. Removing them frees about \(ByteCountFormatter.string(fromByteCount: pendingUnkeptCleanupBytes, countStyle: .file)). Their events stay in the app and play again whenever the source drive is plugged in — if the car hasn't overwritten it. Footage for kept events is never touched.")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("\(eventCount) events · \(videoCount) videos · \(storedSizeText) saved in the app")
        }
    }

    // MARK: - Delete

    /// Destructive actions, isolated in their own section so nothing sits
    /// next to a button that removes data.
    private var deleteSection: some View {
        Section("Delete Data") {
            // BUTTON: delete incomplete events (and any clips only they
            // reference) after confirmation.
            Button(role: .destructive) {
                handleRemoveIncompleteTap()
            } label: {
                Label("Remove Incomplete Imports…", systemImage: "trash.slash")
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
        storedBytes = ClipStore.totalBytes()
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
        ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file)
    }

    /// TEXT: save-clips confirmation body. Quotes the size when readable;
    /// with the drive unplugged sizing comes back zero, so say that instead
    /// of "Zero KB".
    private var copyConfirmMessage: String {
        if pendingCopyBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: pendingCopyBytes, countStyle: .file)
            return "This copies about \(size) from your drive into the app's storage. Clips already saved aren't copied again."
        }
        return "The clip sizes couldn't be read — the drive may be unplugged. You can still start, but clips that can't be read are skipped."
    }

    /// Gather the legacy drive-referenced clips and size them, then present
    /// the confirmation. Sizing resolves and stats every file, so it runs
    /// off-main behind a brief spinner.
    private func handleCopyClipsTap() {
        guard !isCopyingClips, !isSizingCopy else { return }
        let descriptor = FetchDescriptor<VideoRecording>(
            predicate: #Predicate<VideoRecording> { $0.localFileName == "" }
        )
        let legacy = (try? modelContext.fetch(descriptor)) ?? []
        guard !legacy.isEmpty else {
            clipStorageNotice = "All your clips are already saved in the app."
            showClipStorageNotice = true
            return
        }
        let items = legacy.map { ClipCopyItem(id: $0.persistentModelID, bookmark: $0.bookmark) }
        isSizingCopy = true
        Task {
            let bytes = await Task.detached(priority: .userInitiated) { () -> Int64 in
                var total: Int64 = 0
                for item in items {
                    guard let source = BookmarkResolver.resolve(item.bookmark)?.url else { continue }
                    let didAccess = source.startAccessingSecurityScopedResource()
                    total += Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    if didAccess { source.stopAccessingSecurityScopedResource() }
                }
                return total
            }.value
            isSizingCopy = false
            pendingCopyBytes = bytes
            pendingCopyItems = items
        }
    }

    /// Copy every legacy drive-referenced clip into ClipStore, once the user
    /// confirms the size. The file copies run off the main actor (gigabytes
    /// over USB); only Sendable bookmark data crosses over, and the model
    /// writes happen back here.
    private func startClipCopy(items: [ClipCopyItem]) {
        guard !isCopyingClips else { return }
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
            // Events whose footage is now fully copied count as kept, so
            // Remove/cleanup semantics see them correctly.
            EventFootageKeeper.backfillKeptFlags(modelContext: modelContext)
            refreshCounts()
            let failed = items.count - savedCount
            if failed == 0 {
                clipStorageNotice = "Saved \(savedCount) clip\(savedCount == 1 ? "" : "s") in the app. Videos now play even with the drive unplugged."
            } else {
                clipStorageNotice = "Saved \(savedCount) of \(items.count) clips in the app. \(failed) couldn't be read — plug in the drive they were imported from, make sure there's enough free space, and try again."
            }
            showClipStorageNotice = true
        }
    }

    /// Scan only the clips that cover an event and were never analyzed. A
    /// scanned clip always has non-empty markersJSON (an empty result encodes
    /// as "[]"), so `== ""` means the analyzer never touched it.
    private func handlePlateScanTap() {
        guard !isPlateScanning else { return }
        guard !VideoAnalyzer.shared.isAnalyzing else {
            plateScanNotice = "A video scan is already running — check the Videos tab for its progress."
            showPlateScanNotice = true
            return
        }
        let descriptor = FetchDescriptor<VideoRecording>(
            // `== ""` rather than .isEmpty — SwiftData mistranslates .isEmpty
            // on stored strings and the clause silently matches nothing.
            predicate: #Predicate<VideoRecording> { $0.markersJSON == "" }
        )
        let unscanned = (try? modelContext.fetch(descriptor)) ?? []
        let timestamps = fetchAllEvents().map(\.timestamp)
        let clips = unscanned.filter { clip in
            timestamps.contains {
                EventClipMatcher.covers(start: clip.startTime, end: clip.endTime, timestamp: $0)
            }
        }
        guard !clips.isEmpty else {
            plateScanNotice = "Every clip covering an event has already been scanned. If a plate still isn't matching, its footage may not show a readable plate."
            showPlateScanNotice = true
            return
        }
        isPlateScanning = true
        plateScanNotice = "Scanning \(clips.count) clip\(clips.count == 1 ? "" : "s") for plates and activity. Keep the drive plugged in — progress shows in the Videos tab."
        showPlateScanNotice = true
        Task {
            await VideoAnalysisRunner.runAnalysis(
                videos: clips,
                analyzer: VideoAnalyzer.shared,
                modelContext: modelContext
            )
            // Fresh plate reads can turn events into watchlist matches — save
            // their footage while the drive is (probably still) plugged in,
            // same rule as the post-import pass.
            let entries = (try? modelContext.fetch(FetchDescriptor<Watchlist>())) ?? []
            if !entries.isEmpty {
                for event in fetchAllEvents()
                where !event.keptOnDevice
                    && !WatchlistMatcher.matches(event: event, in: entries).isEmpty {
                    try? await EventFootageKeeper.keep(event: event, modelContext: modelContext)
                }
            }
            isPlateScanning = false
            refreshCounts()
        }
    }

    private func handleRemoveUnkeptTap() {
        let candidates = EventFootageKeeper.unkeptLocalClips(modelContext: modelContext)
        if candidates.isEmpty {
            clipStorageNotice = "Nothing to remove — every saved clip belongs to an event kept on this device."
            showClipStorageNotice = true
        } else {
            // Local files, so sizing them is cheap enough for the tap.
            pendingUnkeptCleanupBytes = candidates.reduce(Int64(0)) { sum, clip in
                guard let url = BookmarkResolver.localURL(fileName: clip.localFileName) else { return sum }
                return sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            pendingUnkeptCleanupCount = candidates.count
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
