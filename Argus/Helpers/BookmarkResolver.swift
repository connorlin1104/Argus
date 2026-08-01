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

import Foundation

enum BookmarkResolver {

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
        guard let resolution = resolve(video.bookmark) else { return nil }
        if let refreshed = resolution.refreshedBookmark {
            video.bookmark = refreshed
        }
        return resolution.url
    }
}
