//
//  EventFileVendor.swift
//  teslaDashcamViewer
//
//  Resolves a VideoRecording security-scoped bookmark and copies its file
//  into a temp directory so consumers (ShareLink, EventExporter, Quick Look)
//  can use a real, non-scoped URL.
//

import Foundation

enum EventFileVendor {

    enum VendorError: Error {
        case bookmarkResolutionFailed
        case accessDenied
        case copyFailed(underlying: Error)
    }

    /// Copies the recording's file into a temp staging directory. The
    /// returned URL has no security-scope requirements and may be handed to
    /// ShareLink, QLPreviewController, or zipped via NSFileCoordinator.
    ///
    /// - Parameters:
    ///   - video: the VideoRecording whose bookmark we'll resolve.
    ///   - stagingRoot: directory the copy lives under (created if missing).
    ///   - subfolder: optional subfolder inside `stagingRoot` to namespace
    ///     multi-event exports (e.g. one folder per event).
    static func vend(video: VideoRecording,
                     stagingRoot: URL,
                     subfolder: String? = nil) throws -> URL {
        guard let source = try resolveBookmark(video.bookmark) else {
            throw VendorError.bookmarkResolutionFailed
        }
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        guard didAccess else { throw VendorError.accessDenied }

        let dir: URL = {
            if let subfolder { return stagingRoot.appendingPathComponent(subfolder, isDirectory: true) }
            return stagingRoot
        }()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dest = dir.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            throw VendorError.copyFailed(underlying: error)
        }
        return dest
    }

    /// A scratch directory under the system temp dir, scoped by a UUID so
    /// multiple exports / shares don't trample each other.
    static func makeStagingRoot(prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func resolveBookmark(_ data: Data) throws -> URL? {
        var isStale = false
        #if os(iOS)
        return try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        #else
        return try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                       bookmarkDataIsStale: &isStale)
        #endif
    }
}
