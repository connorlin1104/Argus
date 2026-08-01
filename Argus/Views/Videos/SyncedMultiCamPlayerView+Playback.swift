//
//  SyncedMultiCamPlayerView+Playback.swift
//  Argus
//
//  AVPlayer lifecycle and seek logic for the synced multi-cam player.
//  Owns: setup, teardown, play/pause, seek-all, bookmark resolution.
//  Search keywords: PLAYBACK:setup, PLAYBACK:seek, PLAYBACK:teardown
//

import SwiftUI
import AVKit

extension SyncedMultiCamPlayerView {

    // MARK: - Setup

    /// Build one AVPlayer per camera, anchored to the earliest clip's start time.
    /// Auto-starts playback once the players are wired up.
    func setupPlayers() {
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
        primaryCamera = preferredCameraOrder.first(where: { players[$0] != nil })
            ?? (players.keys.first ?? "")
        attachPrimaryTimeObserver()

        seekAll(to: 0)
        autoPlayAfterSetup()
    }

    /// Measure each clip's real width:height ratio off its video track.
    /// Runs after `setupPlayers()`; tiles show the 4:3 fallback until the
    /// ratio for their camera lands (imperceptible for local files).
    func loadAspectRatios() async {
        for (cam, url) in resolvedURLs {
            if let ratio = await VideoAspect.ratio(of: url) {
                aspectRatios[cam] = ratio
            }
        }
    }

    /// Auto-play once setup is complete.
    private func autoPlayAfterSetup() {
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

    /// Periodic time observer that mirrors the primary camera's clock into our
    /// global scrubber position.
    func attachPrimaryTimeObserver() {
        guard let primary = players[primaryCamera] else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = primary.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if isScrubbing { return }
            let primaryOffset = offsets[primaryCamera] ?? 0
            positionSeconds = min(totalDuration, max(0, primaryOffset + time.seconds))
        }
    }

    // MARK: - Teardown

    func tearDown() {
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
        aspectRatios.removeAll()
        isPlaying = false
    }

    // MARK: - Transport

    func togglePlay() {
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

    /// Lightweight seek used while the user is actively dragging the scrubber.
    /// Uses a looser tolerance than `seekAll` so AVPlayer can satisfy the
    /// stream of seek requests in real time, and keeps every player paused
    /// (regardless of `isPlaying`) so the frame visibly follows the thumb.
    func scrubSeekAll(to seconds: Double) {
        // PLAYBACK: tolerance for live scrub seeks — too tight and AVPlayer
        // can't keep up with finger movement; too loose and the thumb jumps
        // to a frame several hundred ms away.
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        for (cam, player) in players {
            let offset = offsets[cam] ?? 0
            let duration = durations[cam] ?? 0
            let local = seconds - offset
            player.pause()
            if local < 0 {
                player.seek(to: .zero, toleranceBefore: tolerance, toleranceAfter: tolerance)
            } else if local > duration {
                player.seek(to: CMTime(seconds: duration, preferredTimescale: 600),
                            toleranceBefore: tolerance, toleranceAfter: tolerance)
            } else {
                player.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                            toleranceBefore: tolerance, toleranceAfter: tolerance)
            }
        }
    }

    /// Seek every camera to the equivalent local time. Clamps to each clip's
    /// duration so cameras that started later or ended earlier just sit on
    /// the correct edge frame.
    func seekAll(to seconds: Double) {
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

    // MARK: - Bookmark resolution

    func resolveBookmark(bookmarkData: Data) -> URL? {
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
}
