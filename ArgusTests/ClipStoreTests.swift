//
//  ClipStoreTests.swift
//  ArgusTests
//
//  Covers app-owned clip storage: copy-on-import semantics (reuse, no
//  overwrite), local-first URL resolution, and EventDeleter removing stored
//  files with their records. Files are created under unique names and
//  cleaned up so runs never collide with the host app's real store.
//

import Foundation
import SwiftData
import Testing
@testable import Argus

@MainActor
struct ClipStoreTests {

    private nonisolated static let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// A unique throwaway source file in a temp directory.
    private func makeSourceFile(named name: String, content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    @Test func importCopyStoresTheFile() throws {
        let name = "clip-\(UUID().uuidString).mp4"
        defer { ClipStore.delete(fileName: name) }

        let source = try makeSourceFile(named: name, content: "original")
        let stored = try ClipStore.importCopy(from: source)
        #expect(stored == name)
        let data = try Data(contentsOf: ClipStore.url(forFileName: name))
        #expect(String(decoding: data, as: UTF8.self) == "original")
    }

    @Test func importCopyReusesAnExistingFile() throws {
        // Tesla writes the same minute-clip into overlapping event folders —
        // the second copy must be a no-op, not an error or an overwrite.
        let name = "clip-\(UUID().uuidString).mp4"
        defer { ClipStore.delete(fileName: name) }

        let first = try makeSourceFile(named: name, content: "original")
        _ = try ClipStore.importCopy(from: first)
        let second = try makeSourceFile(named: name, content: "different copy")
        let stored = try ClipStore.importCopy(from: second)
        #expect(stored == name)
        let data = try Data(contentsOf: ClipStore.url(forFileName: name))
        #expect(String(decoding: data, as: UTF8.self) == "original")
    }

    @Test func deleteIsSafeOnEmptyAndMissingNames() {
        ClipStore.delete(fileName: "")
        ClipStore.delete(fileName: "never-existed-\(UUID().uuidString).mp4")
        // Reaching here without a crash is the assertion.
        #expect(Bool(true))
    }

    @Test func resolveURLPrefersTheLocalCopy() throws {
        let name = "clip-\(UUID().uuidString).mp4"
        defer { ClipStore.delete(fileName: name) }
        let source = try makeSourceFile(named: name, content: "clip")
        _ = try ClipStore.importCopy(from: source)

        // Empty bookmark: only the local copy can resolve this.
        let video = VideoRecording(url: source, bookmark: Data(), camera: "front",
                                   startTime: Self.base,
                                   endTime: Self.base.addingTimeInterval(60),
                                   localFileName: name)
        #expect(BookmarkResolver.resolveURL(for: video) == ClipStore.url(forFileName: name))
    }

    @Test func resolveURLFailsWhenCopyAndBookmarkAreGone() {
        let video = VideoRecording(url: URL(fileURLWithPath: "/tmp/gone.mp4"),
                                   bookmark: Data(), camera: "front",
                                   startTime: Self.base,
                                   endTime: Self.base.addingTimeInterval(60),
                                   localFileName: "never-existed-\(UUID().uuidString).mp4")
        #expect(BookmarkResolver.resolveURL(for: video) == nil)
    }

    @Test func eventDeleterRemovesTheStoredCopy() throws {
        let name = "clip-\(UUID().uuidString).mp4"
        defer { ClipStore.delete(fileName: name) }
        let source = try makeSourceFile(named: name, content: "clip")
        _ = try ClipStore.importCopy(from: source)

        let schema = Schema([Event.self, VideoRecording.self, Geofence.self, Watchlist.self])
        let config = ModelConfiguration(schema: schema,
                                        isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let event = Event(source: "Tesla", camera: "front", city: "Austin",
                          estLatitude: "30.0", estLongitude: "-97.0",
                          reason: "user_interaction_honk",
                          timestamp: Self.base.addingTimeInterval(30))
        let video = VideoRecording(url: source, bookmark: Data(), camera: "front",
                                   startTime: Self.base,
                                   endTime: Self.base.addingTimeInterval(60),
                                   localFileName: name)
        context.insert(event)
        context.insert(video)
        try context.save()

        EventDeleter.delete(events: [event], modelContext: context)

        #expect(!FileManager.default.fileExists(atPath: ClipStore.url(forFileName: name).path))
        #expect(((try? context.fetchCount(FetchDescriptor<VideoRecording>())) ?? -1) == 0)
    }
}
