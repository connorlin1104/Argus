//
//  EventsImport.swift
//  Argus
//
//  Helpers used by EventsListView when the user picks a Tesla Sentry folder.
//  Handles security-scoped access, dedupe, and saving into SwiftData.
//
//  One import runs at a time (a second request is refused with a banner
//  message), each event is saved the moment it's read so cancelling — or
//  killing the app — keeps everything imported so far, and progress streams
//  into ImportFeedback for the determinate banner.
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
    /// True while an import pass is reading folders and copying clips.
    var isImporting: Bool = false
    /// Determinate progress: event directories processed / total in scope.
    /// Total stays 0 until the folder walk finishes counting.
    var eventsProcessed: Int = 0
    var totalEvents: Int = 0

    func begin() {
        isImporting = true
        message = nil
        eventsProcessed = 0
        totalEvents = 0
    }

    func progress(processed: Int, total: Int) {
        eventsProcessed = processed
        totalEvents = total
    }

    func finish(tally: ImportTally, cancelled: Bool = false, skippedByDateFilter: Int = 0) {
        isImporting = false
        if cancelled {
            // TEXT: cancelled-import banner — partials are kept by design.
            message = "Import stopped — kept \(count(tally.insertedEvents, "event")) imported so far. Import the folder again anytime to pick up the rest."
        } else if tally.insertedEvents == 0 && tally.skippedEvents == 0 {
            if skippedByDateFilter > 0 {
                message = "No events matched your date range — \(count(skippedByDateFilter, "event")) in that folder \(skippedByDateFilter == 1 ? "is" : "are") outside it."
            } else {
                message = "No Tesla events found in that folder. Pick a TeslaCam, SavedClips, or SentryClips folder — each event folder needs its event.json."
            }
        } else if tally.insertedEvents == 0 {
            message = "Nothing new to import — \(count(tally.skippedEvents, "event")) in that folder \(tally.skippedEvents == 1 ? "is" : "are") already imported."
        } else {
            // Imported events stay hidden until analyzed — say so, or the
            // still-empty list makes the import look like it did nothing.
            // Clips are copied into the app during import, so it's safe to
            // unplug the drive as soon as this message shows.
            var text = "Imported \(count(tally.insertedEvents, "event")) with \(count(tally.insertedVideos, "clip")) — you can unplug the drive now. Each event appears once it finishes analyzing."
            if tally.skippedEvents > 0 {
                text += " Skipped \(count(tally.skippedEvents, "event")) already imported."
            }
            if skippedByDateFilter > 0 {
                text += " Skipped \(count(skippedByDateFilter, "event")) outside your date range."
            }
            message = text
        }
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

enum EventsImportRunner {

    /// Shared runner so the toolbar progress can outlive any single import call.
    @MainActor static let autoSummaryRunner = AutoSummaryRunner()

    /// The single in-flight import. One slot, not a queue: it backs the
    /// Cancel button and stops two imports from interleaving their feedback
    /// (a finished second import used to clear the banner while the first
    /// was still copying, making a 20 GB import look dead).
    @MainActor private static var activeImportTask: Task<Void, Never>?

    @MainActor static var isImportRunning: Bool { activeImportTask != nil }

    /// BUTTON: banner cancel. Takes effect at the next clip boundary; the
    /// events already saved stay.
    @MainActor
    static func cancelImport() {
        activeImportTask?.cancel()
    }

    /// Claim the single import slot, or explain why not.
    @MainActor
    private static func launch(_ body: @escaping @MainActor () async -> Void) {
        guard activeImportTask == nil else {
            // TEXT: second-import-refused banner (2.1a: the tap always answers)
            ImportFeedback.shared.message = "Another import is still running — cancel it or let it finish first."
            return
        }
        activeImportTask = Task { @MainActor in
            await body()
            activeImportTask = nil
        }
    }

    /// Entry point for folder imports (scope wizard already answered) and
    /// drag-and-drop (which skips the wizard and imports everything).
    @MainActor
    static func beginImport(url: URL, scope: ImportScope = .everything, modelContext: ModelContext) {
        launch { await runImport(url: url, scope: scope, modelContext: modelContext) }
    }

    /// Top-level handler for dropped folders.
    @MainActor
    static func handle(result: Result<URL, Error>, modelContext: ModelContext) {
        switch result {
        case .success(let url):
            beginImport(url: url, modelContext: modelContext)
        case .failure:
            print("nothing was selected")
        }
    }

    /// Multi-file fallback used on iOS when the system folder picker won't
    /// surface an "Open" affordance for the user's storage provider.
    @MainActor
    static func handleFiles(result: Result<[URL], Error>, modelContext: ModelContext) {
        switch result {
        case .success(let urls):
            launch { await runFilesImport(urls: urls, modelContext: modelContext) }
        case .failure:
            print("nothing was selected")
        }
    }

    @MainActor
    private static func runImport(url: URL, scope: ImportScope, modelContext: ModelContext) async {
        ImportFollowUpScheduler.shared.importWillStart()
        ImportFeedback.shared.begin()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let session = ImportSession(modelContext: modelContext)
        let summary = await importEvents(
            url: url,
            scope: scope,
            onProgress: { processed, total in
                ImportFeedback.shared.progress(processed: processed, total: total)
            },
            onEvent: { event, videos in
                session.persist(event: event, videos: videos)
            }
        )
        session.finish(cancelled: summary.cancelled,
                       skippedByDateFilter: summary.skippedByDateFilter,
                       modelContext: modelContext)
    }

    @MainActor
    private static func runFilesImport(urls: [URL], modelContext: ModelContext) async {
        ImportFollowUpScheduler.shared.importWillStart()
        ImportFeedback.shared.begin()
        // Each picked URL carries its own security scope; we have to start it
        // before reading the file and stop it when we're done.
        let accessed: [URL] = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

        let session = ImportSession(modelContext: modelContext)
        await importEventsFromFiles(urls: urls) { event, videos in
            session.persist(event: event, videos: videos)
        }
        session.finish(cancelled: Task.isCancelled, modelContext: modelContext)
    }

    /// Stable key identifying one physical recording: one car can't record
    /// two different clips on the same camera in the same second.
    static func videoKey(_ video: VideoRecording) -> String {
        "\(video.camera)|\(Int(video.startTime.timeIntervalSince1970))"
    }

    /// Stable key used to dedupe events across imports.
    static func eventKey(_ event: Event) -> String {
        "\(event.source)|\(event.camera)|\(Int(event.timestamp.timeIntervalSince1970))"
    }
}

/// Accumulates one import pass. Dedupe sets are built once up front, each
/// event is inserted AND saved as it arrives (cancel / app kill keeps the
/// partials), and the once-per-import follow-ups (zones, trip regroup,
/// analysis scheduling) run in `finish` over whatever actually landed.
@MainActor
final class ImportSession {
    private let modelContext: ModelContext
    private var existingVideoPaths: Set<String>
    private var existingVideoKeys: Set<String>
    private var existingEventKeys: Set<String>
    private(set) var tally = ImportTally()
    private var freshEvents: [Event] = []
    private var freshVideos: [VideoRecording] = []

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        existingVideoPaths = Self.currentVideoPaths(modelContext: modelContext)
        existingVideoKeys = Self.currentVideoKeys(modelContext: modelContext)
        existingEventKeys = Self.currentEventKeys(modelContext: modelContext)
    }

    /// Insert + save one event and its clips the moment the importer reads
    /// them, deduped against the library and everything earlier in this pass.
    func persist(event: Event, videos: [VideoRecording]) {
        var insertedSomething = false
        let key = EventsImportRunner.eventKey(event)
        if existingEventKeys.contains(key) {
            tally.skippedEvents += 1
        } else {
            // Hidden from the events list until its clips are scanned and
            // summarized — the follow-up scheduler reveals each event once
            // it's ready to open instead of listing it half-populated.
            event.isPendingAnalysis = true
            existingEventKeys.insert(key)
            modelContext.insert(event)
            freshEvents.append(event)
            tally.insertedEvents += 1
            insertedSomething = true
        }
        for video in videos {
            // Dedupe by camera + start second as well as by path: Tesla
            // writes the same minute-clip into every event folder that
            // overlaps it, so the identical recording arrives under several
            // paths. One row per physical clip, or the AI summary narrates
            // the same activity once per copy.
            let videoKey = EventsImportRunner.videoKey(video)
            if existingVideoPaths.contains(video.url.path) || existingVideoKeys.contains(videoKey) {
                tally.skippedVideos += 1
                continue
            }
            existingVideoPaths.insert(video.url.path)
            existingVideoKeys.insert(videoKey)
            modelContext.insert(video)
            freshVideos.append(video)
            tally.insertedVideos += 1
            insertedSomething = true
        }
        if insertedSomething {
            do {
                try modelContext.save()
            } catch {
                print("modelContext.save failed: \(error)")
            }
        }
    }

    /// Once-per-import follow-ups over everything that landed — also runs on
    /// cancel, so partial imports still get zones, trips, and analysis.
    func finish(cancelled: Bool, skippedByDateFilter: Int = 0, modelContext: ModelContext) {
        // Tag the new events with any geofence they fall inside, so zones
        // show up right after import instead of waiting for a manual recompute.
        if !freshEvents.isEmpty {
            let fences = (try? modelContext.fetch(FetchDescriptor<Geofence>())) ?? []
            SettingsBulkActions.recomputeZones(events: freshEvents, fences: fences)
            // Re-cluster trips across the whole library, not just the new
            // events — an import can extend or bridge existing trips. This is
            // the only place tripID gets stamped.
            let allEvents = (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
            TripGrouper.regroup(events: allEvents)
        }

        // The user just said stop — don't leave the kept events invisible
        // until the background scan grinds through them (on a big cancelled
        // import that made the cancel look like it lost everything until a
        // relaunch). Reveal them now; the queued follow-up still scans and
        // summarizes them in place. Only events with no covering footage get
        // the Incomplete chip.
        if cancelled {
            let windows = IncompleteEventDetector.clipWindows(modelContext: modelContext)
            for event in freshEvents {
                event.isPendingAnalysis = false
                event.analysisIncomplete = !IncompleteEventDetector.hasAssociatedVideo(
                    timestamp: event.timestamp, windows: windows)
            }
        }

        do {
            try modelContext.save()
        } catch {
            print("modelContext.save failed: \(error)")
        }
        print("Import: events +\(tally.insertedEvents)/-\(tally.skippedEvents), videos +\(tally.insertedVideos)/-\(tally.skippedVideos)\(cancelled ? " (cancelled)" : "")")
        ImportFeedback.shared.finish(tally: tally, cancelled: cancelled,
                                     skippedByDateFilter: skippedByDateFilter)

        // Autonomous follow-ups (AI summaries + Vision clip scans) are queued
        // rather than started here: the scheduler waits until every in-flight
        // import has landed plus a quiet period, then runs the merged batch.
        ImportFollowUpScheduler.shared.importDidFinish(
            events: freshEvents,
            videos: freshVideos,
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

    private static func currentVideoKeys(modelContext: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<VideoRecording>()
        descriptor.propertiesToFetch = [\.camera, \.startTime]
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return Set(existing.map(EventsImportRunner.videoKey))
    }

    private static func currentEventKeys(modelContext: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<Event>()
        descriptor.propertiesToFetch = [\.source, \.camera, \.timestamp]
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return Set(existing.map(EventsImportRunner.eventKey))
    }
}
