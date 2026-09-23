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
import SwiftData

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

        // Widen with continuation clips from the library. The event query
        // only matches clips covering the trigger timestamp, so a camera
        // whose neighbors kept recording showed a black tail for footage
        // that exists one row over in the Videos tab. Any library clip
        // overlapping the matched clips' union window fills that hole —
        // only for cameras the event already shows, and clamped to the
        // window during stitching so the timeline never grows past the
        // matched footage.
        let windowStart = videos.map(\.startTime).min() ?? .distantFuture
        let windowEnd = videos.map(\.endTime).max() ?? .distantPast
        if windowEnd > windowStart {
            let descriptor = FetchDescriptor<VideoRecording>(
                predicate: #Predicate<VideoRecording> { v in
                    v.startTime < windowEnd && v.endTime > windowStart
                }
            )
            for clip in (try? modelContext.fetch(descriptor)) ?? [] {
                let cam = TeslaCamera.canonical(clip.camera)
                guard byCamera[cam] != nil else { continue }
                byCamera[cam]?.append(clip)
            }
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

        // Decode-verify each camera's FINAL clip up front, concurrently.
        // Those are the corrupt-tail candidates (car powered down mid-write);
        // earlier clips are bounded by the next clip's start time during
        // stitching, so their metadata can't overrun. Concurrent because a
        // probe costs real decode time and four in a row quadruples the
        // player's spin-up.
        var verifiedDurations: [URL: CMTime] = [:]
        await withTaskGroup(of: (URL, CMTime?).self) { group in
            for source in sources {
                guard let last = source.clips.last else { continue }
                let url = last.url
                group.addTask { (url, await Self.verifiedPlayableDuration(url: url)) }
            }
            for await (url, duration) in group {
                if let duration { verifiedDurations[url] = duration }
            }
        }

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
                // Duration from the frames that actually exist, not import
                // metadata — corrupt Sentry tail clips (car powered down
                // mid-write) claim more time than they hold, and the excess
                // played as a black tail on every camera.
                let metaDuration = clips[0].video.endTime.timeIntervalSince(camStart)
                let playable = verifiedDurations[clips[0].url]?.seconds ?? 0
                duration = playable > 0.5 ? playable : metaDuration
                print("MultiCam[\(camKey)]: single clip \(clips[0].url.lastPathComponent) claimed \(metaDuration)s verified \(playable)s")
                newAssets[camKey] = asset
                newMarkers[camKey] = clips[0].video.markers
            } else {
                // Stitch this camera's clips end-to-end at their real offsets,
                // so playback and scrubbing treat them as one recording.
                let composition = AVMutableComposition()
                var cursor = CMTime.zero
                var merged: [DetectionMarker] = []
                // Never stitch past the matched clips' union window — a
                // continuation clip pulled from the library above would
                // otherwise extend this camera past the others and re-create
                // the black-tail problem it was fetched to fix.
                let capTime = CMTime(seconds: windowEnd.timeIntervalSince(camStart),
                                     preferredTimescale: 600)
                for (index, clip) in clips.enumerated() {
                    let (video, url) = clip
                    let offset = video.startTime.timeIntervalSince(camStart)
                    let target = CMTime(seconds: offset, preferredTimescale: 600)
                    guard cursor < capTime, target < capTime else { break }
                    let asset = AVURLAsset(url: url)
                    // Only the final clip carries a decode-verified duration
                    // (see the probe above); a verified .zero means nothing
                    // in it decodes, and the empty range below drops it —
                    // that truncates the timeline instead of scheduling
                    // undecodable time as a black tail.
                    let claimedDuration = CMTime(
                        seconds: video.endTime.timeIntervalSince(video.startTime),
                        preferredTimescale: 600)
                    let assetDuration = verifiedDurations[url] ?? claimedDuration
                    print("MultiCam[\(camKey)]: stitch \(url.lastPathComponent) at +\(offset)s claimed \(claimedDuration.seconds)s verified \(verifiedDurations[url]?.seconds ?? -1)s")
                    if target > cursor {
                        // Recording gap between clips — keep later clips at
                        // their true wall-clock position.
                        composition.insertEmptyTimeRange(CMTimeRange(start: cursor, end: target))
                        cursor = target
                    }
                    // Stop this clip where the next one starts. Corrupt tail
                    // clips overstate even their video track's time range, and
                    // trusting it inserted claimed-but-frameless time that
                    // shadowed the next clip's real footage — the black tail
                    // survived exactly where a continuation clip existed to
                    // fill it.
                    var insertCap = capTime
                    if index + 1 < clips.count {
                        let nextOffset = clips[index + 1].video.startTime
                            .timeIntervalSince(camStart)
                        insertCap = min(insertCap,
                                        CMTime(seconds: nextOffset, preferredTimescale: 600))
                    }
                    // Clips can overlap the seam by a moment; skip the part
                    // the previous clip already covered. Cap the end so this
                    // camera stops at the union window (or the next clip).
                    let sourceStart = CMTime(seconds: max(0, cursor.seconds - offset),
                                             preferredTimescale: 600)
                    let sourceEnd = min(assetDuration, sourceStart + (insertCap - cursor))
                    let range = CMTimeRange(start: sourceStart, end: sourceEnd)
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
                print("MultiCam[\(camKey)]: stitched \(clips.count) clips, final duration \(duration)s (cap \(capTime.seconds)s)")
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

    /// Result of decoding a probe window: where renderable frames actually
    /// end, that nothing in the window decodes, or that the probe itself
    /// couldn't run (treat the metadata as innocent then).
    private enum TailProbe {
        case verified(CMTime)
        case nothingDecodable
        case probeFailed
    }

    /// Wall-clock duration of footage that actually DECODES from the file.
    /// Corrupt Sentry tail clips (car powered down mid-write) carry sample
    /// tables — and even readable bytes — for frames that never render:
    /// container duration, track time range, and pass-through reads all
    /// vouched for the lie (FigFilePlayer -12860 at play time was the only
    /// dissent). Decoding the tail is the same test playback faces, so its
    /// verdict is authoritative: a shorter verified end truncates the clip,
    /// nothing decodable drops it entirely (.zero), and a probe that can't
    /// run falls back to the claimed duration rather than nuking playback.
    static func verifiedPlayableDuration(url: URL) async -> CMTime? {
        // The probes run before setupPlayers' own access loop, so hold the
        // security scope here.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let claimed = try? await track.load(.timeRange),
              claimed.duration.isNumeric, claimed.duration > .zero else {
            return try? await asset.load(.duration)
        }
        // TUNING: tail window the probe decodes. Longer catches truncation
        // points further from the end but costs decode time (~1s per 10s of
        // 1080p footage) on every playback setup.
        let probeWindow = CMTime(seconds: 10, preferredTimescale: 600)
        let probeStart = max(claimed.start, claimed.end - probeWindow)
        switch decodedEnd(asset: asset, track: track, from: probeStart) {
        case .verified(let end):
            return min(end - claimed.start, claimed.duration)
        case .nothingDecodable:
            // Truncated before the tail window — walk from the top for the
            // real end. A file with nothing decodable anywhere contributes
            // no footage at all.
            guard probeStart > claimed.start else { return .zero }
            switch decodedEnd(asset: asset, track: track, from: claimed.start) {
            case .verified(let end): return min(end - claimed.start, claimed.duration)
            case .nothingDecodable: return .zero
            case .probeFailed: return claimed.duration
            }
        case .probeFailed:
            return claimed.duration
        }
    }

    /// End time of the last frame that decodes from `from` onward.
    private static func decodedEnd(asset: AVURLAsset, track: AVAssetTrack,
                                   from: CMTime) -> TailProbe {
        guard let reader = try? AVAssetReader(asset: asset) else { return .probeFailed }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .probeFailed }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: from, end: .positiveInfinity)
        guard reader.startReading() else { return .probeFailed }
        var lastEnd: CMTime?
        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts.isNumeric else { continue }
            let frameDuration = CMSampleBufferGetDuration(buffer)
            let end = frameDuration.isNumeric ? pts + frameDuration : pts
            if lastEnd.map({ end > $0 }) ?? true { lastEnd = end }
        }
        reader.cancelReading()
        guard let lastEnd, lastEnd.isNumeric, lastEnd > from else { return .nothingDecodable }
        return .verified(lastEnd)
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
