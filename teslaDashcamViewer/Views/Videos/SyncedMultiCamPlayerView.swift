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
    @State private var focusedCamera: String? = nil

    /// Canonical display order. Only cameras that exist in `videos` are shown.
    private let preferredCameraOrder: [String] = ["front", "left_repeater", "right_repeater", "back"]

    // === TUNING KNOBS ===
    /// Max width of the 2x2 grid.
    private let playerMaxWidth: CGFloat = 1050
    /// Max width of the focused tile. Slightly larger than `playerMaxWidth` because
    /// the grid's 4-pt inter-tile spacing makes the 2x2 layout feel a touch wider
    /// than a single tile at the same cap.
    private let focusTileMaxWidth: CGFloat = 1052
    /// Width of the camera-button column. Sits OUTSIDE the player's maxWidth so the
    /// focused tile isn't shrunk to make room — the layout is intentionally asymmetric.
    private let cameraSidebarWidth: CGFloat = 110

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
            wallClockBadge
                .padding(.top, -12)
            HStack(alignment: .top, spacing: 20) {
                if let focused = focusedCamera {
                    Spacer()
                        .frame(width: cameraSidebarWidth)
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
                tile(camID: camID, showsExitButton: false)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            focusedCamera = camID
                        }
                    }
            }
        }
    }

    private var focusLayout: some View {
        let focused = focusedCamera ?? orderedCameras.first ?? ""
        return HStack(alignment: .top, spacing: 8) {
            tile(camID: focused, showsExitButton: false)
                .layoutPriority(1)
            // === ADJUST `cameraSidebarWidth` (top of file) to change focus tile size ===
            cameraButtonColumn(active: focused)
                .frame(width: cameraSidebarWidth)
        }
    }

    private func cameraButtonColumn(active: String) -> some View {
        VStack(spacing: 6) {
            ForEach(orderedCameras, id: \.self) { camID in
                let name = TeslaCamera.displayName(for: camID)
                let label = name.isEmpty ? camID.capitalized : name
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        focusedCamera = camID
                    }
                } label: {
                    Text(label)
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(active == camID ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(active == camID ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                        .foregroundStyle(active == camID ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    focusedCamera = nil
                }
            } label: {
                Label("Grid", systemImage: "rectangle.split.2x2.fill")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    /// One camera tile. When `showsExitButton` is true, overlays a button
    /// that returns to the 2x2 grid.
    private func tile(camID: String, showsExitButton: Bool) -> some View {
        let name = TeslaCamera.displayName(for: camID)
        let label = name.isEmpty ? "Camera" : name
        return ZStack(alignment: .topLeading) {
            if let player = players[camID] {
                PlayerLayerView(player: player)
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .allowsHitTesting(false)
            } else {
                Color.black
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .overlay(
                        Text("No \(label) feed")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    )
            }
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
            if showsExitButton {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        focusedCamera = nil
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x2.fill")
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .help("Back to grid")
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

        // Auto-play once setup is complete.
        isPlaying = true
        for (cam, player) in players {
            let offset = offsets[cam] ?? 0
            let duration = durations[cam] ?? 0
            let local = positionSeconds - offset
            if local >= 0 && local <= duration {
                player.play()
            }
        }
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
