//
//  SyncedMultiCamPlayerView.swift
//  teslaDashcamViewer
//
//  Multi-camera synchronized playback. Plays Front/Left/Right/Rear in a
//  2x2 grid driven by a single play/pause/scrub controller. Tapping a tile
//  enters focus mode where the chosen camera is enlarged.
//
//  Sibling files (extensions on this view):
//   - SyncedMultiCamPlayerView+Tiles.swift     — grid + tile + sidebar UI
//   - SyncedMultiCamPlayerView+Controls.swift  — wall clock, scrubber, keyboard
//   - SyncedMultiCamPlayerView+Playback.swift  — AVPlayer setup / teardown / seek
//   - SyncedMultiCamPlayerView+Export.swift    — ±5s clip export (macOS)
//
//  Search keywords: UI:multi-cam, LAYOUT:multi-cam, TUNING:multi-cam
//

import SwiftUI
import AVKit
import SwiftData

struct SyncedMultiCamPlayerView: View {
    let videos: [VideoRecording]

    // === Playback state (shared with the +Playback / +Controls / +Export extensions) ===
    // NOTE: these are intentionally `internal` (no `private`) so the sibling
    // extension files can read/write them. Don't make these `private`.
    @State var players: [String: AVPlayer] = [:]
    @State var resolvedURLs: [String: URL] = [:]
    @State var offsets: [String: Double] = [:]     // seconds from anchor
    @State var durations: [String: Double] = [:]
    @State var anchor: Date = .distantFuture
    @State var totalDuration: Double = 0
    @State var positionSeconds: Double = 0
    @State var isPlaying: Bool = false
    @State var timeObserverToken: Any?
    @State var primaryCamera: String = ""
    @State var isScrubbing: Bool = false
    @State var isExporting: Bool = false
    @State var focusedCamera: String? = nil

    /// LAYOUT: Canonical camera display order. Only cameras present in `videos` show up.
    let preferredCameraOrder: [String] = ["front", "left_repeater", "right_repeater", "back"]

    // === TUNING KNOBS ===
    /// LAYOUT: Max width of the 2x2 grid.
    let playerMaxWidth: CGFloat = 1050
    /// LAYOUT: Max width of the focused tile. Slightly larger than `playerMaxWidth`
    /// because the grid's 4-pt inter-tile spacing makes the 2x2 layout feel a touch
    /// wider than a single tile at the same cap.
    let focusTileMaxWidth: CGFloat = 1052
    /// LAYOUT: Width of the camera-button column. Sits OUTSIDE the player's maxWidth so
    /// the focused tile isn't shrunk to make room — intentionally asymmetric.
    let cameraSidebarWidth: CGFloat = 110

    /// Cameras to render, in display order, deduped.
    var orderedCameras: [String] {
        let present = Array(Set(videos.map { TeslaCamera.canonical($0.camera) }))
        var ordered = preferredCameraOrder.filter { present.contains($0) }
        // Append anything unknown at the end so we never silently hide a clip.
        for cam in present where !preferredCameraOrder.contains(cam) {
            ordered.append(cam)
        }
        return ordered
    }

    /// Fingerprint used to drive `.task(id:)` — when the input video list changes,
    /// we tear down & re-setup the players.
    var videoFingerprint: String {
        videos.map { "\($0.url.path)|\($0.startTime.timeIntervalSince1970)" }
              .joined(separator: ",")
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 8) {
            // UI: floating wall-clock badge above the grid
            wallClockBadge
                .padding(.top, -12)

            // UI: main player area — either 2x2 grid or focus mode with sidebar
            HStack(alignment: .top, spacing: 20) {
                if let focused = focusedCamera {
                    Spacer().frame(width: cameraSidebarWidth)
                    tile(camID: focused, showsExitButton: false)
                        .frame(maxWidth: focusTileMaxWidth)
                    cameraButtonColumn(active: focused)
                        .frame(width: cameraSidebarWidth)
                } else {
                    grid
                        .frame(maxWidth: playerMaxWidth)
                }
            }
            .frame(maxWidth: .infinity)

            keyboardShortcutLayer

            // UI: transport bar (play/pause + scrubber + time + export)
            controlBar
        }
        .task(id: videoFingerprint) {
            setupPlayers()
        }
        .onDisappear {
            tearDown()
        }
    }
}
