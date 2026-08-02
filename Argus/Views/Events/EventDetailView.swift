//
//  EventDetailView.swift
//  Argus
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

/// LAYOUT: Preference key used to read the Details card's natural height so
/// the mini map beside it can stretch to exactly the same height instead of
/// leaving a gap beneath a fixed square.
private struct DetailsHeightKey: PreferenceKey {
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
    /// LAYOUT: Measured height of the Details card so the mini map beside it
    /// can match it exactly.
    @State private var detailsHeight: CGFloat = 0

    /// LAYOUT: drives single-column stacking on iPhone-width screens.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    /// LAYOUT: iPhone in landscape collapses to verticalSizeClass == .compact.
    /// Used to hide the tab bar so the player fills the screen.
    private var isLandscape: Bool { verticalSizeClass == .compact }
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
    /// SyncedMultiCamPlayerView's own focusTileMaxWidth so the timeline lines up.
    private let playerColumnMaxWidth: CGFloat = 1602
    /// LAYOUT: Minimum width of the left info column on small windows.
    /// Sized so the Details card + the mini map can sit side-by-side
    /// (≈220pt map + spacing + ≈180pt details). Kept as small as readable so
    /// the player column gets every pixel it can use.
    private let leftColumnMinWidth: CGFloat = 420
    /// LAYOUT: Fixed width of the mini map next to Details. Its height
    /// stretches to match the Details card (see DetailsHeightKey).
    private let miniMapSize: CGFloat = 220
    /// LAYOUT: Horizontal gap between the info column and the player column.
    private let columnSpacing: CGFloat = 16
    /// LAYOUT: Vertical space the player chrome (wall-clock badge + transport
    /// bar + inter-row spacing) occupies around the video. Used to size the
    /// video to the window height without pushing the transport bar off-screen.
    private let playerChromeReserve: CGFloat = 104

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
        .navigationTitle(navigationTitleText)
        #if os(macOS)
        .navigationSubtitle({
            let n = TeslaCamera.displayName(for: event.camera)
            return n.isEmpty ? "" : n
        }())
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // LAYOUT: iPhone landscape gives us a true full-screen player surface,
        // so the tab bar at the bottom only steals pixels. Hide it while we're
        // in landscape; SwiftUI restores it on rotation back / pop.
        .toolbar(isLandscape ? .hidden : .automatic, for: .tabBar)
        // LAYOUT: landscape also hides the navigation bar (and with it the
        // event-name title + star/archive items) so the player can claim the
        // top ~32pt of the screen. Users can swipe from the leading edge to
        // go back, or rotate to portrait to reach the toolbar actions.
        .toolbar(isLandscape ? .hidden : .automatic, for: .navigationBar)
        #endif
        .toolbar { toolbarContent }
    }

    /// TEXT: title shown in the navigation bar.
    /// iOS swaps the timestamp for the event name so users see what they tapped
    /// into; the in-page EventNameSection card was visually too heavy on iPhone.
    /// macOS keeps the timestamp because the window's title bar already shows
    /// the navigationSubtitle (camera name) — together they read like metadata.
    private var navigationTitleText: String {
        #if os(iOS)
        if !event.customName.isEmpty { return event.customName }
        if !event.reason.isEmpty { return EventSummarizer.humanizeReason(event.reason) }
        return "Untitled event"
        #else
        return event.timestamp.formatted(date: .abbreviated, time: .shortened)
        #endif
    }

    /// macOS / iPad regular-width layout — info card column hugs the left, player hugs the right.
    @ViewBuilder
    private var regularBody: some View {
        // LAYOUT: two-column page. No outer scroll — info hugs the left, video hugs the right.
        // The GeometryReader sizes the player column to fit BOTH the available
        // width and height, so the video scales as large as the window allows
        // instead of leaving a dead band below the transport bar.
        GeometryReader { geo in
            // Width left for the player after outer padding + left column + gap.
            let availableWidth = geo.size.width - 40 - leftColumnMinWidth - columnSpacing
            // Vertical budget for the video surface: window height minus outer
            // padding and the player chrome above/below the tiles.
            let availableHeight = geo.size.height - 40 - playerChromeReserve
            // 4:3 (HW3) is the tallest Tesla footage; sizing to it guarantees
            // the grid never pushes the transport bar off-screen — 3:2 (HW4)
            // clips just come out a touch shorter.
            let heightFittedWidth = availableHeight * (4.0 / 3.0)
            let playerWidth = max(360, min(playerColumnMaxWidth, availableWidth, heightFittedWidth))

            HStack(alignment: .top, spacing: columnSpacing) {
                // LAYOUT: the info column scrolls within the player-height
                // clamp — long AI summaries or notes used to push the cards
                // below them clean off the (scroll-less) page.
                ScrollView(.vertical) {
                    leftInfoColumn
                }
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
                    .frame(width: playerWidth, alignment: .top)
                    .background(
                        // LAYOUT: report the player column's natural height up to
                        // the parent so the left column can match it.
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: RightColumnHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            // LAYOUT: outer padding around the whole detail page
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onPreferenceChange(RightColumnHeightKey.self) { newValue in
            // Guard against tiny oscillations that would trigger relayout loops.
            if abs(newValue - rightColumnHeight) > 0.5 {
                rightColumnHeight = newValue
            }
        }
    }

    /// iPhone compact layout. Portrait scrolls through the whole page;
    /// landscape collapses to the player only so the 4:3 clip can fit by
    /// height instead of being sized by the full landscape width (which
    /// pushes it taller than the screen).
    @ViewBuilder
    private var compactBody: some View {
        #if os(iOS)
        if isLandscape {
            landscapeCompactBody
        } else {
            portraitCompactBody
        }
        #else
        portraitCompactBody
        #endif
    }

    /// Standard scrolling iPhone-portrait layout — player on top, then chips +
    /// camera buttons + summary + details + mini map + notes. The event name
    /// lives in the navigation bar instead of inline.
    @ViewBuilder
    private var portraitCompactBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                rightPlayerColumn
                    .frame(maxWidth: .infinity)

                if hasHeader { headerChips }
                cameraButtonsRows
                // No Apple Intelligence → no AI Summary card at all.
                if EventSummarizer.isAvailable {
                    EventSummarySection(event: event, isGenerating: $isGenerating)
                }
                // LAYOUT: on compact, Details and the mini map each get full
                // width — the map drops below Details instead of sitting to
                // its right.
                EventMetadataSection(event: event)
                // LAYOUT: on iOS let the map flex to the full column width —
                // its own 1.1 aspect ratio sizes the height. Far easier to read
                // than the fixed 220pt square the macOS layout uses.
                EventMiniMapSection(event: event)
                EventNotesSection(event: event)
                    .frame(minHeight: 160)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// iPhone landscape: hide everything except the player so the bounded
    /// VStack inside SyncedMultiCamPlayerView can fit the 4:3 tile by height.
    /// The tab bar AND nav bar are already hidden in landscape (see body),
    /// so this reads as full-screen playback — no horizontal padding so the
    /// tiles get every available pixel.
    @ViewBuilder
    private var landscapeCompactBody: some View {
        rightPlayerColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // No Apple Intelligence → no AI Summary card at all.
            if EventSummarizer.isAvailable {
                EventSummarySection(event: event, isGenerating: $isGenerating)
            }
            cameraButtonsRows
            // LAYOUT: Details + mini map share one row. Details flexes to
            // absorb whatever the column's width allows; the map column is a
            // fixed width and its height is pinned to the Details card's
            // measured height so the two sit flush with no gap beneath the map.
            HStack(alignment: .top, spacing: 8) {
                EventMetadataSection(event: event)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DetailsHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                EventMiniMapSection(event: event, fillsParent: true)
                    .frame(width: miniMapSize)
                    .frame(height: detailsHeight > 0 ? detailsHeight : miniMapSize)
            }
            .onPreferenceChange(DetailsHeightKey.self) { newValue in
                // Guard against tiny oscillations that would trigger relayout loops.
                if abs(newValue - detailsHeight) > 0.5 {
                    detailsHeight = newValue
                }
            }
            // LAYOUT: inside the ScrollView the column takes its natural
            // height, so Notes gets a floor instead of absorbing slack.
            EventNotesSection(event: event)
                .frame(minHeight: 160)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

}

/// Inserts a sample event once the preview's model container is in the
/// environment, then hosts the real detail view. Creating the event before
/// the container exists crashes the preview.
private struct EventDetailPreviewHost: View {
    @Environment(\.modelContext) private var context
    @State private var event: Event?

    var body: some View {
        Group {
            if let event {
                EventDetailView(event: event)
            } else {
                // Real view (not EmptyView) so onAppear fires and inserts
                // the sample.
                Color.clear
            }
        }
        .onAppear {
            guard event == nil else { return }
            let sample = Event(
                source: "Tesla", camera: "5", city: "San Francisco",
                estLatitude: "37.7749", estLongitude: "-122.4194",
                reason: "sentry_aware_object_detection", timestamp: .now,
                interestingnessScore: 0.62, tag: "lingered",
                summary: "A person approached the rear camera, stayed close for about a minute, then walked away."
            )
            context.insert(sample)
            event = sample
        }
    }
}

#Preview {
    NavigationStack { EventDetailPreviewHost() }
        .modelContainer(
            for: [Event.self, Geofence.self, Watchlist.self, VideoRecording.self],
            inMemory: true
        )
}
