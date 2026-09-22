//
//  EventFootageKeeperTests.swift
//  ArgusTests
//
//  Covers the reference-only import direction: the delete-safety rule for
//  shared clips (Tesla writes one physical clip into overlapping event
//  folders), the launch backfill rule, the root-fallback path math, and the
//  importer leaving footage on the drive.
//

import Foundation
import Testing
@testable import Argus

struct EventFootageKeeperTests {

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private static func at(_ seconds: TimeInterval) -> Date {
        base.addingTimeInterval(seconds)
    }

    // MARK: - Delete safety (shared clips)

    @Test func clipStaysWhileAnotherKeptEventCoversIt() {
        // One physical clip [0, 60] serves two events; unkeeping one must not
        // free the file while the other is still kept.
        let stillKept = [Self.at(30)]
        #expect(EventFootageKeeper.clipIsNeeded(
            clipStart: Self.at(0), clipEnd: Self.at(60), keptTimestamps: stillKept))
    }

    @Test func clipIsFreeOnceNoKeptEventCoversIt() {
        #expect(!EventFootageKeeper.clipIsNeeded(
            clipStart: Self.at(0), clipEnd: Self.at(60), keptTimestamps: []))
    }

    @Test func unrelatedKeptEventDoesNotProtectTheClip() {
        // A kept event hours away is outside the clip's window (even with the
        // matcher's end tolerance) and must not block deletion.
        let farAway = [Self.at(7200)]
        #expect(!EventFootageKeeper.clipIsNeeded(
            clipStart: Self.at(0), clipEnd: Self.at(60), keptTimestamps: farAway))
    }

    @Test func endToleranceStillProtectsTheClip() {
        // Tesla stamps event.json a few seconds after the clips stop — an
        // event just past the clip's end is still that clip's event.
        let justPastEnd = [Self.at(60 + EventClipMatcher.toleranceSeconds - 1)]
        #expect(EventFootageKeeper.clipIsNeeded(
            clipStart: Self.at(0), clipEnd: Self.at(60), keptTimestamps: justPastEnd))
    }

    // MARK: - Launch backfill

    @Test func fullyCopiedEventBackfillsAsKept() {
        let windows = [
            (start: Self.at(0), end: Self.at(60), hasLocalCopy: true),
            (start: Self.at(0), end: Self.at(60), hasLocalCopy: true),
        ]
        #expect(EventFootageKeeper.shouldBackfillAsKept(
            eventTimestamp: Self.at(30), clipWindows: windows))
    }

    @Test func partiallyCopiedEventDoesNotBackfill() {
        let windows = [
            (start: Self.at(0), end: Self.at(60), hasLocalCopy: true),
            (start: Self.at(0), end: Self.at(60), hasLocalCopy: false),
        ]
        #expect(!EventFootageKeeper.shouldBackfillAsKept(
            eventTimestamp: Self.at(30), clipWindows: windows))
    }

    @Test func eventWithNoCoveringClipsDoesNotBackfill() {
        let windows = [(start: Self.at(7200), end: Self.at(7260), hasLocalCopy: true)]
        #expect(!EventFootageKeeper.shouldBackfillAsKept(
            eventTimestamp: Self.at(30), clipWindows: windows))
    }

    // MARK: - Root-fallback path math

    @Test func fallbackPathRebasesOntoTheResolvedRoot() {
        let path = BookmarkResolver.fallbackPath(
            clipPath: "/old/mount/TeslaCam/SentryClips/e1/clip.mp4",
            rootPath: "/old/mount/TeslaCam",
            resolvedRootPath: "/new/mount/TeslaCam"
        )
        #expect(path == "/new/mount/TeslaCam/SentryClips/e1/clip.mp4")
    }

    @Test func fallbackPathRejectsClipsOutsideTheRoot() {
        #expect(BookmarkResolver.fallbackPath(
            clipPath: "/elsewhere/clip.mp4",
            rootPath: "/old/mount/TeslaCam",
            resolvedRootPath: "/new/mount/TeslaCam"
        ) == nil)
    }

    @Test func fallbackPathRequiresADirectoryBoundary() {
        // "/TeslaCamOld" must not be claimed by root "/TeslaCam".
        #expect(BookmarkResolver.fallbackPath(
            clipPath: "/mnt/TeslaCamOld/clip.mp4",
            rootPath: "/mnt/TeslaCam",
            resolvedRootPath: "/new/TeslaCam"
        ) == nil)
    }

    @Test func fallbackPathToleratesATrailingSlashOnTheRoot() {
        let path = BookmarkResolver.fallbackPath(
            clipPath: "/mnt/TeslaCam/e1/clip.mp4",
            rootPath: "/mnt/TeslaCam/",
            resolvedRootPath: "/new/TeslaCam"
        )
        #expect(path == "/new/TeslaCam/e1/clip.mp4")
    }

    @Test func fallbackPathRejectsAnEmptyRoot() {
        #expect(BookmarkResolver.fallbackPath(
            clipPath: "/mnt/TeslaCam/clip.mp4",
            rootPath: "",
            resolvedRootPath: "/new"
        ) == nil)
    }

    // MARK: - Reference-only import

    @Test func importLeavesFootageOnTheDrive() async throws {
        // Build a minimal Tesla event folder: event.json + one clip.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        {"timestamp":"2026-09-01T12:00:30","city":"Austin","est_lat":"30.27","est_lon":"-97.74","reason":"sentry_aware_object_detection","camera":"5"}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("event.json"))
        let clipName = "2026-09-01_12-00-00-front.mp4"
        try Data("not a real mp4".utf8).write(to: dir.appendingPathComponent(clipName))
        defer { ClipStore.delete(fileName: clipName) }

        let result = await importEvent(
            eventURL: dir.appendingPathComponent("event.json"),
            eventDirectory: dir
        )
        let videos = try #require(result).videos
        #expect(videos.count == 1)
        // Reference-only: no app copy, and nothing landed in ClipStore.
        #expect(videos[0].localFileName.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: ClipStore.url(forFileName: clipName).path))
    }
}
