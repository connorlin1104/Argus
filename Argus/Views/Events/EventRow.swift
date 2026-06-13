//
//  EventRow.swift
//  Argus
//
//  A single row in the events list — camera icon, timestamp, trigger,
//  subtitle, chips. Rename happens inside the detail view; the list row is
//  display-only so accidental taps don't drop the user into edit mode.
//  Search keywords: UI:event-row, LAYOUT:row, ICON:camera, TEXT:row
//

import SwiftUI
import SwiftData

struct EventRow: View {
    @Bindable var event: Event

    /// Geofences are needed to look up the row's zone color/symbol.
    @Query(sort: \Geofence.name) private var fences: [Geofence]
    /// Watchlist for plate-match badges.
    @Query private var watchlist: [Watchlist]

    // === Hover state ===
    /// UI: true while the cursor is over this row — drives the background tint.
    @State private var isHovered: Bool = false

    var body: some View {
        // UI: top-level row layout
        HStack(alignment: .center, spacing: 12) {
            cameraIcon

            VStack(alignment: .leading, spacing: 4) {
                metaLine
                triggerLine
                subtitleLine
                chipsLine
            }

            Spacer(minLength: 8)

            // UI: right-aligned interestingness score
            if event.interestingnessScore > 0 {
                ScoreBadge(score: event.interestingnessScore)
            }
        }
        // LAYOUT: horizontal padding so the hover pill has breathing room.
        .padding(.horizontal, 8)
        // LAYOUT: vertical breathing room per row
        .padding(.vertical, 4)
        // UI: hover highlight — subtle accent tint behind the whole row.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    // MARK: - Lines

    /// First line: star (if favorited) + date.
    private var metaLine: some View {
        HStack(spacing: 6) {
            if event.isFavorite {
                // ICON: favorite star (only when isFavorite is true)
                Image(systemName: "star.fill")
                    // COLOR: favorite yellow
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
            // TEXT: date subhead
            Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Second line: bold trigger label. Rename lives in the detail view —
    /// the row is display-only so a tap navigates into the event rather than
    /// dropping into edit mode.
    @ViewBuilder
    private var triggerLine: some View {
        if !displayTrigger.isEmpty {
            // TEXT: bold trigger fills the row's main line
            Text(displayTrigger)
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    /// Third line: camera name + city.
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

    /// Fourth line: zone + tag chips (when present) + optional watchlist badge.
    private var chipsLine: some View {
        HStack(spacing: 6) {
            if !event.zone.isEmpty {
                ZoneChip(
                    zone: event.zone,
                    tint: GeofenceStyle.color(forZone: event.zone, in: fences),
                    symbol: GeofenceStyle.symbol(forZone: event.zone, in: fences)
                )
            }
            if event.tag != "unknown" { TagChip(tag: event.tag) }
            if let match = WatchlistMatcher.match(event: event, in: watchlist) {
                EventWatchlistBadge(entry: match)
            }
        }
    }

    /// What to render on the trigger line: customName if set, else humanized reason.
    private var displayTrigger: String {
        if !event.customName.isEmpty { return event.customName }
        if !event.reason.isEmpty { return EventSummarizer.humanizeReason(event.reason) }
        return ""
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
