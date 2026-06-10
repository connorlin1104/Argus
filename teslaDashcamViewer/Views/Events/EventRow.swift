//
//  EventRow.swift
//  teslaDashcamViewer
//
//  A single row in the events list — camera icon, timestamp, reason, chips.
//  Search keywords: UI:event-row, LAYOUT:row, ICON:camera, TEXT:row
//

import SwiftUI

struct EventRow: View {
    let event: Event

    var body: some View {
        // UI: top-level row layout
        HStack(alignment: .center, spacing: 12) {
            cameraIcon

            VStack(alignment: .leading, spacing: 4) {
                titleLine
                subtitleLine
                chipsLine
            }

            Spacer(minLength: 8)

            // UI: right-aligned interestingness score
            if event.interestingnessScore > 0 {
                ScoreBadge(score: event.interestingnessScore)
            }
        }
        // LAYOUT: vertical breathing room per row
        .padding(.vertical, 4)
    }

    // MARK: - Lines

    /// First line: star (if favorited) + date + dot + reason.
    private var titleLine: some View {
        HStack(spacing: 6) {
            if event.isFavorite {
                // ICON: favorite star (only when isFavorite is true)
                Image(systemName: "star.fill")
                    // COLOR: favorite yellow
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
            // TEXT: date headline
            Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            if !event.reason.isEmpty {
                // TEXT: humanized trigger reason
                Text("· \(EventSummarizer.humanizeReason(event.reason))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Second line: camera name + city.
    private var subtitleLine: some View {
        HStack(spacing: 6) {
            let cameraName = TeslaCamera.displayName(for: event.camera)
            if !cameraName.isEmpty {
                Text(cameraName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !event.city.isEmpty {
                Text(cameraName.isEmpty ? event.city : "· \(event.city)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Third line: zone + tag chips (when present).
    private var chipsLine: some View {
        HStack(spacing: 6) {
            if !event.zone.isEmpty { ZoneChip(zone: event.zone) }
            if event.tag != "unknown" { TagChip(tag: event.tag) }
        }
    }

    // MARK: - Camera icon

    /// ICON: SF Symbol used for the camera's arrow circle.
    private var cameraSymbol: String {
        switch TeslaCamera.canonical(event.camera) {
        case "front":          return "arrow.up.circle"
        case "left_repeater":  return "arrow.left.circle"
        case "right_repeater": return "arrow.right.circle"
        case "back":           return "arrow.down.circle"
        default:               return "camera"
        }
    }

    private var cameraIcon: some View {
        Image(systemName: cameraSymbol)
            // FONT/COLOR/LAYOUT: camera icon styling
            .font(.title2)
            .foregroundStyle(.tint)
            .frame(width: 28, height: 28)
    }
}
