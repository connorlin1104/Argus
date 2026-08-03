//
//  EventsImport.swift
//  Argus
//
//  Helpers used by EventsListView when the user picks a Tesla Sentry folder.
//  Handles security-scoped access, dedupe, and saving into SwiftData.
//

import Foundation
import SwiftData
import Observation

/// Which system picker the shared import `.fileImporter` in EventsListView
/// presents. Both modes share a single fileImporter because SwiftUI only
/// honors one fileImporter per view — a second modifier attached to the same
/// view silently never presents (this is what broke folder import on iOS).
enum ImportPickerMode {
    /// Standard path: pick a TeslaCam / SavedClips / SentryClips folder.
    case folder
    /// Multi-file fallback for iOS storage providers whose folder picker
    /// won't surface an "Open" affordance.
    case files
}

/// Result of one import pass: counts shown in the import log.
struct ImportTally {
    var insertedEvents = 0
    var insertedVideos = 0
    var skippedEvents = 0
    var skippedVideos = 0
}

/// Live import status surfaced as a banner in EventsListView. A singleton so
/// every import path (toolbar picker, iOS file picker, drag-and-drop) reports
/// into the same place — before this, the tally only went to the console and
/// a failed or empty import looked like nothing happened.
@Observable
@MainActor
final class ImportFeedback {
    static let shared = ImportFeedback()

    /// Message describing the last finished import; nil once dismissed.
    var message: String? = nil
    /// True while an import pass is reading folders and probing clips.
    var isImporting: Bool = false

    func begin() {
        isImporting = true
        message = nil
    }

    func finish(tally: ImportTally) {
        isImporting = false
        if tally.insertedEvents == 0 && tally.skippedEvents == 0 {
            message = "No Tesla events found in that folder. Pick a TeslaCam, SavedClips, or SentryClips folder — each event folder needs its event.json."
        } else if tally.insertedEvents == 0 {
            message = "Nothing new to import — \(count(tally.skippedEvents, "event")) in that folder \(tally.skippedEvents == 1 ? "is" : "are") already imported."
        } else {
            // Imported events stay hidden until analyzed — say so, or the
            // still-empty list makes the import look like it did nothing.
            var text = "Imported \(count(tally.insertedEvents, "event")) with \(count(tally.insertedVideos, "clip")). Each event appears once it finishes analyzing."
            if tally.skippedEvents > 0 {
                text += " Skipped \(count(tally.skippedEvents, "event")) already imported."
            }
            message = text
        }
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

enum EventsImportRunner {

    /// Entry point for the shared fileImporter in EventsListView. The picker
    /// always yields a URL list; in folder mode it carries exactly one URL.
    static func handlePicked(result: Result<[URL], Error>, mode: ImportPickerMode, modelContext: ModelContext) {
        switch (mode, result) {
        case (.folder, .success(let urls)):
            guard let url = urls.first else { return }
            handle(result: .success(url), modelContext: modelContext)
        case (.folder, .failure(let error)):
            handle(result: .failure(error), modelContext: modelContext)
        case (.files, _):
            handleFiles(result: result, modelContext: modelContext)
        }
    }

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
        ImportFollowUpScheduler.shared.importWillStart()
        ImportFeedback.shared.begin()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let imported = await importEvents(url: url)
        persist(imported: imported, modelContext: modelContext)
    }

    @MainActor
    private static func runFilesImport(urls: [URL], modelContext: ModelContext) async {
        ImportFollowUpScheduler.shared.importWillStart()
        ImportFeedback.shared.begin()
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
            // Hidden from the events list until its clips are scanned and
            // summarized — the follow-up scheduler reveals each event once
            // it's ready to open instead of listing it half-populated.
            event.isPendingAnalysis = true
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
            // Re-cluster trips across the whole library, not just the new
            // events — an import can extend or bridge existing trips. This is
            // the only place tripID gets stamped.
            let allEvents = (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
            TripGrouper.regroup(events: allEvents)
        }

        do {
            try modelContext.save()
        } catch {
            print("modelContext.save failed: \(error)")
        }
        print("Import: events +\(tally.insertedEvents)/-\(tally.skippedEvents), videos +\(tally.insertedVideos)/-\(tally.skippedVideos)")
        ImportFeedback.shared.finish(tally: tally)

        // Autonomous follow-ups (AI summaries + Vision clip scans) are queued
        // rather than started here: the scheduler waits until every in-flight
        // import has landed plus a quiet period, then runs the merged batch.
        ImportFollowUpScheduler.shared.importDidFinish(
            events: freshlyInserted,
            videos: freshlyInsertedVideos,
            modelContext: modelContext
        )
    }

    // MARK: - Dedupe sets

    private static func currentVideoPaths(modelContext: ModelContext) -> Set<String> {
        // propertiesToFetch keeps the dedupe pass from materializing every
        // stored field (bookmarks, marker JSON) for every row.
        var descriptor = FetchDescriptor<VideoRecording>()
        descriptor.propertiesToFetch = [\.url]
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return Set(existing.map { $0.url.path })
    }

    private static func currentEventKeys(modelContext: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<Event>()
        descriptor.propertiesToFetch = [\.source, \.camera, \.timestamp]
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return Set(existing.map(eventKey))
    }

    /// Stable key used to dedupe events across imports.
    static func eventKey(_ event: Event) -> String {
        "\(event.source)|\(event.camera)|\(Int(event.timestamp.timeIntervalSince1970))"
    }
}
