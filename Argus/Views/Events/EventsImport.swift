//
//  EventsImport.swift
//  Argus
//
//  Helpers used by EventsListView when the user picks a Tesla Sentry folder.
//  Handles security-scoped access, dedupe, and saving into SwiftData.
//

import Foundation
import SwiftData

/// Result of one import pass: counts shown in the import log.
struct ImportTally {
    var insertedEvents = 0
    var insertedVideos = 0
    var skippedEvents = 0
    var skippedVideos = 0
}

enum EventsImportRunner {

    /// Top-level handler bound to the folder importer in EventsListView.
    static func handle(result: Result<URL, Error>, modelContext: ModelContext) {
        switch result {
        case .success(let url):
            Task { @MainActor in
                await runImport(url: url, modelContext: modelContext)
            }
        case .failure:
            print("nothing was selected")
        }
    }

    /// Multi-file fallback used on iOS when the system folder picker won't
    /// surface an "Open" affordance for the user's storage provider.
    static func handleFiles(result: Result<[URL], Error>, modelContext: ModelContext) {
        switch result {
        case .success(let urls):
            Task { @MainActor in
                await runFilesImport(urls: urls, modelContext: modelContext)
            }
        case .failure:
            print("nothing was selected")
        }
    }

    /// Shared runner so the toolbar progress can outlive any single import call.
    @MainActor static let autoSummaryRunner = AutoSummaryRunner()

    @MainActor
    private static func runImport(url: URL, modelContext: ModelContext) async {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let imported = await importEvents(url: url)
        persist(imported: imported, modelContext: modelContext)
    }

    @MainActor
    private static func runFilesImport(urls: [URL], modelContext: ModelContext) async {
        // Each picked URL carries its own security scope; we have to start it
        // before reading the file and stop it when we're done.
        let accessed: [URL] = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

        let imported = await importEventsFromFiles(urls: urls)
        persist(imported: imported, modelContext: modelContext)
    }

    @MainActor
    private static func persist(imported: ImportResult, modelContext: ModelContext) {
        let existingVideoPaths = currentVideoPaths(modelContext: modelContext)
        let existingEventKeys = currentEventKeys(modelContext: modelContext)

        var tally = ImportTally()
        var freshlyInserted: [Event] = []
        var freshlyInsertedVideos: [VideoRecording] = []

        for event in imported.events {
            if existingEventKeys.contains(eventKey(event)) {
                tally.skippedEvents += 1
                continue
            }
            modelContext.insert(event)
            freshlyInserted.append(event)
            tally.insertedEvents += 1
        }
        for video in imported.videos {
            if existingVideoPaths.contains(video.url.path) {
                tally.skippedVideos += 1
                continue
            }
            modelContext.insert(video)
            freshlyInsertedVideos.append(video)
            tally.insertedVideos += 1
        }

        // Tag the new events with any geofence they fall inside, so zones
        // show up right after import instead of waiting for a manual recompute.
        if !freshlyInserted.isEmpty {
            let fences = (try? modelContext.fetch(FetchDescriptor<Geofence>())) ?? []
            SettingsBulkActions.recomputeZones(events: freshlyInserted, fences: fences)
        }

        do {
            try modelContext.save()
        } catch {
            print("modelContext.save failed: \(error)")
        }
        print("Import: events +\(tally.insertedEvents)/-\(tally.skippedEvents), videos +\(tally.insertedVideos)/-\(tally.skippedVideos)")

        // AI: always backfill summaries for freshly imported events when the
        // on-device model is available. The toggle that used to gate this was
        // removed — there's no downside to running it.
        if EventSummarizer.isAvailable && !freshlyInserted.isEmpty {
            autoSummaryRunner.run(events: freshlyInserted, modelContext: modelContext)
        }

        // Vision: auto-scan the new clips for people / vehicles / plates so
        // detection markers and tags appear without pressing "Scan clips".
        // Skipped if a scan is already running (the batch progress state is
        // single-flight); the manual button covers that rare case.
        if !freshlyInsertedVideos.isEmpty && !VideoAnalyzer.shared.isAnalyzing {
            let newVideos = freshlyInsertedVideos
            Task { @MainActor in
                await VideoAnalysisRunner.runAnalysis(
                    videos: newVideos,
                    analyzer: VideoAnalyzer.shared,
                    modelContext: modelContext
                )
            }
        }
    }

    // MARK: - Dedupe sets

    private static func currentVideoPaths(modelContext: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<VideoRecording>()
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return Set(existing.map { $0.url.path })
    }

    private static func currentEventKeys(modelContext: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<Event>()
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return Set(existing.map(eventKey))
    }

    /// Stable key used to dedupe events across imports.
    static func eventKey(_ event: Event) -> String {
        "\(event.source)|\(event.camera)|\(Int(event.timestamp.timeIntervalSince1970))"
    }
}
