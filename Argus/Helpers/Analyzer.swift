//
//  Analyzer.swift
//  Argus
//
//  Observable façade around DetectionEngine. Owns the progress state shown
//  in the toolbar and the batch lifecycle helpers used by VideoListView.
//
//  See also:
//   - DetectionEngine.swift    — the actual per-frame Vision pipeline
//   - Detection.swift          — Detection / DetectionSummary types
//   - EventTag.swift           — classifyEventTag()
//   - TeslaCamera.swift        — FOV table + canonical camera IDs
//

import Foundation
import Observation
import CoreGraphics

// MARK: - Analyzer state

@Observable
@MainActor
class VideoAnalyzer {
    /// Single shared instance so the Videos-tab progress chip reflects scans
    /// no matter who starts them (the toolbar button or the post-import
    /// auto-run in EventsImportRunner).
    static let shared = VideoAnalyzer()

    // === Live progress state (drives the toolbar UI) ===
    var isAnalyzing: Bool = false
    var progress: Double = 0.0
    var currentTaskLabel: String = ""
    var totalVideos: Int = 0
    var completedVideos: Int = 0

    // === TUNING KNOBS ===
    /// Distance (m) at which a human is considered "too close" and gets flagged.
    /// TUNING: lower = more sensitive, fires events from further away.
    var humanProximityThresholdMeters: Double = 3.0

    // MARK: - Public API

    /// Returns the first timestamp (ms) where a human is closer than the proximity threshold.
    func firstProximityEvent(in detections: [Detection]) -> Int? {
        for d in detections where d.kind == .human {
            if let dist = d.estimatedDistanceMeters, dist <= humanProximityThresholdMeters {
                return d.timestampMs
            }
        }
        return nil
    }

    // MARK: - Summarization

    /// Rolls a Detection array up into a single summary + interestingness score.
    nonisolated static func summarize(detections: [Detection]) -> DetectionSummary {
        let humans = detections.filter { $0.kind == .human }
                               .sorted(by: { $0.timestampMs < $1.timestampMs })
        let vehicles = detections.filter { $0.kind == .vehicle }
        let plates = detections.filter { $0.kind == .licensePlate }

        let closestHuman = humans.compactMap { $0.estimatedDistanceMeters }.min()
        let presenceSeconds = computePresenceSeconds(humans: humans)
        let meanMotion = computeMeanMotion(humans: humans)
        let score = computeScore(
            closestHuman: closestHuman,
            presenceSeconds: presenceSeconds,
            humanCount: humans.count,
            meanMotion: meanMotion,
            hasPlates: !plates.isEmpty
        )

        return DetectionSummary(
            humanCount: humans.count,
            vehicleCount: vehicles.count,
            plateCount: plates.count,
            closestHumanMeters: closestHuman,
            humanPresenceSeconds: presenceSeconds,
            meanHumanMotion: meanMotion,
            score: score,
            firstPlateText: plates.first?.licensePlateText
        )
    }

    private nonisolated static func computePresenceSeconds(humans: [Detection]) -> Double {
        if let first = humans.first?.timestampMs, let last = humans.last?.timestampMs, last > first {
            return Double(last - first) / 1000.0
        }
        // single-frame blip → tiny presence so it's not zero
        return humans.isEmpty ? 0 : 0.2
    }

    private nonisolated static func computeMeanMotion(humans: [Detection]) -> Double {
        // Mean per-frame motion: average distance between consecutive human bbox centers (normalized).
        guard humans.count >= 2 else { return 0 }
        var motionSum: Double = 0
        var motionN: Int = 0
        for i in 1..<humans.count {
            let a = humans[i - 1].bbox
            let b = humans[i].bbox
            let dx = Double((a.midX) - (b.midX))
            let dy = Double((a.midY) - (b.midY))
            motionSum += (dx * dx + dy * dy).squareRoot()
            motionN += 1
        }
        return motionN > 0 ? motionSum / Double(motionN) : 0
    }

    // TUNING: tweak weights here to change which signals push score higher.
    private nonisolated static func computeScore(closestHuman: Double?,
                                                 presenceSeconds: Double,
                                                 humanCount: Int,
                                                 meanMotion: Double,
                                                 hasPlates: Bool) -> Double {
        var score: Double = 0
        if let d = closestHuman {
            // closer = higher; 1m ≈ 1.0
            score += max(0, min(1.0, 3.0 / max(d, 0.5))) * 0.45
        }
        score += min(1.0, presenceSeconds / 15.0) * 0.30          // 15s of presence saturates
        score += min(1.0, Double(humanCount) / 60.0) * 0.10       // many detections
        score += min(1.0, meanMotion * 5.0) * 0.10                // active movement bonus
        score += hasPlates ? 0.05 : 0                              // any plate spotted
        return score
    }

    // MARK: - Batch progress

    func beginBatch(total: Int) {
        totalVideos = total
        completedVideos = 0
        progress = 0
        isAnalyzing = true
        currentTaskLabel = "Starting analysis…"
    }

    func tickBatch(label: String) {
        completedVideos += 1
        if totalVideos > 0 {
            progress = Double(completedVideos) / Double(totalVideos)
        }
        currentTaskLabel = label
    }

    func endBatch() {
        isAnalyzing = false
        currentTaskLabel = ""
        progress = 0
        totalVideos = 0
        completedVideos = 0
    }
}
