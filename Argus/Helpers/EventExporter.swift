//
//  EventExporter.swift
//  Argus
//
//  Bundles selected events + their matching video clips into a single zip
//  via NSFileCoordinator(.forUploading:). Layout:
//
//     export.zip/
//        <yyyy-MM-dd-HHmmss-eventID>/
//            front.mp4
//            left.mp4
//            ...
//            event.json     (Event metadata + summary)
//

import Foundation
import SwiftData

enum EventExporter {

    enum ExportError: LocalizedError {
        case noEventsSelected
        case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
        case zipFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .noEventsSelected:
                return "No events selected."
            case .insufficientDiskSpace(let required, let available):
                let fmt = ByteCountFormatter()
                return "Not enough free space: the export needs about \(fmt.string(fromByteCount: required)) but only \(fmt.string(fromByteCount: available)) is available."
            case .zipFailed(let underlying):
                return "Couldn't create the zip: \(underlying.localizedDescription)"
            }
        }
    }

    struct ExportResult {
        let zipURL: URL
        /// Clips that were staged into the zip.
        let stagedClips: Int
        /// Source filenames that couldn't be read (unplugged drive, moved
        /// files) and are therefore missing from the zip.
        let skippedClips: [String]
    }

    /// Stages the export bundle and zips it. The result's zipURL points to
    /// the final zip — the caller is responsible for moving it to its final
    /// destination (typically via a save panel) and MUST surface
    /// `skippedClips` to the user: a zip that silently lacks footage is the
    /// worst failure mode for evidence exports.
    ///
    /// - Parameter progress: invoked on the main actor after each event.
    static func export(events: [Event],
                       modelContext: ModelContext,
                       progress: @MainActor @escaping (Double, String) -> Void) async throws -> ExportResult {
        guard !events.isEmpty else { throw ExportError.noEventsSelected }

        // Pair each event with its matching clips (same timestamp-overlap
        // predicate EventDetailView uses) before copying anything, so we can
        // preflight the total size against free disk space.
        var plan: [(event: Event, videos: [VideoRecording])] = []
        for event in events {
            let t = event.timestamp
            let descriptor = FetchDescriptor<VideoRecording>(
                predicate: #Predicate<VideoRecording> { v in
                    v.startTime <= t && v.endTime >= t
                }
            )
            plan.append((event, (try? modelContext.fetch(descriptor)) ?? []))
        }
        try ensureDiskSpace(for: plan.flatMap { $0.videos })

        let staging = EventFileVendor.makeStagingRoot(prefix: "events-export")
        let total = Double(events.count)
        var stagedClips = 0
        var skippedClips: [String] = []

        for (i, entry) in plan.enumerated() {
            let subfolder = folderName(for: entry.event)
            for video in entry.videos {
                do {
                    _ = try EventFileVendor.vend(video: video,
                                                 stagingRoot: staging,
                                                 subfolder: subfolder)
                    stagedClips += 1
                } catch {
                    skippedClips.append(video.url.lastPathComponent)
                }
            }

            // Drop an event.json sidecar describing the event.
            let metaURL = staging
                .appendingPathComponent(subfolder, isDirectory: true)
                .appendingPathComponent("event.json")
            try? FileManager.default.createDirectory(at: metaURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            do {
                try writeMetadata(event: entry.event, to: metaURL)
            } catch {
                skippedClips.append("event.json (\(subfolder))")
            }

            let label = "Staged \(i + 1)/\(events.count)"
            await MainActor.run { progress(Double(i + 1) / total, label) }
        }

        // The zip is self-contained — remove the unzipped staging copies as
        // soon as it exists (or if zipping fails) so plaintext video copies
        // don't linger in the temp dir.
        defer { try? FileManager.default.removeItem(at: staging) }
        let zipURL = try await zip(directory: staging)
        return ExportResult(zipURL: zipURL, stagedClips: stagedClips, skippedClips: skippedClips)
    }

    /// Throw before staging if the temp volume can't hold the staged copies
    /// plus the zip (both exist at once → 2×), with a safety margin.
    private static func ensureDiskSpace(for videos: [VideoRecording]) throws {
        var totalBytes: Int64 = 0
        for video in videos {
            guard let url = BookmarkResolver.resolveURL(for: video) else { continue }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalBytes += Int64(size)
            }
        }
        let required = totalBytes * 2 + 64 * 1024 * 1024
        let tempDir = FileManager.default.temporaryDirectory
        guard let available = try? tempDir
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        else { return }  // capacity unknown — don't block the export on it
        if available < required {
            throw ExportError.insufficientDiskSpace(requiredBytes: required, availableBytes: available)
        }
    }

    /// Wraps `NSFileCoordinator(.forUploading:)`. On both platforms this
    /// produces a real .zip at a temp URL that the caller can move out.
    private static func zip(directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let coordinator = NSFileCoordinator()
            var nsError: NSError?
            coordinator.coordinate(readingItemAt: directory,
                                  options: [.forUploading],
                                  error: &nsError) { zipURL in
                // The coordinator hands us a temporary file — move it to a
                // sibling path so it survives the callback's cleanup.
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Argus-export-\(UUID().uuidString).zip")
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: zipURL, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: ExportError.zipFailed(underlying: error))
                }
            }
            if let nsError {
                cont.resume(throwing: ExportError.zipFailed(underlying: nsError))
            }
        }
    }

    private static func writeMetadata(event: Event, to url: URL) throws {
        struct Meta: Encodable {
            let timestamp: Date
            let camera: String
            let city: String
            let address: String
            let zone: String
            let reason: String
            let tag: String
            let interestingnessScore: Double
            let summary: String
            let notes: String
            let customName: String
            let latitude: String
            let longitude: String
        }
        let meta = Meta(
            timestamp: event.timestamp, camera: event.camera, city: event.city,
            address: event.address, zone: event.zone, reason: event.reason,
            tag: event.tag, interestingnessScore: event.interestingnessScore,
            summary: event.summary, notes: event.notes, customName: event.customName,
            latitude: event.estLatitude, longitude: event.estLongitude
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: url)
    }

    private static func folderName(for event: Event) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = fmt.string(from: event.timestamp)
        let short = String(event.persistentModelID.hashValue & 0xFFFFFF, radix: 16)
        return "\(stamp)-\(short)"
    }
}
