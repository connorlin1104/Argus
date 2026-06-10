//
//  TeslaCamera.swift
//  teslaDashcamViewer
//
//  Camera ID normalization and lens metadata for Tesla's four exterior cameras.
//  Supports both the legacy numeric IDs (0/3/4/5) and the modern string names
//  emitted by current firmware (front / left_repeater / right_repeater / back).
//

import Foundation
import CoreGraphics

// MARK: - Camera registry

enum TeslaCamera {

    /// Canonical camera ID used everywhere in the UI.
    /// TEXT: maps raw Tesla strings → the lowercased keys we use internally.
    static func canonical(_ raw: String) -> String {
        switch raw.lowercased() {
        case "0", "front":                      return "front"
        case "3", "left", "left_repeater":      return "left_repeater"
        case "4", "right", "right_repeater":    return "right_repeater"
        case "5", "back", "rear":               return "back"
        default:                                 return raw.lowercased()
        }
    }

    /// Approximate vertical FOV in degrees, used for monocular distance estimates.
    /// TUNING: adjust these if you want distance numbers to lean closer/further.
    static func verticalFOVDegrees(for cameraID: String) -> Double {
        switch canonical(cameraID) {
        case "front": return 50.0
        case "left_repeater", "right_repeater": return 75.0
        case "back": return 75.0
        default: return 60.0
        }
    }

    /// Friendly name. Returns "" if the camera ID is not one we recognize,
    /// so callers can omit the field rather than show a meaningless raw ID.
    /// TEXT: change these strings to relabel cameras everywhere in the UI.
    static func displayName(for cameraID: String) -> String {
        switch canonical(cameraID) {
        case "front":          return "Front"
        case "left_repeater":  return "Left"
        case "right_repeater": return "Right"
        case "back":           return "Rear"
        default:               return ""
        }
    }
}

// MARK: - Distance estimation

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
