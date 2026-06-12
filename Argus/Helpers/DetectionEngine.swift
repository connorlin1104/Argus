//
//  DetectionEngine.swift
//  Argus
//
//  The actual per-frame Vision pipeline. Lives outside the Observable
//  VideoAnalyzer so the heavy work runs `nonisolated` off the main actor.
//

import Foundation
import AVFoundation
import Vision
import CoreGraphics

// MARK: - Frame walker

enum DetectionEngine {

    /// Walks a video, runs Vision requests every 5th frame, and returns
    /// every detection it finds (humans, vehicles, license plates).
    static func runDetections(url: URL, vfovDegrees: Double) async -> [Detection] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return [] }
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        reader.startReading()

        var detections: [Detection] = []
        var frameCount = 0
        // TUNING: any of these labels reported by Vision counts as a vehicle.
        let vehicleLabels: Set<String> = [
            "car", "truck", "automobile", "vehicle", "van", "suv",
            "pickup", "motorcycle", "bus", "minivan", "sedan", "convertible"
        ]

        while let sample = output.copyNextSampleBuffer() {
            // TUNING: change "% 5" to scan more or fewer frames.
            if frameCount % 5 == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                let timestampMs = Int(pts * 1000)

                let frameDetections = analyzeFrame(
                    pixelBuffer: pixelBuffer,
                    timestampMs: timestampMs,
                    vfovDegrees: vfovDegrees,
                    vehicleLabels: vehicleLabels
                )
                detections.append(contentsOf: frameDetections)
            }
            frameCount += 1
        }
        return detections
    }

    // MARK: - Single frame

    private static func analyzeFrame(pixelBuffer: CVPixelBuffer,
                                     timestampMs: Int,
                                     vfovDegrees: Double,
                                     vehicleLabels: Set<String>) -> [Detection] {
        let humanRequest = VNDetectHumanRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        let classifyRequest = VNClassifyImageRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
        try? handler.perform([humanRequest, textRequest, classifyRequest])

        var detections: [Detection] = []

        if let humans = humanRequest.results {
            for obs in humans {
                let bbox = obs.boundingBox
                let distance = estimateDistanceMeters(
                    bboxHeightNormalized: bbox.height,
                    vfovDegrees: vfovDegrees,
                    // TUNING: 1.7 m adult average — change to bias distance estimates.
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
                // TUNING: 0.3 confidence floor for "this frame contains a vehicle".
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

        return detections
    }

    // MARK: - License plate filter

    /// Heuristic: license-plate-like strings are 4-8 chars, uppercase alphanumeric,
    /// and contain at least one digit and one letter.
    static func isLicensePlateLike(_ raw: String) -> Bool {
        let stripped = raw.replacingOccurrences(of: " ", with: "")
                          .replacingOccurrences(of: "-", with: "")
        guard (4...8).contains(stripped.count) else { return false }
        let upper = stripped.uppercased()
        guard upper == stripped else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard stripped.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let hasDigit = stripped.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) })
        let hasLetter = stripped.unicodeScalars.contains(where: { CharacterSet.uppercaseLetters.contains($0) })
        return hasDigit && hasLetter
    }
}
