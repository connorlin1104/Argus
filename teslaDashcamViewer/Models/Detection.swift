//
//  Detection.swift
//  teslaDashcamViewer
//
//  Data types produced by the Vision-based video analyzer.
//  These are intentionally simple value types so they can be passed across
//  actors safely (Sendable) and serialized for storage as needed.
//

import Foundation
import CoreGraphics

// MARK: - Detection kind

/// What kind of thing Vision spotted in a single frame.
enum DetectionKind: String, Sendable {
    case human
    case vehicle
    case licensePlate
}

// MARK: - Single detection

/// One detection in one frame of a dashcam video.
struct Detection: Identifiable, Sendable {
    let id = UUID()
    let kind: DetectionKind
    /// Position in the video, in milliseconds from the clip's start.
    let timestampMs: Int
    /// Normalized [0,1] bounding box, origin lower-left (Vision convention).
    let bbox: CGRect
    let confidence: Float
    /// Distance from the camera, when we can guess it from bbox height.
    let estimatedDistanceMeters: Double?
    /// Text Vision read off the plate, when applicable.
    let licensePlateText: String?
}

// MARK: - Aggregated summary

/// Rolled-up stats for one video, used by the event tagger and the
/// natural-language summarizer.
struct DetectionSummary: Sendable {
    let humanCount: Int
    let vehicleCount: Int
    let plateCount: Int
    /// Closest a human came to the camera (m). Nil if no humans.
    let closestHumanMeters: Double?
    /// Wall-clock seconds humans were continuously on-screen.
    let humanPresenceSeconds: Double
    /// Average per-frame movement of the human bbox center, normalized.
    let meanHumanMotion: Double
    /// Composite interestingness score 0..1 (soft-clamped).
    let score: Double
    /// First plate text Vision was confident about, for surfacing in UI.
    let firstPlateText: String?
}
