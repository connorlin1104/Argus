//
//  VideoRow.swift
//  teslaDashcamViewer
//
//  One row in the videos list: thumbnail + camera name + duration. The whole
//  row is the tap target — tapping anywhere opens the player sheet, with a
//  hover highlight matching the events list.
//  Search keywords: UI:video-row, LAYOUT:video-row, COLOR:video-row
//

import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct VideoRow: View {
    let video: VideoRecording

    @State private var thumbnail: Image?

    /// UI: true while the cursor is over this row — drives the background tint.
    @State private var isHovered: Bool = false

    var body: some View {
        // UI: row layout — the whole row is the tap target.
        HStack(spacing: 12) {
            thumbnailView

            // UI: text labels (camera name, start time, duration)
            VStack(alignment: .leading, spacing: 3) {
                // TEXT: camera display name
                Text(TeslaCamera.displayName(for: video.camera))
                    .font(.headline)
                // TEXT: clip start time
                Text(video.startTime.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                // TEXT: clip duration (M:SS)
                Text(durationString)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        // LAYOUT: horizontal padding so the hover pill has breathing room.
        .padding(.horizontal, 8)
        // LAYOUT: row vertical padding
        .padding(.vertical, 4)
        // UI: hover highlight — subtle accent tint behind the whole row.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .task(id: video.url.path) {
            await loadThumbnail()
        }
    }

    // MARK: - Sub-views

    /// UI: 16:9 thumbnail with rounded corners and a thin border.
    private var thumbnailView: some View {
        ZStack {
            // COLOR: thumbnail placeholder background
            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.6))
            if let thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
            // COLOR: subtle white outline
            RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.1), lineWidth: 0.5)
        }
        // LAYOUT: thumbnail size (16:9)
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    /// TEXT: `M:SS` duration string under the camera name.
    private var durationString: String {
        let s = max(0, Int(video.endTime.timeIntervalSince(video.startTime)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        guard let url = resolve() else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // TUNING: max thumb size — bigger = sharper but more memory.
        gen.maximumSize = CGSize(width: 384, height: 216)
        do {
            let (cgImage, _) = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            #if os(macOS)
            thumbnail = Image(nsImage: NSImage(cgImage: cgImage, size: .zero))
            #else
            thumbnail = Image(uiImage: UIImage(cgImage: cgImage))
            #endif
        } catch {
            // leave nil; row will show placeholder
        }
    }

    private func resolve() -> URL? {
        do {
            var isStale = false
            #if os(iOS)
            return try URL(resolvingBookmarkData: video.bookmark, bookmarkDataIsStale: &isStale)
            #else
            return try URL(resolvingBookmarkData: video.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            #endif
        } catch {
            return nil
        }
    }
}
