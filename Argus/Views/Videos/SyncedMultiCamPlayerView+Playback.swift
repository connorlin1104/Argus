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
    /// A camera with several matched clips gets them stitched into one seamless
    /// composition — an event moment near a minute boundary matches both the
    /// clip containing it and the one ending just before, and playing only one
    /// arbitrary clip left that tile frozen for the other's minute.
    /// Auto-starts playback once the players are wired up.
    func setupPlayers() async {
        tearDown()
        guard !videos.isEmpty else {
            print("SyncedMultiCamPlayerView: no matched videos")
            return
        }

        // Group per camera; drop copies of the same physical clip (same start
        // second — Tesla writes one file into several event folders), keeping
        // the scanned copy; order chronologically for stitching.
        var byCamera: [String: [VideoRecording]] = [:]
        for video in videos {
            byCamera[TeslaCamera.canonical(video.camera), default: []].append(video)
        }
        var sources: [(cam: String, clips: [(video: VideoRecording, url: URL)])] = []
        for (cam, camVideos) in byCamera {
            var bestByStart: [Int: VideoRecording] = [:]
            for video in camVideos {
                let key = Int(video.startTime.timeIntervalSince1970)
                if let current = bestByStart[key],
                   current.markers.count >= video.markers.count { continue }
                bestByStart[key] = video
            }
            let clips: [(video: VideoRecording, url: URL)] = bestByStart.values
                .sorted { $0.startTime < $1.startTime }
                .compactMap { video in
                    guard let url = BookmarkResolver.resolveURL(for: video) else {
                        print("SyncedMultiCamPlayerView: failed to resolve clip for camera \(cam)")
                        return nil
                    }
                    return (video, url)
                }
            if !clips.isEmpty { sources.append((cam: cam, clips: clips)) }
        }
        guard !sources.isEmpty else { return }

        // Anchor = earliest playable clip start across cameras.
        let earliest = sources.map { $0.clips[0].video.startTime }.min() ?? Date()
        anchor = earliest

        var newPlayers: [String: AVPlayer] = [:]
        var newURLs: [String: URL] = [:]
        var newAssets: [String: AVAsset] = [:]
        var newAccessed: [URL] = []
        var newOffsets: [String: Double] = [:]
        var newDurations: [String: Double] = [:]
        var newMarkers: [String: [DetectionMarker]] = [:]
        var maxEnd: Double = 0

        for (camKey, clips) in sources {
            for (_, url) in clips where url.startAccessingSecurityScopedResource() {
                newAccessed.append(url)
            }
            let camStart = clips[0].video.startTime

            let item: AVPlayerItem
            let duration: Double
            if clips.count == 1 {
                let asset = AVURLAsset(url: clips[0].url)
                item = AVPlayerItem(asset: asset)
                duration = clips[0].video.endTime.timeIntervalSince(camStart)
                newAssets[camKey] = asset
                newMarkers[camKey] = clips[0].video.markers
            } else {
                // Stitch this camera's clips end-to-end at their real offsets,
                // so playback and scrubbing treat them as one recording.
                let composition = AVMutableComposition()
                var cursor = CMTime.zero
                var merged: [DetectionMarker] = []
                for (video, url) in clips {
                    let asset = AVURLAsset(url: url)
                    let assetDuration = (try? await asset.load(.duration))
                        ?? CMTime(seconds: video.endTime.timeIntervalSince(video.startTime),
                                  preferredTimescale: 600)
                    let offset = video.startTime.timeIntervalSince(camStart)
                    let target = CMTime(seconds: offset, preferredTimescale: 600)
                    if target > cursor {
                        // Recording gap between clips — keep later clips at
                        // their true wall-clock position.
                        composition.insertEmptyTimeRange(CMTimeRange(start: cursor, end: target))
                        cursor = target
                    }
                    // Clips can overlap the seam by a moment; skip the part
                    // the previous clip already covered.
                    let sourceStart = CMTime(seconds: max(0, cursor.seconds - offset),
                                             preferredTimescale: 600)
                    let range = CMTimeRange(start: sourceStart, end: assetDuration)
                    guard range.duration > .zero else { continue }
                    do {
                        try await composition.insertTimeRange(range, of: asset, at: cursor)
                    } catch {
                        print("SyncedMultiCamPlayerView: stitch failed for \(camKey): \(error)")
                        continue
                    }
                    cursor = cursor + range.duration
                    let shiftMs = Int(offset * 1000)
                    merged.append(contentsOf: video.markers.map {
                        DetectionMarker(kind: $0.kind, timestampMs: $0.timestampMs + shiftMs)
                    })
                }
                item = AVPlayerItem(asset: composition)
                duration = cursor.seconds
                newAssets[camKey] = composition
                newMarkers[camKey] = merged
            }

            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            newPlayers[camKey] = player
            // Representative URL — feeds the aspect-ratio probe (all of one
            // camera's clips share a ratio).
            newURLs[camKey] = clips[0].url
            let offset = camStart.timeIntervalSince(earliest)
            newOffsets[camKey] = offset
            newDurations[camKey] = duration
            maxEnd = max(maxEnd, offset + duration)
        }

        players = newPlayers
        resolvedURLs = newURLs
        assetsByCamera = newAssets
        accessedURLs = newAccessed
        offsets = newOffsets
        durations = newDurations
        markersByCamera = newMarkers
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
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        players.removeAll()
        resolvedURLs.removeAll()
        assetsByCamera.removeAll()
        accessedURLs.removeAll()
        offsets.removeAll()
        durations.removeAll()
        aspectRatios.removeAll()
        markersByCamera.removeAll()
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

}
