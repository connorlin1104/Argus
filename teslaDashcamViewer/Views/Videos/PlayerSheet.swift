//
//  PlayerSheet.swift
//  teslaDashcamViewer
//
//  Modal sheet that plays a single video file with a small header bar.
//  Used by VideoListView when the user taps a row's play button.
//  Search keywords: UI:player-sheet, BUTTON:close-sheet, LAYOUT:sheet
//

import SwiftUI

/// Wrapper that gives a URL an Identifiable conformance so it can drive a sheet binding.
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Sheet that plays a single clip. Header shows the filename + a close button.
struct PlayerSheet: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // UI: header bar with filename + close button
            HStack {
                // TEXT: filename in monospaced caption
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                // BUTTON: close sheet
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill") // ICON: close
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // LAYOUT: header padding
            .padding(12)

            // UI: actual video player
            VideoPlayerView(videoURL: url)
                // LAYOUT: 16:9 video area
                .aspectRatio(16/9, contentMode: .fit)
        }
        // LAYOUT: minimum sheet size
        .frame(minWidth: 640, minHeight: 400)
    }
}
