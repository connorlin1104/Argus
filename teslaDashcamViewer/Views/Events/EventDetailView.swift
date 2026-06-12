//
//  EventDetailView.swift
//  teslaDashcamViewer
//
//  Top-level event detail screen. Composes the multi-cam player, AI summary,
//  metadata card, and notes editor.
//
//  Sub-sections live in their own files alongside this one:
//    - EventNameSection.swift
//    - EventSummarySection.swift
//    - EventMetadataSection.swift
//    - EventMiniMapSection.swift
//    - EventNotesSection.swift
//  Reusable card chrome lives in Views/Style/SectionCard.swift.
//  Search keywords: UI:event-detail, LAYOUT:detail
//

import SwiftUI
import SwiftData

/// LAYOUT: Preference key used to read the right (player) column's natural
/// height so the left info column can match it. Without this, Notes absorbs
/// the entire parent height and overruns the player on tall windows.
private struct RightColumnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct EventDetailView: View {
    @Bindable var event: Event
    @State private var isGenerating: Bool = false
    /// LAYOUT: Owned here so the camera-select buttons in the left info column
    /// can drive the player's focus mode.
    @State private var focusedCamera: String? = nil
    /// LAYOUT: Measured height of the player column. Used to clamp the left
    /// info column so Notes stops growing at the player's bottom.
    @State private var rightColumnHeight: CGFloat = 0

    /// LAYOUT: drives single-column stacking on iPhone-width screens.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    /// Videos whose recording window covers this event's timestamp.
    @Query private var matchedVideos: [VideoRecording]

    /// Geofences for header zone-chip styling.
    @Query(sort: \Geofence.name) private var fences: [Geofence]

    /// Watchlist for plate-match badge in the header.
    @Query private var watchlist: [Watchlist]

    init(event: Event) {
        self.event = event
        let t = event.timestamp
        _matchedVideos = Query(
            filter: #Predicate<VideoRecording> { video in
                video.startTime <= t && video.endTime >= t
            },
            sort: [SortDescriptor(\VideoRecording.camera, order: .forward)]
        )
    }

    // === TUNING KNOBS ===
    /// LAYOUT: Max width of the right-hand player column. Matches the
    /// SyncedMultiCamPlayerView's own playerMaxWidth so the timeline lines up.
    private let playerColumnMaxWidth: CGFloat = 1052
    /// LAYOUT: Minimum width of the left info column on small windows.
    /// Sized so the Details card + the square mini map can sit side-by-side
    /// (≈220pt map + spacing + ≈200pt details).
    private let leftColumnMinWidth: CGFloat = 460
    /// LAYOUT: Fixed edge length of the square mini map next to Details.
    /// Keeping it fixed lets Details flex with the left column's width while
    /// the map stays perfectly square.
    private let miniMapSize: CGFloat = 220
    /// LAYOUT: Horizontal gap between the info column and the player column.
    private let columnSpacing: CGFloat = 16

    private var hasHeader: Bool {
        !event.zone.isEmpty || event.tag != "unknown" || event.interestingnessScore > 0
    }

    /// Canonical IDs of cameras actually present for this event's matched videos.
    private var presentCameras: Set<String> {
        Set(matchedVideos.map { TeslaCamera.canonical($0.camera) })
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isCompact {
                compactBody
            } else {
                regularBody
            }
        }
        .onAppear { logMatches() }
        .navigationTitle(event.timestamp.formatted(date: .abbreviated, time: .shortened))
        #if os(macOS)
        .navigationSubtitle({
            let n = TeslaCamera.displayName(for: event.camera)
            return n.isEmpty ? "" : n
        }())
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
    }

    /// macOS / iPad regular-width layout — info card column hugs the left, player hugs the right.
    @ViewBuilder
    private var regularBody: some View {
        // LAYOUT: two-column page. No outer scroll — info hugs the left, video hugs the right.
        HStack(alignment: .top, spacing: columnSpacing) {
            leftInfoColumn
                .frame(minWidth: leftColumnMinWidth, maxWidth: .infinity, alignment: .topLeading)
                // LAYOUT: clamp to the right column's natural height (+12 to
                // compensate for the -12 top padding below that lifts the name
                // badge to timer level) so Notes can't push past the player.
                .frame(
                    maxHeight: rightColumnHeight > 0 ? rightColumnHeight + 12 : .infinity,
                    alignment: .top
                )
                // LAYOUT: pull the name badge up so its frame aligns with the
                // wall-clock badge on the right (which sits at .padding(.top, -12)).
                .padding(.top, -12)

            rightPlayerColumn
                .frame(maxWidth: playerColumnMaxWidth, alignment: .top)
                .background(
                    // LAYOUT: report the player column's natural height up to
                    // the parent so the left column can match it.
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: RightColumnHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .layoutPriority(1)
        }
        // LAYOUT: outer padding around the whole detail page
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(RightColumnHeightKey.self) { newValue in
            // Guard against tiny oscillations that would trigger relayout loops.
            if abs(newValue - rightColumnHeight) > 0.5 {
                rightColumnHeight = newValue
            }
        }
    }

    /// iPhone / compact-width layout — single scrollable column.
    /// Player on top (with its own transport bar), name + chips + summary +
    /// camera buttons + details + mini map + notes stacked beneath. Notes drops
    /// its height-matching behavior here since the page scrolls naturally.
    @ViewBuilder
    private var compactBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                rightPlayerColumn
                    .frame(maxWidth: .infinity)

                EventNameSection(event: event)
                if hasHeader { headerChips }
                EventSummarySection(event: event, isGenerating: $isGenerating)
                cameraButtonsRows
                // LAYOUT: on compact, Details and the mini map each get full
                // width — the map drops below Details instead of sitting to
                // its right.
                EventMetadataSection(event: event)
                EventMiniMapSection(event: event)
                    .frame(height: 220)
                EventTripSection(event: event)
                EventNotesSection(event: event)
                    .frame(minHeight: 160)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Left info column

    /// Left column: chips, AI summary, camera-select buttons, details, notes.
    /// Replaces the content that used to sit below the player in the old vertical layout.
    /// Notes expands to absorb any leftover vertical space so the column matches the player height.
    @ViewBuilder
    private var leftInfoColumn: some View {
        // LAYOUT: spacing 8 matches the player column's VStack so the gap from
        // the title badge down to the AI Summary card visually equals the gap
        // from the wall-clock badge down to the video grid.
        VStack(alignment: .leading, spacing: 6) {
            // UI: editable event name at top, sized to match the timer
            EventNameSection(event: event)
            if hasHeader { headerChips }
            EventSummarySection(event: event, isGenerating: $isGenerating)
            cameraButtonsRows
            // LAYOUT: Details + square mini map share one row. Details flexes
            // to absorb whatever the column's width allows; the map column is
            // a fixed width so the inner map stays a clean square (the card's
            // height grows naturally to fit the header + square map).
            HStack(alignment: .top, spacing: 8) {
                EventMetadataSection(event: event)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                EventMiniMapSection(event: event)
                    .frame(width: miniMapSize)
            }
            // UI: trip context (sibling events in the same drive).
            EventTripSection(event: event)
            // LAYOUT: Notes is the only flexible section — it absorbs any slack
            // so the other cards keep their natural sizes.
            EventNotesSection(event: event)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Camera-select buttons. Two rows: [Grid, Front, Rear] then [Left, Right].
    /// Grid returns to the 2x2 view; the others switch focus to that camera.
    @ViewBuilder
    private var cameraButtonsRows: some View {
        VStack(spacing: 6) {
            // ROW 1: Grid · Front · Rear
            HStack(spacing: 6) {
                cameraSelectButton(
                    label: "Grid",
                    icon: "rectangle.split.2x2.fill",
                    isActive: focusedCamera == nil,
                    enabled: !matchedVideos.isEmpty
                ) { focusedCamera = nil }

                cameraSelectButton(
                    label: "Front",
                    icon: nil,
                    isActive: focusedCamera == "front",
                    enabled: presentCameras.contains("front")
                ) { focusedCamera = "front" }

                cameraSelectButton(
                    label: "Rear",
                    icon: nil,
                    isActive: focusedCamera == "back",
                    enabled: presentCameras.contains("back")
                ) { focusedCamera = "back" }
            }
            // ROW 2: Left · Right
            HStack(spacing: 6) {
                cameraSelectButton(
                    label: "Left",
                    icon: nil,
                    isActive: focusedCamera == "left_repeater",
                    enabled: presentCameras.contains("left_repeater")
                ) { focusedCamera = "left_repeater" }

                cameraSelectButton(
                    label: "Right",
                    icon: nil,
                    isActive: focusedCamera == "right_repeater",
                    enabled: presentCameras.contains("right_repeater")
                ) { focusedCamera = "right_repeater" }
            }
        }
    }

    /// One camera-select pill. Visual matches the prior in-player sidebar buttons.
    private func cameraSelectButton(
        label: String,
        icon: String?,
        isActive: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { action() }
        } label: {
            Group {
                if let icon {
                    Label(label, systemImage: icon)
                } else {
                    Text(label)
                }
            }
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    // COLOR: active vs. idle background fill
                    .fill(isActive ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    // COLOR: active outline ring
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .foregroundStyle(isActive ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: - Right player column

    /// Right column: wall-clock + video grid/focus tile + transport bar.
    /// The player view aligns to the trailing edge of this column so it hugs the right.
    @ViewBuilder
    private var rightPlayerColumn: some View {
        if !matchedVideos.isEmpty {
            SyncedMultiCamPlayerView(
                videos: matchedVideos,
                focusedCamera: $focusedCamera
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            // TEXT: shown when no clip overlaps this event's timestamp
            ContentUnavailableView(
                "No matching clips",
                systemImage: "play.slash",
                description: Text("No imported videos overlap this event's timestamp (\(event.timestamp.formatted())).")
            )
            .frame(height: 220)
            .liquidGlassCard(cornerRadius: 14)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Compact row of zone/tag/score chips at the top of the info column.
    private var headerChips: some View {
        // UI: header chip row
        HStack(spacing: 6) {
            if !event.zone.isEmpty {
                ZoneChip(
                    zone: event.zone,
                    tint: GeofenceStyle.color(forZone: event.zone, in: fences),
                    symbol: GeofenceStyle.symbol(forZone: event.zone, in: fences)
                )
            }
            if event.tag != "unknown" { TagChip(tag: event.tag) }
            if event.interestingnessScore > 0 { ScoreBadge(score: event.interestingnessScore) }
            if let match = WatchlistMatcher.match(event: event, in: watchlist) {
                EventWatchlistBadge(entry: match)
            }
            Spacer()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // BUTTON: favorite toggle (star)
        ToolbarItem {
            Button {
                event.isFavorite.toggle()
            } label: {
                Image(systemName: event.isFavorite ? "star.fill" : "star")
                    // COLOR: yellow when favorited, secondary otherwise
                    .foregroundStyle(event.isFavorite ? .yellow : .secondary)
            }
        }
        // BUTTON: archive toggle
        ToolbarItem {
            Button {
                event.isArchived.toggle()
            } label: {
                Image(systemName: event.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
        }
    }

    private func logMatches() {
        print("EventDetailView: event.timestamp=\(event.timestamp), matchedVideos.count=\(matchedVideos.count)")
        for v in matchedVideos {
            print("  - cam=\(v.camera) start=\(v.startTime) end=\(v.endTime) path=\(v.url.lastPathComponent)")
        }
    }
}

#Preview {
    //EventDetailView()
}
