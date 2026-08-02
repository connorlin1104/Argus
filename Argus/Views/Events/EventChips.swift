//
//  EventChips.swift
//  Argus
//
//  Small pill-shaped badges used by EventRow, EventDetailView, and the map.
//  Search keywords: UI:chip, COLOR:chip, TEXT:chip
//

import SwiftUI

// MARK: - Zone chip

/// Pill chip showing a matching geofence name (e.g. "Home"). Tint and SF
/// Symbol default to green / no-icon but can be overridden per-zone by the
/// caller after looking up the matching Geofence via GeofenceStyle.
struct ZoneChip: View {
    let zone: String
    /// Per-zone color override (defaults to green when nil).
    var tint: Color? = nil
    /// Per-zone SF Symbol shown before the name (omitted when nil).
    var symbol: String? = nil

    var body: some View {
        let effectiveTint = tint ?? .green
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2)
            }
            Text(zone)
                .font(.caption2.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(effectiveTint)
        .liquidGlassChip(tint: effectiveTint)
    }
}

// MARK: - Tag chip

/// Behavior tag chip — color & label depend on the event's tag string.
/// COLOR: edit the switch below to change tag colors site-wide.
struct TagChip: View {
    let tag: String
    var body: some View {
        // TEXT: label per tag — keep in sync with EventTag.label if both used
        let (label, color): (String, Color) = {
            switch tag {
            case "touched":    return ("Touched", .red)
            case "lingered":   return ("Lingered", .orange)
            case "approached": return ("Approached", .yellow)
            case "passing":    return ("Passing", .blue)
            case "vehicle":    return ("Vehicle", .purple)
            case "noise":      return ("Noise", .gray)
            default:           return (tag.capitalized, .secondary)
            }
        }()
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .liquidGlassChip(tint: color)
    }
}

// MARK: - Score badge

/// Interestingness badge. Shows a plain-language activity level instead of
/// the raw 0–100 number — "62" meant nothing to users.
/// COLOR: red = high, orange = moderate, yellow = low. TUNING below.
struct ScoreBadge: View {
    let score: Double
    var body: some View {
        let pct = max(0, min(1, score))
        // TUNING: threshold breakpoints — keep in sync with label(for:)
        let color: Color = pct > 0.66 ? .red : (pct > 0.33 ? .orange : .yellow)
        Text(ScoreBadge.label(for: score))
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .liquidGlassChip(tint: color)
            .help("Activity level estimated from the clip scan (proximity, time on screen, movement)")
    }

    /// Shared wording so the map popover and any other score readout say the
    /// same thing as the chip.
    static func label(for score: Double) -> String {
        let pct = max(0, min(1, score))
        // TUNING: threshold breakpoints for the activity wording
        if pct > 0.66 { return "High activity" }
        if pct > 0.33 { return "Moderate activity" }
        return "Low activity"
    }
}
