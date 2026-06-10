//
//  EventChips.swift
//  teslaDashcamViewer
//
//  Small pill-shaped badges used by EventRow, EventDetailView, and the map.
//  Search keywords: UI:chip, COLOR:chip, TEXT:chip
//

import SwiftUI

// MARK: - Zone chip

/// Green chip showing a matching geofence name (e.g. "Home").
/// COLOR: green by design — change tint here if you want a different zone color.
struct ZoneChip: View {
    let zone: String
    var body: some View {
        Text(zone)
            // FONT: tiny bold caption
            .font(.caption2.bold())
            // LAYOUT: pill padding
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // COLOR: green text + green glass tint
            .foregroundStyle(.green)
            .liquidGlassChip(tint: .green)
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
