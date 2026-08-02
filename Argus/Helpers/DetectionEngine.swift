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

/// Everything one clip scan produces: the per-frame detections plus
/// human-readable phrases for notable things Vision classified in frames
/// where a person was also on screen ("a backpack", "a box or package").
struct ClipScanResult: Sendable {
    let detections: [Detection]
    let humanContext: [String]
}

enum DetectionEngine {

    /// Longest frame edge the decoder outputs for Vision. HW3 clips
    /// (1280×960) pass through untouched; HW4 front clips (2896×1876) decode
    /// at half size. Human rects use normalized bboxes so distance estimates
    /// are unaffected; plates that only resolve above this size were already
    /// unreadable in the sampled frames.
    private static let maxDecodeDimension: CGFloat = 1920

    /// Walks a video, runs Vision requests every 5th frame, and returns
    /// every detection it finds (humans, vehicles, license plates) plus
    /// the carried-object / companion context seen alongside people.
    static func runDetections(url: URL, vfovDegrees: Double) async -> ClipScanResult {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return ClipScanResult(detections: [], humanContext: [])
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            return ClipScanResult(detections: [], humanContext: [])
        }
        // Decode capped at maxDecodeDimension — full-size 32BGRA frames from
        // HW4 cameras are ~21 MB each and were a big slice of the scan's
        // memory footprint on iPhones.
        var outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if let naturalSize = try? await track.load(.naturalSize) {
            let longSide = max(naturalSize.width, naturalSize.height)
            if longSide > maxDecodeDimension {
                let scale = maxDecodeDimension / longSide
                outputSettings[kCVPixelBufferWidthKey as String] = Int(naturalSize.width * scale)
                outputSettings[kCVPixelBufferHeightKey as String] = Int(naturalSize.height * scale)
            }
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        var detections: [Detection] = []
        var contextCounts: [String: Int] = [:]
        var frameCount = 0
        var sampledCount = 0
        // TUNING: any of these labels reported by Vision counts as a vehicle.
        let vehicleLabels: Set<String> = [
            "car", "truck", "automobile", "vehicle", "van", "suv",
            "pickup", "motorcycle", "bus", "minivan", "sedan", "convertible"
        ]

        // Each iteration runs inside its own autoreleasepool. Sample buffers
        // and Vision's per-frame intermediates are autoreleased, and this
        // loop has no await for the runtime to drain at — without the pool
        // they piled up for the whole clip (gigabytes), which iOS answered
        // by killing the app a few clips into a batch scan.
        while true {
            let finished = autoreleasepool { () -> Bool in
                guard let sample = output.copyNextSampleBuffer() else { return true }
                // TUNING: change "% 5" to scan more or fewer frames.
                if frameCount % 5 == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    let timestampMs = Int(pts * 1000)

                    let frame = analyzeFrame(
                        pixelBuffer: pixelBuffer,
                        timestampMs: timestampMs,
                        vfovDegrees: vfovDegrees,
                        vehicleLabels: vehicleLabels,
                        // TUNING: accurate text recognition dominates scan time,
                        // and a readable plate stays on screen for seconds — OCR
                        // every 3rd sampled frame (~every 15th frame) instead of
                        // all of them. Roughly halves per-clip scan time.
                        includeText: sampledCount % 3 == 0
                    )
                    detections.append(contentsOf: frame.detections)
                    for phrase in frame.contextPhrases {
                        contextCounts[phrase, default: 0] += 1
                    }
                    sampledCount += 1
                }
                frameCount += 1
                return false
            }
            if finished { break }
        }

        // Noise gate: a phrase must show up in at least 2 sampled frames.
        // TUNING: raise the floor or the cap if summaries mention clutter.
        let context = contextCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map(\.key)
        return ClipScanResult(detections: detections, humanContext: Array(context))
    }

    // MARK: - Human context labels

    /// Vision classification tokens worth surfacing when a person is on
    /// screen, mapped to the phrase the AI summary should use. Identifiers
    /// are matched token-wise (split on "_"), so "box" can't match "boxer".
    /// TUNING: extend this map to surface more carried items / companions.
    private static let humanContextPhrases: [String: String] = [
        "backpack": "a backpack",
        "handbag": "a bag", "purse": "a bag", "bag": "a bag",
        "suitcase": "luggage", "luggage": "luggage", "briefcase": "a briefcase",
        "box": "a box or package", "package": "a box or package", "parcel": "a box or package", "carton": "a box or package",
        "phone": "a phone", "smartphone": "a phone", "cellphone": "a phone", "telephone": "a phone",
        "umbrella": "an umbrella",
        "bicycle": "a bicycle", "bike": "a bicycle",
        "skateboard": "a skateboard", "scooter": "a scooter",
        "stroller": "a stroller",
        "dog": "a dog", "cat": "a cat",
        "helmet": "a helmet", "hat": "a hat", "hood": "a hood",
        "flashlight": "a flashlight",
        "ladder": "a ladder", "toolbox": "tools", "tool": "tools",
        "camera": "a camera",
        "guitar": "an instrument case",
    ]

    // MARK: - Single frame

    private static func analyzeFrame(pixelBuffer: CVPixelBuffer,
                                     timestampMs: Int,
                                     vfovDegrees: Double,
                                     vehicleLabels: Set<String>,
                                     includeText: Bool) -> (detections: [Detection], contextPhrases: [String]) {
        let humanRequest = VNDetectHumanRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        let classifyRequest = VNClassifyImageRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
        var requests: [VNRequest] = [humanRequest, classifyRequest]
        if includeText { requests.append(textRequest) }
        try? handler.perform(requests)

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

        var contextPhrases: [String] = []
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

            // Carried items / companions — only meaningful when a person is
            // actually in the frame, so the summary can say "carrying a box"
            // instead of narrating random street objects.
            let humanOnScreen = !(humanRequest.results?.isEmpty ?? true)
            if humanOnScreen {
                for obs in classes where obs.confidence > 0.25 {
                    let tokens = obs.identifier.lowercased()
                        .split(whereSeparator: { $0 == "_" || $0 == " " })
                    for token in tokens {
                        if let phrase = humanContextPhrases[String(token)],
                           !contextPhrases.contains(phrase) {
                            contextPhrases.append(phrase)
                        }
                    }
                }
            }
        }

        return (detections, contextPhrases)
    }

    // MARK: - License plate filter

    /// Heuristic: license-plate-like strings are 4-8 chars, uppercase alphanumeric,
    /// and contain at least one digit and one letter — minus the uppercase
    /// letter+digit text a dashcam constantly reads that is NOT a plate
    /// (route signs, exit numbers, car model badges).
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
        guard hasDigit && hasLetter else { return false }
        return !isRoadSignOrBadge(stripped)
    }

    /// Common non-plate strings that pass the shape check above.
    /// TUNING: extend these prefixes/patterns if a recurring sign or badge
    /// keeps showing up as a phantom plate.
    private static func isRoadSignOrBadge(_ text: String) -> Bool {
        // Route / lane / exit signage: a signage word followed by digits
        // ("US101", "EXIT12", "HOV2", "HWY99", "RT66", "SR520").
        let signPrefixes = ["US", "SR", "RT", "RTE", "HWY", "EXIT", "HOV", "MPH", "SPEED", "LANE", "MILE"]
        for prefix in signPrefixes where text.hasPrefix(prefix) {
            if text.dropFirst(prefix.count).allSatisfy(\.isNumber) { return true }
        }
        // Car model badges: "MODEL3", "MODELY" style.
        if text.hasPrefix("MODEL") { return true }
        // Single letter + digits ("F150", "E350", "X5M" trims to X5, "I8").
        // Badge shape on trucks and German sedans; real US plates virtually
        // never have a 1-letter prefix with nothing after the digits.
        if text.first!.isLetter, text.dropFirst().allSatisfy(\.isNumber) { return true }
        return false
    }
}
