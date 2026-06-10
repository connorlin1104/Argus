//
//  EventDetailView.swift
//  teslaDashcamViewer
//
//  Top-level event detail screen. Composes the multi-cam player, AI summary,
//  metadata card, and notes editor.
//
//  Sub-sections live in EventDetailSections.swift.
//  Reusable card chrome lives in Views/Style/SectionCard.swift.
//  Search keywords: UI:event-detail, LAYOUT:detail
//

import SwiftUI
import SwiftData

struct EventDetailView: View {
    @Bindable var event: Event
    @State private var isGenerating: Bool = false

    /// Videos whose recording window covers this event's timestamp.
    @Query private var matchedVideos: [VideoRecording]

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
    /// LAYOUT: Max width for the info cards (Details, Notes). Roughly matches
    /// the video grid width so the whole column reads as one centered layout.
    private let contentMaxWidth: CGFloat = 1050

    /// LAYOUT: Width of the AI Summary card when it hangs in the left margin
    /// next to the centered player. Wider => floats further into the centered
    /// area on narrow windows; narrower => more breathing room for the video.
    private let aiSummaryWingWidth: CGFloat = 260

    private var hasHeader: Bool {
        !event.zone.isEmpty || event.tag != "unknown" || event.interestingnessScore > 0
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if hasHeader {
                    headerChips
                        .frame(maxWidth: contentMaxWidth)
                }

                playerOrPlaceholder

                EventMetadataSection(event: event).frame(maxWidth: contentMaxWidth)
                EventNotesSection(event: event).frame(maxWidth: contentMaxWidth)
            }
            // LAYOUT: outer padding around the whole detail page
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .onAppear { logMatches() }
        .navigationTitle(event.timestamp.formatted(date: .abbreviated, time: .shortened))
        #if os(macOS)
        .navigationSubtitle({
            let n = TeslaCamera.displayName(for: event.camera)
            return n.isEmpty ? "" : n
        }())
        #endif
        .toolbar { toolbarContent }
    }

    // MARK: - Sub-views

    /// Either the synced multi-cam player with the floating AI-summary wing,
    /// or a placeholder + standalone summary card if no clips were matched.
    @ViewBuilder
    private var playerOrPlaceholder: some View {
        if !matchedVideos.isEmpty {
            // UI: floats the AI summary into the player's left margin.
            // LAYOUT: padding(.top, 40) clears the wall-clock badge.
            SyncedMultiCamPlayerView(videos: matchedVideos)
                .overlay(alignment: .topLeading) {
                    EventSummarySection(event: event, isGenerating: $isGenerating)
                        .frame(width: aiSummaryWingWidth)
                        .padding(.leading, 12)
                        .padding(.top, 40)
                }
        } else {
            // TEXT: shown when no clip overlaps this event's timestamp
            ContentUnavailableView(
                "No matching clips",
                systemImage: "play.slash",
                description: Text("No imported videos overlap this event's timestamp (\(event.timestamp.formatted())).")
            )
            .frame(height: 220)
            .liquidGlassCard(cornerRadius: 14)
            .frame(maxWidth: contentMaxWidth)

            EventSummarySection(event: event, isGenerating: $isGenerating)
                .frame(maxWidth: contentMaxWidth)
        }
    }

    /// Compact row of zone/tag/score chips above the player.
    private var headerChips: some View {
        // UI: header chip row
        HStack(spacing: 6) {
            if !event.zone.isEmpty { ZoneChip(zone: event.zone) }
            if event.tag != "unknown" { TagChip(tag: event.tag) }
            if event.interestingnessScore > 0 { ScoreBadge(score: event.interestingnessScore) }
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
