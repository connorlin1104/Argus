//
//  EventStillPicker.swift
//  Argus
//
//  Picks which video frames an Evidence Package PDF should include, using
//  only the DetectionMarkers persisted on each clip — no re-scan. Pure
//  logic (no AVFoundation) so it's unit-testable; EvidencePackageRenderer
//  does the actual frame extraction at the chosen timestamps.
//

import Foundation

enum EventStillPicker {

    /// One clip's persisted markers, tagged with its position in the
    /// caller's video array so stills can be traced back to their clip.
    struct ClipMarkers {
        let clipIndex: Int
        let markers: [DetectionMarker]
    }

    /// A chosen still: which clip, where in it, and why it was picked
    /// ("human" | "plate" | "fallback") — the reason drives nothing today
    /// but makes the choice auditable in tests and debugging.
    struct Still: Equatable {
        let clipIndex: Int
        let timestampMs: Int
        let reason: String
    }

    // TUNING: human markers further apart than this (ms) split into separate
    // sighting runs — mirrors the 3000ms presence gap in VideoAnalyzer but
    // tighter, since a still wants one continuous moment.
    private static let runGapMs = 1500
    // TUNING: two stills from the same clip closer than this (ms) are
    // duplicates — the frame barely changes in under 2 seconds.
    private static let dedupeWindowMs = 2000

    /// Up to `cap` stills across the event's clips: the midpoint of the
    /// longest human-marker run first (most people on screen = the moment
    /// worth printing), then plate-read moments in chronological order.
    /// No markers anywhere → a single 1-second fallback frame from the
    /// first clip, so a report never ships with an empty stills section
    /// while footage exists. Empty input → empty output.
    static func pick(clips: [ClipMarkers], cap: Int = 4) -> [Still] {
        guard !clips.isEmpty, cap > 0 else { return [] }

        var chosen: [Still] = []
        func isDuplicate(_ candidate: Still) -> Bool {
            chosen.contains {
                $0.clipIndex == candidate.clipIndex &&
                abs($0.timestampMs - candidate.timestampMs) < dedupeWindowMs
            }
        }

        // 1. Midpoint of the best human run across all clips (ranked by
        //    marker count, then duration). The midpoint marker is guaranteed
        //    to be a frame where a human was actually detected.
        if let best = bestHumanRun(in: clips) {
            let mid = best.markers[best.markers.count / 2]
            chosen.append(Still(clipIndex: best.clipIndex,
                                timestampMs: mid.timestampMs,
                                reason: "human"))
        }

        // 2. Plate-read moments, chronological, until the cap.
        let plateStills = clips
            .flatMap { clip in
                clip.markers
                    .filter { $0.kind == DetectionKind.licensePlate.rawValue }
                    .map { Still(clipIndex: clip.clipIndex,
                                 timestampMs: $0.timestampMs,
                                 reason: "plate") }
            }
            .sorted { $0.timestampMs < $1.timestampMs }
        for still in plateStills where chosen.count < cap {
            if !isDuplicate(still) { chosen.append(still) }
        }

        // 3. Nothing detected anywhere → one early frame from the first clip.
        if chosen.isEmpty {
            chosen.append(Still(clipIndex: clips[0].clipIndex,
                                timestampMs: 1000,
                                reason: "fallback"))
        }
        return chosen
    }

    /// The clip + human-marker run with the most markers (duration breaks
    /// ties). Runs split where consecutive human markers sit further apart
    /// than `runGapMs`.
    private static func bestHumanRun(in clips: [ClipMarkers]) -> (clipIndex: Int, markers: [DetectionMarker])? {
        var best: (clipIndex: Int, markers: [DetectionMarker])?
        func durationMs(_ run: [DetectionMarker]) -> Int {
            (run.last?.timestampMs ?? 0) - (run.first?.timestampMs ?? 0)
        }
        for clip in clips {
            let humans = clip.markers
                .filter { $0.kind == DetectionKind.human.rawValue }
                .sorted { $0.timestampMs < $1.timestampMs }
            var run: [DetectionMarker] = []
            func closeRun() {
                guard !run.isEmpty else { return }
                if let current = best {
                    if run.count > current.markers.count ||
                       (run.count == current.markers.count &&
                        durationMs(run) > durationMs(current.markers)) {
                        best = (clip.clipIndex, run)
                    }
                } else {
                    best = (clip.clipIndex, run)
                }
                run = []
            }
            for marker in humans {
                if let previous = run.last,
                   marker.timestampMs - previous.timestampMs > runGapMs {
                    closeRun()
                }
                run.append(marker)
            }
            closeRun()
        }
        return best
    }

    /// Caption printed under a still: camera + the frame's wall-clock time
    /// with seconds (seconds matter for evidence). "Front camera — Nov 11,
    /// 2026 at 3:42:17 PM"; unknown camera IDs fall back to plain "Camera".
    static func caption(cameraID: String, clipStart: Date, offsetMs: Int) -> String {
        let name = TeslaCamera.displayName(for: cameraID)
        let label = name.isEmpty ? "Camera" : "\(name) camera"
        let wallClock = clipStart.addingTimeInterval(Double(offsetMs) / 1000.0)
        return "\(label) — \(wallClock.formatted(date: .abbreviated, time: .standard))"
    }
}
