//
//  BookmarkResolver.swift
//  Argus
//
//  Single home for security-scoped bookmark resolution. Every resolver in
//  the app used to read the `bookmarkDataIsStale` flag and ignore it, so a
//  renamed drive or moved file left thousands of clips with bookmarks that
//  degraded silently until they stopped resolving. When the system reports a
//  bookmark as stale, the fix is to re-create it from the resolved URL right
//  away — that's the only moment resolution is still guaranteed to work.
//
//  Resolution order for a clip: app-owned local copy → the clip's own
//  bookmark → the import-root fallback (resolve the ImportSource root
//  bookmark and append the clip's path relative to the original root).
//  The fallback exists because per-file bookmarks are the first thing to
//  degrade across drive unplugs; the root bookmark is one sturdy anchor
//  per import instead of thousands of fragile ones.
//

import Foundation
import SwiftData

enum BookmarkResolver {

    /// Mint a security-scoped bookmark for a URL currently readable (its own
    /// scope, or a parent folder's, must be active). iOS bookmarks carry the
    /// scope implicitly; macOS needs it requested explicitly.
    static func mint(for url: URL) -> Data? {
        #if os(iOS)
        try? url.bookmarkData()
        #else
        try? url.bookmarkData(options: .withSecurityScope)
        #endif
    }

    struct Resolution {
        let url: URL
        /// Non-nil when the stored bookmark was stale and a fresh one was
        /// created. Callers that own the VideoRecording should persist it.
        let refreshedBookmark: Data?
    }

    /// Resolve bookmark data to a URL, re-creating the bookmark when the
    /// system flags it stale. Returns nil only if resolution itself fails.
    static func resolve(_ data: Data) -> Resolution? {
        var isStale = false
        let url: URL
        do {
            #if os(iOS)
            url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            #else
            url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                          bookmarkDataIsStale: &isStale)
            #endif
        } catch {
            print("Bookmark resolution error: \(error)")
            return nil
        }
        guard isStale else { return Resolution(url: url, refreshedBookmark: nil) }

        // Re-creating a bookmark reads the target, which needs its scope.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let refreshed: Data?
        #if os(iOS)
        refreshed = try? url.bookmarkData()
        #else
        refreshed = try? url.bookmarkData(options: .withSecurityScope)
        #endif
        return Resolution(url: url, refreshedBookmark: refreshed)
    }

    /// Resolve a recording's clip URL, writing the refreshed bookmark back to
    /// the model when the stored one was stale so it keeps resolving in
    /// future sessions. The write is picked up by the context's normal save.
    static func resolveURL(for video: VideoRecording) -> URL? {
        // App-owned copies resolve by filename — no bookmark, no drive
        // needed. A missing copy falls through to the bookmark so a
        // reference-only row still plays from the source drive.
        if let local = localURL(fileName: video.localFileName) {
            return local
        }
        if !video.bookmark.isEmpty, let resolution = resolve(video.bookmark) {
            if let refreshed = resolution.refreshedBookmark {
                video.bookmark = refreshed
            }
            return resolution.url
        }
        return rootFallbackURL(for: video)
    }

    /// Last resort when the clip's own bookmark is gone or dead: resolve each
    /// ImportSource root bookmark, rebuild the clip's path relative to the
    /// originally picked root, and check the file is actually there. On
    /// success the per-file bookmark is re-minted so the next resolution is
    /// direct again.
    private static func rootFallbackURL(for video: VideoRecording) -> URL? {
        guard let context = video.modelContext else { return nil }
        let sources = (try? context.fetch(FetchDescriptor<ImportSource>())) ?? []
        for source in sources {
            guard let root = resolve(source.bookmark) else { continue }
            if let refreshed = root.refreshedBookmark {
                source.bookmark = refreshed
            }
            guard let candidatePath = fallbackPath(clipPath: video.url.path,
                                                   rootPath: source.rootPath,
                                                   resolvedRootPath: root.url.path) else { continue }
            let didAccess = root.url.startAccessingSecurityScopedResource()
            defer { if didAccess { root.url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: candidatePath) else { continue }
            let candidate = URL(fileURLWithPath: candidatePath)
            if let fresh = mint(for: candidate) {
                video.bookmark = fresh
            }
            return candidate
        }
        return nil
    }

    /// Pure path math for the root fallback: the clip's stored absolute path
    /// minus the original root prefix, appended to wherever the root resolves
    /// today. Nil when the clip wasn't imported from under this root. The
    /// prefix check requires a "/" boundary so root "/Volumes/SSD/TeslaCam"
    /// never claims clips from "/Volumes/SSD/TeslaCamOld".
    static func fallbackPath(clipPath: String, rootPath: String,
                             resolvedRootPath: String) -> String? {
        guard !rootPath.isEmpty else { return nil }
        let root = rootPath.count > 1 && rootPath.hasSuffix("/")
            ? String(rootPath.dropLast()) : rootPath
        if clipPath == root { return resolvedRootPath }
        guard clipPath.hasPrefix(root + "/") else { return nil }
        return resolvedRootPath + clipPath.dropFirst(root.count)
    }

    /// The ClipStore URL for a stored filename, nil when unset or the file
    /// is gone. Shared by the model-based resolver above and ThumbnailCache
    /// (which works from plain Sendable values, not the model).
    static func localURL(fileName: String) -> URL? {
        guard !fileName.isEmpty else { return nil }
        let url = ClipStore.url(forFileName: fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
