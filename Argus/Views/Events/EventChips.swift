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

/// Numeric 0–100 interestingness score badge.
/// COLOR: red >66, orange >33, yellow otherwise. TUNING below.
struct ScoreBadge: View {
    let score: Double
    var body: some View {
        let pct = max(0, min(1, score))
        // TUNING: threshold breakpoints for the badge color
        let color: Color = pct > 0.66 ? .red : (pct > 0.33 ? .orange : .yellow)
        Text(String(format: "%.0f", pct * 100))
            // FONT: monospaced digits so widths stay stable
            .font(.caption2.monospacedDigit().bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .liquidGlassChip(tint: color)
    }
}
