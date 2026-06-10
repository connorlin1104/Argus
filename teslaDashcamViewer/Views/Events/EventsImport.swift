//
//  EventsImport.swift
//  teslaDashcamViewer
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

    /// Top-level handler bound to the file importer in EventsListView.
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

    @MainActor
    private static func runImport(url: URL, modelContext: ModelContext) async {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let imported = await importEvents(url: url)

        // Build dedupe sets from current store contents.
        let existingVideoPaths = currentVideoPaths(modelContext: modelContext)
        let existingEventKeys = currentEventKeys(modelContext: modelContext)

        var tally = ImportTally()

        for event in imported.events {
            if existingEventKeys.contains(eventKey(event)) {
                tally.skippedEvents += 1
                continue
            }
            modelContext.insert(event)
            tally.insertedEvents += 1
        }
        for video in imported.videos {
            if existingVideoPaths.contains(video.url.path) {
                tally.skippedVideos += 1
                continue
            }
            modelContext.insert(video)
            tally.insertedVideos += 1
        }

        do {
            try modelContext.save()
        } catch {
            print("modelContext.save failed: \(error)")
        }
        print("Import: events +\(tally.insertedEvents)/-\(tally.skippedEvents), videos +\(tally.insertedVideos)/-\(tally.skippedVideos)")
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
