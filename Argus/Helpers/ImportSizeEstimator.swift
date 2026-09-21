//
//  ImportSizeEstimator.swift
//  Argus
//
//  Sizes the disk cost of an import before it starts: clips are copied into
//  app-owned storage (see ClipStore.importCopy), so importing a months-deep
//  SSD adds its full clip size to this device. The scope sheet shows these
//  numbers per option so the user can pick a range that fits their disk.
//  Metadata-only by design — no video file is ever opened.
//
//  Search keywords: IMPORT:size-estimate, UI:import-scope
//

import Foundation

enum ImportSizeEstimator {

    /// One event directory's clip payload. `date` is parsed from the folder
    /// name; nil means unparseable — those directories import under every
    /// scope (the date filter fails open), so they count toward every option.
    struct DirectorySize: Equatable, Sendable {
        let date: Date?
        let bytes: Int64
    }

    /// Walk the picked folder and sum each event directory's .mp4 sizes.
    /// Call off the main actor — a big USB drive holds thousands of files
    /// and slow storage providers can take a second or two of metadata I/O.
    static func scan(url: URL) -> [DirectorySize] {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return eventDirectories(under: url).map { directory in
            DirectorySize(date: ImportDateFilter.folderDate(directory.lastPathComponent),
                          bytes: clipBytes(in: directory))
        }
    }

    /// Total bytes an import with this scope would copy. Mirrors
    /// ImportDateFilter.shouldImport: no range means everything, and
    /// undated directories are always included (fail-open).
    static func bytes(for scope: ImportScope, sizes: [DirectorySize], now: Date = Date()) -> Int64 {
        guard let range = ImportDateFilter.dateRange(for: scope, now: now) else {
            return sizes.reduce(0) { $0 + $1.bytes }
        }
        return sizes.reduce(0) { total, directory in
            guard let date = directory.date else { return total + directory.bytes }
            return range.contains(date) ? total + directory.bytes : total
        }
    }

    private static func clipBytes(in directory: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        )) ?? []
        return files.reduce(0) { total, file in
            guard file.pathExtension.lowercased() == "mp4",
                  let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                return total
            }
            return total + Int64(size)
        }
    }
}
