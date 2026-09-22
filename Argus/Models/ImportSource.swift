//
//  ImportSource.swift
//  Argus
//
//  One row per distinct folder the user has imported from. Import stores
//  references (per-clip security-scoped bookmarks) instead of copying
//  footage; when a clip's own bookmark stops resolving, BookmarkResolver
//  falls back to resolving this root bookmark and appending the clip's path
//  relative to `rootPath`. Lives in the local VideosStore alongside
//  VideoRecording — bookmarks don't translate across devices, so this must
//  never sync via CloudKit.
//

import SwiftData
import Foundation

@Model
final class ImportSource {
    /// Security-scoped bookmark of the picked root folder.
    var bookmark: Data = Data()
    /// Original absolute path of the picked folder — clips' relative paths
    /// are derived against this prefix, and re-imports match on it.
    var rootPath: String = ""
    /// Folder name shown in any UI that lists sources (e.g. "TeslaCam").
    var displayName: String = ""

    init(bookmark: Data, rootPath: String, displayName: String) {
        self.bookmark = bookmark
        self.rootPath = rootPath
        self.displayName = displayName
    }
}
