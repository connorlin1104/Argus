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

    enum ExportError: Error {
        case noEventsSelected
        case zipFailed(underlying: Error)
    }

    /// Stages the export bundle and zips it. The result URL points to the
    /// final zip — the caller is responsible for moving it to its final
    /// destination (typically via a save panel).
    ///
    /// - Parameter progress: invoked on the main actor after each event.
    static func export(events: [Event],
                       modelContext: ModelContext,
                       progress: @MainActor @escaping (Double, String) -> Void) async throws -> URL {
        guard !events.isEmpty else { throw ExportError.noEventsSelected }

        let staging = EventFileVendor.makeStagingRoot(prefix: "events-export")
        let total = Double(events.count)

        for (i, event) in events.enumerated() {
            let subfolder = folderName(for: event)
            // Find the matching videos by timestamp overlap (same predicate
            // EventDetailView uses).
            let t = event.timestamp
            let descriptor = FetchDescriptor<VideoRecording>(
                predicate: #Predicate<VideoRecording> { v in
                    v.startTime <= t && v.endTime >= t
                }
            )
            let matched = (try? modelContext.fetch(descriptor)) ?? []

            for video in matched {
                _ = try? EventFileVendor.vend(video: video,
                                              stagingRoot: staging,
                                              subfolder: subfolder)
            }

            // Drop an event.json sidecar describing the event.
            let metaURL = staging
                .appendingPathComponent(subfolder, isDirectory: true)
                .appendingPathComponent("event.json")
            try? FileManager.default.createDirectory(at: metaURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? writeMetadata(event: event, to: metaURL)

            let label = "Staged \(i + 1)/\(events.count)"
            await MainActor.run { progress(Double(i + 1) / total, label) }
        }

        return try await zip(directory: staging)
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
