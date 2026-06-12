//
//  VideoPlayerView.swift
//  Argus
//
//  Thin wrapper around AVKit's `VideoPlayer` that manages security-scoped
//  resource access for the URL it's given. Used inside PlayerSheet.
//  Search keywords: UI:video-player, PLAYBACK:single
//

import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?
    @State private var didAccess: Bool = false

    var body: some View {
        // UI: standard AVKit video player with default controls
        VideoPlayer(player: player)
            .onAppear {
                didAccess = videoURL.startAccessingSecurityScopedResource()

                if didAccess {
                    player = AVPlayer(url: videoURL)
                    // PLAYBACK: auto-play on appearance
                    player?.play()
                } else {
                    // Handle error: access denied (e.g., log or show alert)
                    print("Failed to access security-scoped resource for URL: \(videoURL)")
                }
            }
            .onDisappear {
                player?.pause()
                if didAccess {
                    videoURL.stopAccessingSecurityScopedResource()
                    didAccess = false
                }
            }
    }
}
