//
//  SyncedMultiCamPlayerView.swift
//  teslaDashcamViewer
//
//  Multi-camera synchronized playback. Plays Front/Left/Right/Rear in a
//  2x2 grid driven by a single play/pause/scrub controller.
//

import SwiftUI
import AVKit
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct SyncedMultiCamPlayerView: View {
    let videos: [VideoRecording]

    @State private var players: [String: AVPlayer] = [:]
    @State private var resolvedURLs: [String: URL] = [:]
    @State private var offsets: [String: Double] = [:]     // seconds from anchor
    @State private var durations: [String: Double] = [:]
    @State private var anchor: Date = .distantFuture
    @State private var totalDuration: Double = 0
    @State private var positionSeconds: Double = 0
    @State private var isPlaying: Bool = false
    @State private var timeObserverToken: Any?
    @State private var primaryCamera: String = ""
    @State private var isScrubbing: Bool = false
    @State private var isExporting: Bool = false

    /// Canonical display order. Only cameras that exist in `videos` are shown.
    private let preferredCameraOrder: [String] = ["front", "left_repeater", "right_repeater", "back"]

    private var orderedCameras: [String] {
        let present = Array(Set(videos.map { TeslaCamera.canonical($0.camera) }))
        var ordered = preferredCameraOrder.filter { present.contains($0) }
        // Append anything unknown at the end so we never silently hide a clip.
        for cam in present where !preferredCameraOrder.contains(cam) {
            ordered.append(cam)
        }
        return ordered
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                grid
                wallClockBadge
                    .padding(.top, 10)
            }

            keyboardShortcutLayer

            HStack(spacing: 12) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])

                ZStack(alignment: .top) {
                    Slider(
                        value: $positionSeconds,
                        in: 0...max(totalDuration, 0.1),
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            if !editing { seekAll(to: positionSeconds) }
                        }
                    )
                    GeometryReader { geo in
                        ForEach(allMarkers, id: \.self) { marker in
                            let fraction = totalDuration > 0 ? marker.eventSeconds / totalDuration : 0
                            Rectangle()
                                .fill(markerColor(marker.kind))
                                .frame(width: 2, height: 8)
                                .offset(x: CGFloat(fraction) * geo.size.width, y: -2)
                        }
                    }
                    .frame(height: 8)
                    .allowsHitTesting(false)
                }

                Text(timeString(positionSeconds) + " / " + timeString(totalDuration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                #if os(macOS)
                Button {
                    Task { await exportCurrentClip() }
                } label: {
                    Label("Export ±5s", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .help("Export a 10-second clip around the current position")
                .disabled(isExporting)
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .liquidGlassCard(cornerRadius: 14)
            .padding(.horizontal)
        }
        .task(id: videoFingerprint) {
            setupPlayers()
        }
        .onDisappear {
            tearDown()
        }
    }

    private var grid: some View {
        let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(orderedCameras, id: \.self) { camID in
                ZStack(alignment: .topLeading) {
                    if let player = players[camID] {
                        VideoPlayer(player: player)
                            // Tesla cameras output 4:3. Letting hit-testing through
                            // lets the parent ScrollView still receive scroll events.
                            .aspectRatio(4.0/3.0, contentMode: .fit)
                            .allowsHitTesting(false)
                    } else {
                        Color.black
                            .aspectRatio(4.0/3.0, contentMode: .fit)
                            .overlay(
                                Text("No \(TeslaCamera.displayName(for: camID)) feed")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            )
                    }
                    Text(TeslaCamera.displayName(for: camID))
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var videoFingerprint: String {
        videos.map { "\($0.url.path)|\($0.startTime.timeIntervalSince1970)" }.joined(separator: ",")
    }

    private func setupPlayers() {
        tearDown()
        guard !videos.isEmpty else {
            print("SyncedMultiCamPlayerView: no matched videos")
            return
        }

        // Anchor = earliest start time across cameras.
        let earliest = videos.map(\.startTime).min() ?? Date()
        anchor = earliest

        var newPlayers: [String: AVPlayer] = [:]
        var newURLs: [String: URL] = [:]
        var newOffsets: [String: Double] = [:]
        var newDurations: [String: Double] = [:]
        var maxEnd: Double = 0

        for video in videos {
            let camKey = TeslaCamera.canonical(video.camera)
            // De-duplicate: if we already created a player for this canonical camera, skip.
            if newPlayers[camKey] != nil { continue }

            guard let url = resolveBookmark(bookmarkData: video.bookmark) else {
                print("SyncedMultiCamPlayerView: failed to resolve bookmark for camera \(camKey)")
                continue
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            print("SyncedMultiCamPlayerView: cam=\(camKey) didAccess=\(didAccess) url=\(url.lastPathComponent)")

            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            newPlayers[camKey] = player
            newURLs[camKey] = url
            let offset = video.startTime.timeIntervalSince(earliest)
            newOffsets[camKey] = offset
            let duration = video.endTime.timeIntervalSince(video.startTime)
            newDurations[camKey] = duration
            maxEnd = max(maxEnd, offset + duration)
        }

        players = newPlayers
        resolvedURLs = newURLs
        offsets = newOffsets
        durations = newDurations
        totalDuration = maxEnd
        positionSeconds = 0

        // Pick a primary camera to drive time updates (prefer Front).
        primaryCamera = preferredCameraOrder.first(where: { players[$0] != nil }) ?? (players.keys.first ?? "")
        attachPrimaryTimeObserver()

        seekAll(to: 0)
    }

    private func attachPrimaryTimeObserver() {
        guard let primary = players[primaryCamera] else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = primary.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if isScrubbing { return }
            let primaryOffset = offsets[primaryCamera] ?? 0
            positionSeconds = min(totalDuration, max(0, primaryOffset + time.seconds))
        }
    }

    private func tearDown() {
        if let token = timeObserverToken, let primary = players[primaryCamera] {
            primary.removeTimeObserver(token)
        }
        timeObserverToken = nil
        for (_, player) in players { player.pause() }
        for (_, url) in resolvedURLs { url.stopAccessingSecurityScopedResource() }
        players.removeAll()
        resolvedURLs.removeAll()
        offsets.removeAll()
        durations.removeAll()
        isPlaying = false
    }

    private func togglePlay() {
        isPlaying.toggle()
        for (cam, player) in players {
            let offset = offsets[cam] ?? 0
            let duration = durations[cam] ?? 0
            let local = positionSeconds - offset
            if local < 0 || local > duration {
                player.pause()
                continue
            }
            if isPlaying {
                player.play()
            } else {
                player.pause()
            }
        }
    }

    private func seekAll(to seconds: Double) {
        for (cam, player) in players {
            let offset = offsets[cam] ?? 0
            let duration = durations[cam] ?? 0
            let local = seconds - offset
            if local < 0 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                player.pause()
            } else if local > duration {
                player.seek(to: CMTime(seconds: duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                player.pause()
            } else {
                player.seek(to: CMTime(seconds: local, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if isPlaying { player.play() }
            }
        }
    }

    private func resolveBookmark(bookmarkData: Data) -> URL? {
        var isStale = false
        do {
            #if os(iOS)
                return try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
            #else
                return try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            #endif
        } catch {
            print("Bookmark resolution error: \(error)")
            return nil
        }
    }

    private var keyboardShortcutLayer: some View {
        // Invisible buttons that wire keyboard shortcuts to playback actions.
        // J/K/L mirror video-editor conventions; ←/→ scrub by 5 s.
        ZStack {
            Button("") { seekRelative(-5) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { seekRelative(5) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { seekRelative(-10) }.keyboardShortcut("j", modifiers: [])
            Button("") { togglePlay() }.keyboardShortcut("k", modifiers: [])
            Button("") { seekRelative(10) }.keyboardShortcut("l", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    private func seekRelative(_ delta: Double) {
        let target = min(max(0, positionSeconds + delta), totalDuration)
        positionSeconds = target
        seekAll(to: target)
    }

    private func timeString(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Wall-clock timestamp showing the real moment captured by the videos
    /// (anchor + current playback position).
    private var wallClockBadge: some View {
        let now = anchor.addingTimeInterval(positionSeconds)
        let dateString = now.formatted(date: .abbreviated, time: .omitted)
        let timeStringValue = now.formatted(date: .omitted, time: .standard)
        return VStack(spacing: 0) {
            Text(timeStringValue)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
            Text(dateString)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
        .allowsHitTesting(false)
    }

    private struct EventMarker: Hashable {
        let kind: String
        let eventSeconds: Double
    }

    private var allMarkers: [EventMarker] {
        var out: [EventMarker] = []
        for video in videos {
            let offset = offsets[video.camera] ?? video.startTime.timeIntervalSince(anchor)
            for m in video.markers {
                out.append(EventMarker(kind: m.kind, eventSeconds: offset + Double(m.timestampMs) / 1000.0))
            }
        }
        return out
    }

    private func markerColor(_ kind: String) -> Color {
        switch kind {
        case "human": return .red
        case "vehicle": return .purple
        case "licensePlate": return .blue
        default: return .yellow
        }
    }

    #if os(macOS)
    /// Export a ±5s clip from the primary camera at the current scrubber position.
    @MainActor
    private func exportCurrentClip() async {
        guard let sourceURL = resolvedURLs[primaryCamera] else { return }
        let localTime = positionSeconds - (offsets[primaryCamera] ?? 0)
        let duration = durations[primaryCamera] ?? 0
        let startLocal = max(0, localTime - 5)
        let endLocal = min(duration, localTime + 5)
        guard endLocal > startLocal else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let stamp = Int(Date().timeIntervalSince1970)
        panel.nameFieldStringValue = "clip-\(TeslaCamera.displayName(for: primaryCamera))-\(stamp).mp4"
        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        isExporting = true
        defer { isExporting = false }

        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return }
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
    #endif
}
