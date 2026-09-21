//
//  IncompleteEventTests.swift
//  ArgusTests
//
//  Covers the incomplete-import detection: the pure clip-window math, the
//  detector's flagged ∪ clipless union, and the launch-time stranded-event
//  rescue stamping analysisIncomplete. Store-backed tests use an in-memory
//  container so nothing touches the app's real library.
//

import Foundation
import SwiftData
import Testing
@testable import Argus

@MainActor
struct IncompleteEventTests {

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Event.self, VideoRecording.self, Geofence.self, Watchlist.self])
        let config = ModelConfiguration(schema: schema,
                                        isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func event(timestamp: Date, pending: Bool = false, incomplete: Bool = false) -> Event {
        let event = Event(source: "Tesla", camera: "front", city: "Austin",
                          estLatitude: "30.0", estLongitude: "-97.0",
                          reason: "user_interaction_honk", timestamp: timestamp)
        event.isPendingAnalysis = pending
        event.analysisIncomplete = incomplete
        return event
    }

    private func clip(start: Date, duration: TimeInterval = 60) -> VideoRecording {
        VideoRecording(url: URL(fileURLWithPath: "/tmp/clip-\(start.timeIntervalSince1970).mp4"),
                       bookmark: Data(),
                       camera: "front",
                       startTime: start,
                       endTime: start.addingTimeInterval(duration))
    }

    // MARK: - Window math

    @Test func timestampInsideWindowHasVideo() {
        let windows = [(start: Self.base, end: Self.base.addingTimeInterval(60))]
        #expect(IncompleteEventDetector.hasAssociatedVideo(
            timestamp: Self.base.addingTimeInterval(30), windows: windows))
    }

    @Test func windowEdgesCountAsCovered() {
        let windows = [(start: Self.base, end: Self.base.addingTimeInterval(60))]
        #expect(IncompleteEventDetector.hasAssociatedVideo(timestamp: Self.base, windows: windows))
        #expect(IncompleteEventDetector.hasAssociatedVideo(
            timestamp: Self.base.addingTimeInterval(60), windows: windows))
    }

    @Test func timestampShortlyAfterClipEndCountsAsCovered() {
        // Tesla writes event.json a few seconds AFTER the final clips stop
        // recording (measured 0–13 s in a real library) — the shared trailing
        // tolerance must cover that gap, and nothing beyond it.
        let windows = [(start: Self.base, end: Self.base.addingTimeInterval(60))]
        #expect(IncompleteEventDetector.hasAssociatedVideo(
            timestamp: Self.base.addingTimeInterval(60 + 13), windows: windows))
        #expect(!IncompleteEventDetector.hasAssociatedVideo(
            timestamp: Self.base.addingTimeInterval(60 + EventClipMatcher.toleranceSeconds + 1),
            windows: windows))
    }

    @Test func timestampOutsideEveryWindowHasNoVideo() {
        let windows = [
            (start: Self.base, end: Self.base.addingTimeInterval(60)),
            (start: Self.base.addingTimeInterval(300), end: Self.base.addingTimeInterval(360)),
        ]
        #expect(!IncompleteEventDetector.hasAssociatedVideo(
            timestamp: Self.base.addingTimeInterval(120), windows: windows))
        #expect(!IncompleteEventDetector.hasAssociatedVideo(
            timestamp: Self.base.addingTimeInterval(-1), windows: windows))
    }

    @Test func emptyWindowListMeansNoVideo() {
        #expect(!IncompleteEventDetector.hasAssociatedVideo(timestamp: Self.base, windows: []))
    }

    // MARK: - Detector over the store

    @Test func detectorFindsFlaggedAndCliplessEvents() throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Covered and analyzed — not incomplete.
        let healthy = event(timestamp: Self.base.addingTimeInterval(30))
        // Flagged by the stranded rescue — incomplete even though covered.
        let flagged = event(timestamp: Self.base.addingTimeInterval(40), incomplete: true)
        // No clip anywhere near it — incomplete by cliplessness.
        let clipless = event(timestamp: Self.base.addingTimeInterval(10_000))
        // Mid-analysis events are in flight, never reported.
        let inFlight = event(timestamp: Self.base.addingTimeInterval(20_000), pending: true)

        for e in [healthy, flagged, clipless, inFlight] { context.insert(e) }
        context.insert(clip(start: Self.base))
        try context.save()

        let found = IncompleteEventDetector.incompleteEvents(modelContext: context)
        let foundIDs = Set(found.map(\.persistentModelID))
        #expect(foundIDs == Set([flagged.persistentModelID, clipless.persistentModelID]))
    }

    // MARK: - Stranded-event rescue

    @Test func releaseStrandedEventsStampsIncomplete() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let stranded = event(timestamp: Self.base, pending: true)
        let alreadyDone = event(timestamp: Self.base.addingTimeInterval(60))
        context.insert(stranded)
        context.insert(alreadyDone)
        try context.save()

        ImportFollowUpScheduler.shared.releaseStrandedEvents(modelContext: context)

        #expect(stranded.isPendingAnalysis == false)
        #expect(stranded.analysisIncomplete == true)
        #expect(alreadyDone.analysisIncomplete == false)
    }

    @Test func releaseStrandedEventsSparesEventsWithFootage() throws {
        let container = try makeContainer()
        let context = container.mainContext

        // Clips copied fine before the session died — only the scan/summary
        // is missing. Must be revealed WITHOUT the Incomplete chip.
        let covered = event(timestamp: Self.base.addingTimeInterval(30), pending: true)
        // No clip anywhere near it — genuinely incomplete.
        let clipless = event(timestamp: Self.base.addingTimeInterval(10_000), pending: true)
        context.insert(covered)
        context.insert(clipless)
        context.insert(clip(start: Self.base))
        try context.save()

        ImportFollowUpScheduler.shared.releaseStrandedEvents(modelContext: context)

        #expect(covered.isPendingAnalysis == false)
        #expect(covered.analysisIncomplete == false)
        #expect(clipless.isPendingAnalysis == false)
        #expect(clipless.analysisIncomplete == true)
    }
}
