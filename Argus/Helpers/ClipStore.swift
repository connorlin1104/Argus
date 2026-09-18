//
//  ClipStore.swift
//  Argus
//
//  App-owned storage for imported clip files. Clips used to stay on the
//  source drive with security-scoped bookmarks pointing at them — unplug the
//  SSD and every video stopped playing. The normal workflow is "plug the
//  drive in, import, put it back in the car", so import copies each event's
//  clips in here and playback reads the copy.
//
//  Files are keyed by their Tesla filename (timestamp + camera), which is
//  unique per physical clip and lets the copies Tesla writes into overlapping
//  event folders share one stored file. Only the filename is persisted on
//  VideoRecording (localFileName) — absolute container paths change across
//  app updates, so URLs are resolved fresh against the current container.
//

import Foundation

enum ClipStore {

    /// Application Support/Clips, created on first use. Not the Caches
    /// directory: once the drive goes back in the car and gets overwritten,
    /// these are the user's only copy — the OS must never purge them.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sweep staging leftovers from a kill mid-copy — truncated junk that
        // must never be mistaken for a stored clip.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in leftovers where file.lastPathComponent.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: file)
        }
        return dir
    }()

    static func url(forFileName fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Copy a source clip into the store and return the stored filename.
    /// An already-stored file is reused as-is: the same clip arrives under
    /// several paths (overlapping event folders, re-imports) and must not
    /// duplicate gigabytes. The copy lands under a temporary name first and
    /// is renamed into place, so a kill mid-copy can never leave a truncated
    /// file that later looks importable.
    static func importCopy(from source: URL) throws -> String {
        let fileName = source.lastPathComponent
        let destination = url(forFileName: fileName)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            return fileName
        }
        let sourceBytes = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard hasSpace(for: sourceBytes) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let staging = directory.appendingPathComponent(fileName + ".partial")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        try fm.moveItem(at: staging, to: destination)
        return fileName
    }

    /// Whether the volume can take `bytes` more while keeping a safety
    /// margin free — an import must never run the device out of disk.
    static func hasSpace(for bytes: Int64) -> Bool {
        // TUNING: minimum free space to leave on the volume after copying.
        let margin: Int64 = 2_000_000_000
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > bytes + margin
    }

    static func delete(fileName: String) {
        guard !fileName.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(forFileName: fileName))
    }

    /// Remove stored files no VideoRecording references. An import killed
    /// before its records saved leaves its copied files orphaned — silent
    /// gigabytes the user can't see or delete. Called at launch, before any
    /// import can start copying.
    static func removeOrphans(keeping referenced: Set<String>) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in contents where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Total bytes of stored clips, for the Settings storage footer.
    static func totalBytes() -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.reduce(Int64(0)) { sum, file in
            sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}
