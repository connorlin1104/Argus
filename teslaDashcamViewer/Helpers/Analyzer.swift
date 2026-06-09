//
//  Anaylzer.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import AVFoundation
import Vision
import Observation
import CoreGraphics
import Foundation
#if os(macOS)
    import Cocoa
#endif


enum DetectionKind: String, Sendable {
    case human
    case vehicle
    case licensePlate
}

struct Detection: Identifiable, Sendable {
    let id = UUID()
    let kind: DetectionKind
    let timestampMs: Int
    let bbox: CGRect           // normalized [0,1], origin lower-left (Vision convention)
    let confidence: Float
    let estimatedDistanceMeters: Double?
    let licensePlateText: String?
}

struct DetectionSummary: Sendable {
    let humanCount: Int
    let vehicleCount: Int
    let plateCount: Int
    let closestHumanMeters: Double?
    let humanPresenceSeconds: Double
    let meanHumanMotion: Double
    let score: Double
    let firstPlateText: String?
}

enum EventTag: String, CaseIterable, Sendable {
    case touched, lingered, approached, passing, vehicle, noise, unknown

    var label: String {
        switch self {
        case .touched: return "Touched"
        case .lingered: return "Lingered"
        case .approached: return "Approached"
        case .passing: return "Passing by"
        case .vehicle: return "Vehicle activity"
        case .noise: return "Noise"
        case .unknown: return "Unknown"
        }
    }
}

/// Classify a summary into a coarse behavioral tag.
func classifyEventTag(_ s: DetectionSummary) -> EventTag {
    if let dist = s.closestHumanMeters, dist < 1.5, s.humanPresenceSeconds > 3 {
        return .touched
    }
    if s.humanPresenceSeconds >= 10 {
        return .lingered
    }
    if let dist = s.closestHumanMeters, dist < 3.0, s.meanHumanMotion > 0.05 {
        return .approached
    }
    if s.humanCount > 0 && s.humanPresenceSeconds > 0 && s.humanPresenceSeconds < 3 {
        return .passing
    }
    if s.humanCount == 0 && s.vehicleCount > 0 {
        return .vehicle
    }
    if s.humanCount == 0 && s.vehicleCount == 0 && s.plateCount == 0 {
        return .noise
    }
    return .unknown
}

/// Tesla dashcam camera IDs. Supports both the legacy numeric IDs (0/3/4/5)
/// and the modern string names emitted by current firmware
/// (front / left_repeater / right_repeater / back).
enum TeslaCamera {
    /// Canonical camera ID used everywhere in the UI.
    static func canonical(_ raw: String) -> String {
        switch raw.lowercased() {
        case "0", "front":                      return "front"
        case "3", "left", "left_repeater":      return "left_repeater"
        case "4", "right", "right_repeater":    return "right_repeater"
        case "5", "back", "rear":               return "back"
        default:                                 return raw.lowercased()
        }
    }

    static func verticalFOVDegrees(for cameraID: String) -> Double {
        switch canonical(cameraID) {
        case "front": return 50.0
        case "left_repeater", "right_repeater": return 75.0
        case "back": return 75.0
        default: return 60.0
        }
    }

    static func displayName(for cameraID: String) -> String {
        switch canonical(cameraID) {
        case "front": return "Front"
        case "left_repeater": return "Left"
        case "right_repeater": return "Right"
        case "back": return "Rear"
        default: return cameraID
        }
    }
}

/// Pinhole-model distance estimate using a known real-world object height.
/// - bboxHeightNormalized: object's bbox height in [0,1] of the frame
/// - vfovDegrees: camera vertical field of view
/// - realHeightMeters: assumed real-world height (e.g. 1.7 m for an adult)
func estimateDistanceMeters(bboxHeightNormalized: CGFloat,
                            vfovDegrees: Double,
                            realHeightMeters: Double) -> Double? {
    guard bboxHeightNormalized > 0 else { return nil }
    let vfovRad = vfovDegrees * .pi / 180.0
    let denom = 2.0 * tan(vfovRad / 2.0) * Double(bboxHeightNormalized)
    guard denom > 0 else { return nil }
    return realHeightMeters / denom
}


@Observable
@MainActor
class VideoAnalyzer {
    var isAnalyzing: Bool = false
    var progress: Double = 0.0
    var currentTaskLabel: String = ""
    var totalVideos: Int = 0
    var completedVideos: Int = 0

    /// Distance (m) at which a human is considered "too close" and gets flagged.
    var humanProximityThresholdMeters: Double = 3.0

    /// Analyze a video and return all detections (humans, vehicles, license plates).
    func analyzeVideo(url: URL, cameraID: String) async -> [Detection] {
        let vfov = TeslaCamera.verticalFOVDegrees(for: cameraID)
        let result: [Detection] = await Task.detached(priority: .userInitiated) { [url] in
            return await Self.runDetections(url: url, vfovDegrees: vfov)
        }.value
        return result
    }

    /// Returns the first timestamp (ms) where a human is closer than the proximity threshold.
    func firstProximityEvent(in detections: [Detection]) -> Int? {
        for d in detections where d.kind == .human {
            if let dist = d.estimatedDistanceMeters, dist <= humanProximityThresholdMeters {
                return d.timestampMs
            }
        }
        return nil
    }

    /// Rolls a Detection array up into a single summary + interestingness score.
    nonisolated static func summarize(detections: [Detection]) -> DetectionSummary {
        let humans = detections.filter { $0.kind == .human }.sorted(by: { $0.timestampMs < $1.timestampMs })
        let vehicles = detections.filter { $0.kind == .vehicle }
        let plates = detections.filter { $0.kind == .licensePlate }

        let closestHuman = humans.compactMap { $0.estimatedDistanceMeters }.min()

        let presenceSeconds: Double
        if let first = humans.first?.timestampMs, let last = humans.last?.timestampMs, last > first {
            presenceSeconds = Double(last - first) / 1000.0
        } else if !humans.isEmpty {
            presenceSeconds = 0.2  // single-frame blip
        } else {
            presenceSeconds = 0
        }

        // Mean per-frame motion: average distance between consecutive human bbox centers (normalized).
        var motionSum: Double = 0
        var motionN: Int = 0
        if humans.count >= 2 {
            for i in 1..<humans.count {
                let a = humans[i - 1].bbox
                let b = humans[i].bbox
                let dx = Double((a.midX) - (b.midX))
                let dy = Double((a.midY) - (b.midY))
                motionSum += (dx * dx + dy * dy).squareRoot()
                motionN += 1
            }
        }
        let meanMotion = motionN > 0 ? motionSum / Double(motionN) : 0

        // Score: weighted sum, soft-clamped.
        var score: Double = 0
        if let d = closestHuman {
            score += max(0, min(1.0, 3.0 / max(d, 0.5))) * 0.45  // closer = higher; 1m ≈ 1.0
        }
        score += min(1.0, presenceSeconds / 15.0) * 0.30          // 15s of presence saturates
        score += min(1.0, Double(humans.count) / 60.0) * 0.10     // many detections
        score += min(1.0, meanMotion * 5.0) * 0.10                // active movement bonus
        score += plates.isEmpty ? 0 : 0.05                         // any plate spotted

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

    nonisolated static func runDetections(url: URL, vfovDegrees: Double) async -> [Detection] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return [] }
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()

        var detections: [Detection] = []
        var frameCount = 0
        let vehicleLabels: Set<String> = [
            "car", "truck", "automobile", "vehicle", "van", "suv",
            "pickup", "motorcycle", "bus", "minivan", "sedan", "convertible"
        ]

        while let sample = output.copyNextSampleBuffer() {
            if frameCount % 5 == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                let timestampMs = Int(pts * 1000)

                let humanRequest = VNDetectHumanRectanglesRequest()
                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = .accurate
                textRequest.usesLanguageCorrection = false
                let classifyRequest = VNClassifyImageRequest()

                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
                try? handler.perform([humanRequest, textRequest, classifyRequest])

                if let humans = humanRequest.results {
                    for obs in humans {
                        let bbox = obs.boundingBox
                        let distance = estimateDistanceMeters(
                            bboxHeightNormalized: bbox.height,
                            vfovDegrees: vfovDegrees,
                            realHeightMeters: 1.7
                        )
                        detections.append(Detection(
                            kind: .human,
                            timestampMs: timestampMs,
                            bbox: bbox,
                            confidence: obs.confidence,
                            estimatedDistanceMeters: distance,
                            licensePlateText: nil
                        ))
                    }
                }

                if let texts = textRequest.results {
                    for obs in texts {
                        guard let candidate = obs.topCandidates(1).first else { continue }
                        let raw = candidate.string
                        guard isLicensePlateLike(raw) else { continue }
                        detections.append(Detection(
                            kind: .licensePlate,
                            timestampMs: timestampMs,
                            bbox: obs.boundingBox,
                            confidence: candidate.confidence,
                            estimatedDistanceMeters: nil,
                            licensePlateText: raw
                        ))
                    }
                }

                if let classes = classifyRequest.results {
                    let topVehicle = classes
                        .filter { vehicleLabels.contains($0.identifier.lowercased()) && $0.confidence > 0.3 }
                        .max(by: { $0.confidence < $1.confidence })
                    if let v = topVehicle {
                        detections.append(Detection(
                            kind: .vehicle,
                            timestampMs: timestampMs,
                            bbox: CGRect(x: 0, y: 0, width: 1, height: 1),
                            confidence: v.confidence,
                            estimatedDistanceMeters: nil,
                            licensePlateText: nil
                        ))
                    }
                }
            }
            frameCount += 1
        }
        return detections
    }

    /// Heuristic: license-plate-like strings are 4-8 chars, uppercase alphanumeric, and contain at least one digit.
    nonisolated static func isLicensePlateLike(_ raw: String) -> Bool {
        let stripped = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard (4...8).contains(stripped.count) else { return false }
        let upper = stripped.uppercased()
        guard upper == stripped else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard stripped.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let hasDigit = stripped.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) })
        let hasLetter = stripped.unicodeScalars.contains(where: { CharacterSet.uppercaseLetters.contains($0) })
        return hasDigit && hasLetter
    }

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
