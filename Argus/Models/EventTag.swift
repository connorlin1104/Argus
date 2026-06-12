//
//  EventTag.swift
//  Argus
//
//  Coarse behavioral tag derived from a DetectionSummary. Used to color
//  badges in the list, color markers on the map, and label events.
//

import Foundation

// MARK: - Tag enum

/// Behavior categories the analyzer assigns to an event.
/// TEXT: shown to the user as a chip on rows and in the detail view.
enum EventTag: String, CaseIterable, Sendable {
    case touched, lingered, approached, passing, vehicle, noise, unknown

    /// Human-readable label, used by chips.
    /// TEXT: change wording here to update what shows on the tag chip.
    var label: String {
        switch self {
        case .touched:    return "Touched"
        case .lingered:   return "Lingered"
        case .approached: return "Approached"
        case .passing:    return "Passing by"
        case .vehicle:    return "Vehicle activity"
        case .noise:      return "Noise"
        case .unknown:    return "Unknown"
        }
    }
}

// MARK: - Classification rules

/// Classify a summary into a coarse behavioral tag.
/// TUNING: tweak the thresholds below to change how events get tagged.
func classifyEventTag(_ s: DetectionSummary) -> EventTag {
    // TUNING: "touched" — under 1.5m and present for at least 3s.
    if let dist = s.closestHumanMeters, dist < 1.5, s.humanPresenceSeconds > 3 {
        return .touched
    }
    // TUNING: "lingered" — 10+ seconds of continuous human presence.
    if s.humanPresenceSeconds >= 10 {
        return .lingered
    }
    // TUNING: "approached" — within 3m and moving.
    if let dist = s.closestHumanMeters, dist < 3.0, s.meanHumanMotion > 0.05 {
        return .approached
    }
    // TUNING: "passing" — quick walk-by (< 3s presence).
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
