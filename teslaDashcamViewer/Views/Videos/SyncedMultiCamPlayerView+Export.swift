//
//  SyncedMultiCamPlayerView+Export.swift
//  teslaDashcamViewer
//
//  macOS-only: export a ±5 second clip from the primary camera around the
//  current scrubber position.
//  Search keywords: BUTTON:export, EXPORT:clip
//

import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
#endif

#if os(macOS)
extension SyncedMultiCamPlayerView {
    /// Export a ±5s clip from the primary camera at the current scrubber position.
    /// TUNING: change ±5 below to widen/narrow the exported window.
    @MainActor
    func exportCurrentClip() async {
        guard let sourceURL = resolvedURLs[primaryCamera] else { return }
        let localTime = positionSeconds - (offsets[primaryCamera] ?? 0)
        let duration = durations[primaryCamera] ?? 0
        let startLocal = max(0, localTime - 5)
        let endLocal = min(duration, localTime + 5)
        guard endLocal > startLocal else { return }

        // UI: macOS save panel for choosing destination .mp4
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let stamp = Int(Date().timeIntervalSince1970)
        // TEXT: default filename pattern
        panel.nameFieldStringValue = "clip-\(TeslaCamera.displayName(for: primaryCamera))-\(stamp).mp4"
        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        isExporting = true
        defer { isExporting = false }

        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else { return }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: startLocal, preferredTimescale: 600),
            end: CMTime(seconds: endLocal, preferredTimescale: 600)
        )
        try? FileManager.default.removeItem(at: destURL)

        do {
            try await exporter.export(to: destURL, as: .mp4)
        } catch {
            print("Export failed: \(error)")
        }
    }
}
#endif
