//
//  VideoPlayerView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?
    @State private var didAccess: Bool = false

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                didAccess = videoURL.startAccessingSecurityScopedResource()
                
                if didAccess {
                    player = AVPlayer(url: videoURL)
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
