//
//  TeslaDashcamImporter.swift
//  Argus
//
//  Created by Connor Lin on 8/17/25.
//

import Foundation
import AVFoundation

//["0"] = "Front", ["3"] = "Left", ["4"] = "Right", ["5"] = "Rear"

enum FilenameParseError: Error, LocalizedError {
    case invalidFormat
    case invalidDate(String)
    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Filename doesn't match expected pattern: YYYY-MM-DD_HH-mm-ss_label.ext"
        case .invalidDate(let s): return "Unable to parse date from '\(s)'"
        }
    }
}


/// How a folder import pass ended — feeds the finish banner.
struct ImportRunSummary {
    var skippedByDateFilter = 0
    var cancelled = false
}

/// Walk the picked folder and stream each event to `onEvent` as soon as it's
/// read, so the caller can persist incrementally — a cancelled or killed
/// import keeps everything already delivered. `onProgress` reports
/// (processed, total) directory counts for the determinate banner.
func importEvents(
    url: URL,
    scope: ImportScope = .everything,
    onProgress: @MainActor (Int, Int) async -> Void = { _, _ in },
    onEvent: @MainActor (Event, [VideoRecording]) async -> Void
) async -> ImportRunSummary {
    var summary = ImportRunSummary()
    let directories = eventDirectories(under: url)
    let kept = directories.filter { ImportDateFilter.shouldImport(directory: $0, scope: scope) }
    summary.skippedByDateFilter = directories.count - kept.count

    await onProgress(0, kept.count)
    for (index, eventDirectory) in kept.enumerated() {
        if Task.isCancelled {
            summary.cancelled = true
            break
        }
        let eventURL = eventDirectory.appendingPathComponent("event.json")
        if let (event, videos) = await importEvent(eventURL: eventURL, eventDirectory: eventDirectory) {
            await onEvent(event, videos)
        }
        await onProgress(index + 1, kept.count)
    }
    return summary
}

/// Every directory at or under `root` that holds an event.json, descending a
/// few levels so picking TeslaCam, SentryClips, or a single event folder all
/// import the same way. Depth-limited so a mistaken pick of a huge unrelated
/// folder doesn't walk the whole drive. Also used by ImportSizeEstimator so
/// the scope sheet's disk estimate counts exactly what an import would read.
func eventDirectories(under root: URL, depth: Int = 3) -> [URL] {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: root.appendingPathComponent("event.json").path) {
        return [root]
    }
    guard depth > 0 else { return [] }

    let children = (try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    )) ?? []

    return children
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        .flatMap { eventDirectories(under: $0, depth: depth - 1) }
}

/// File-based importer used as the iOS fallback when the system folder picker
/// won't surface an "Open" affordance for USB / SD storage providers. The
/// caller is expected to have picked an `event.json` plus its sibling `.mp4`
/// clips from a single Tesla event folder; we group by parent directory so
/// multiple events selected in one picker session still cluster correctly.
func importEventsFromFiles(
    urls: [URL],
    onEvent: @MainActor (Event, [VideoRecording]) async -> Void
) async {
    var grouped: [URL: [URL]] = [:]
    for url in urls {
        grouped[url.deletingLastPathComponent(), default: []].append(url)
    }

    for (_, files) in grouped {
        if Task.isCancelled { break }
        guard let eventJSONURL = files.first(where: { $0.lastPathComponent == "event.json" }) else {
            // No event.json in this group — skip; we don't have enough
            // metadata to construct an Event (camera/city/reason/timestamp).
            continue
        }
        let mp4s = files.filter { $0.pathExtension.lowercased() == "mp4" }
        if let (event, videos) = await importEvent(eventJSONURL: eventJSONURL, videoFiles: mp4s) {
            await onEvent(event, videos)
        }
    }
}

func importEvent(eventURL: URL, eventDirectory: URL) async -> (event: Event, videos: [VideoRecording])? {
    let fileManager = FileManager.default
    let videoURLs: [URL]
    do {
        videoURLs = try fileManager.contentsOfDirectory(
            at: eventDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.pathExtension.lowercased() == "mp4" }
    } catch {
        print("importEvent enumerate error: \(error)")
        return nil
    }
    return await importEvent(eventJSONURL: eventURL, videoFiles: videoURLs)
}

/// Shared event-construction path used by both the folder-based and
/// file-based importers. Callers pass the `event.json` URL plus the list of
/// `.mp4` files they want associated with it.
func importEvent(eventJSONURL: URL, videoFiles: [URL]) async -> (event: Event, videos: [VideoRecording])? {
    do {
        // A real Tesla event.json is well under 1 KB. Refuse absurd files so
        // a mislabeled or hostile "event.json" can't balloon memory — and
        // trim each field below, since these strings flow straight into the
        // UI and the (CloudKit-synced) store.
        if let size = try? eventJSONURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 1_000_000 {
            print("importEvent: skipping oversized event.json (\(size) bytes)")
            return nil
        }
        let data = try Data(contentsOf: eventJSONURL)
        guard let jsonDict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }

        func field(_ key: String) -> String? {
            guard let raw = jsonDict[key] as? String else { return nil }
            return String(raw.prefix(256))
        }
        guard let camera = field("camera"),
              let city = field("city"),
              let estLatitude = field("est_lat"),
              let estLongitude = field("est_lon"),
              let reason = field("reason"),
              let timestampString = field("timestamp") else {
            return nil
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let timestamp = df.date(from: timestampString) else {
            return nil
        }

        let sentryEvent = Event(source: "Tesla",
                                camera: camera,
                                city: city,
                                estLatitude: estLatitude,
                                estLongitude: estLongitude,
                                reason: reason,
                                timestamp: timestamp)

        // Read real durations from the assets instead of assuming 60s.
        // Loaded concurrently — it's a metadata-only read, and awaiting each
        // clip one-by-one dominated import time on big folders.
        let durations: [URL: TimeInterval] = await withTaskGroup(
            of: (URL, TimeInterval?).self
        ) { group in
            for file in videoFiles {
                group.addTask { (file, await videoDurationSeconds(url: file)) }
            }
            var result: [URL: TimeInterval] = [:]
            for await (file, seconds) in group {
                if let seconds { result[file] = seconds }
            }
            return result
        }

        var videos: [VideoRecording] = []
        for file in videoFiles {
            // Cancel responsively: dropping the whole in-progress event (nil
            // below) is safe — import only records references, so a re-run
            // just reads the same metadata again.
            if Task.isCancelled { return nil }
            let (parsedStart, cameraName) = parseFilename(file.lastPathComponent)
            guard let startTime = parsedStart else {
                continue
            }

            let durationSeconds = durations[file] ?? 60
            let endTime = startTime.addingTimeInterval(durationSeconds)

            // Reference-only import: the clip stays on the drive, found again
            // through its own bookmark (or the ImportSource root fallback).
            // Nothing is copied — a 3k-clip SSD imports in seconds and costs
            // near-zero disk. Footage lands in app storage only when the user
            // (or an auto-keep rule) Keeps the event; see EventFootageKeeper.
            let driveBookmark = BookmarkResolver.mint(for: file) ?? Data()

            videos.append(VideoRecording(url: file, bookmark: driveBookmark, camera: cameraName,
                                         startTime: startTime, endTime: endTime,
                                         localFileName: ""))
        }
        return (sentryEvent, videos)
    } catch {
        print("importEvent error: \(error)")
        return nil
    }
}

private func videoDurationSeconds(url: URL) async -> TimeInterval? {
    let asset = AVURLAsset(url: url)
    do {
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    } catch {
        return nil
    }
}

func parseFilename(_ filename: String, timeZone: TimeZone = .current) -> (date: Date?, cameraID: String) {
    // Get just the file name without extension
    let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    
    // First 19 chars = timestamp
    let timestampPart = String(base.prefix(19))
    // Rest after underscore or dash = camera ID
    let cameraID = String(base.dropFirst(20)) // skip 19 chars + 1 separator

    // Parse date
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = timeZone
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let date = df.date(from: timestampPart)

    return (date, cameraID)
}

