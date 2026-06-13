//
//  VideoListView.swift
//  Argus
//
//  Grouped list of all imported clips. Also exposes the "Analyze all" toolbar
//  button that kicks off the Vision detection batch.
//
//  Sub-components:
//   - VideoRow             — single clip row with thumbnail
//   - PlayerSheet          — modal player sheet
//   - VideoAnalysisRunner  — the analyze-all batch loop
//
//  Search keywords: UI:videos-list, BUTTON:analyze, TEXT:videos-list
//

import SwiftUI
import SwiftData

struct VideoListView: View {
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    /// LAYOUT: iPhone landscape gives the popup card a near-full-screen surface,
    /// so the tab bar at the bottom is dead pixels. Detect it via verticalSizeClass.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }
    #endif
    @State private var videoAnalyzer = VideoAnalyzer()
    @State private var playingVideo: VideoRecording?
    var eventTime: Date?

    @Query(sort: [SortDescriptor(\VideoRecording.startTime, order: .reverse)])
    var videos: [VideoRecording]

    init(eventTime: Date?) {
        self.eventTime = eventTime
        if let et = eventTime {
            _videos = Query(
                filter: #Predicate { video in
                    video.startTime <= et && video.endTime >= et
                },
                sort: [SortDescriptor(\VideoRecording.startTime, order: .reverse)]
            )
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                // TEXT: title (changes when viewing event-scoped clips)
                .navigationTitle(eventTime == nil ? "Videos" : "Event clips")
                #if os(macOS)
                .navigationSubtitle("\(videos.count) clip\(videos.count == 1 ? "" : "s")")
                #endif
                .toolbar { analyzeToolbar }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // UI: the video popup is a manual overlay on both platforms so that
        // clicks anywhere outside the card (the dimmed backdrop) dismiss it.
        // We can't use `.sheet` on macOS for this — sheets are modal and
        // swallow outside clicks.
        .overlay {
            if let video = playingVideo {
                playerOverlay(video: video)
                    // Slight fade-in feels less abrupt than instant.
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: playingVideo)
        #if os(iOS)
        // LAYOUT: hide the tab bar while the popup card is up in landscape so
        // the video isn't fighting the tab strip for screen space.
        .toolbar(playingVideo != nil && isLandscape ? .hidden : .automatic, for: .tabBar)
        #endif
    }

    /// Centered modal: dimmed backdrop + PlayerSheet card. Tapping the
    /// backdrop dismisses; the card itself sizes to its natural content
    /// (header + 4:3 video) so there's no empty grey area under the video.
    @ViewBuilder
    private func playerOverlay(video: VideoRecording) -> some View {
        ZStack {
            // UI: dimmed backdrop covers the whole window/screen.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { playingVideo = nil }

            // UI: shrink-wrapped card so the dim shows on all sides.
            PlayerSheet(video: video) { playingVideo = nil }
                #if os(macOS)
                // macOS: cap width so the card stays roughly the size of the
                // old `.sheet` instead of stretching to the full window width.
                .frame(maxWidth: 1000)
                #else
                .frame(maxWidth: .infinity)
                #endif
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(cardBackground)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(radius: 18)
                .padding(20)
        }
    }

    /// Platform-appropriate solid background for the popup card.
    private var cardBackground: some ShapeStyle {
        #if os(iOS)
        return Color(uiColor: .systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if videos.isEmpty {
            // UI: empty state with friendly explanation
            ContentUnavailableView(
                "No videos", // TEXT
                systemImage: "play.rectangle.on.rectangle",
                description: Text(eventTime == nil
                    // TEXT: empty-state hint depending on context
                    ? "Import a Tesla Sentry event folder to populate this list."
                    : "No clips overlap this event's timestamp.")
            )
        } else {
            list
        }
    }

    /// UI: grouped list by date. Each row's whole area is the tap target —
    /// matches the events-list interaction model.
    private var list: some View {
        List {
            Section {
                ForEach(grouped, id: \.key) { group in
                    Section(header: Text(group.key)) {
                        ForEach(group.value) { video in
                            VideoRow(video: video)
                                .contentShape(Rectangle())
                                .onTapGesture { playingVideo = video }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Toolbar

    /// BUTTON: "Scan clips" with linear progress + status text while running.
    /// Runs on-device Vision detection to find people / vehicles / license
    /// plates. Results are written back into each clip's markersJSON and
    /// feed event tags + AI summaries. NOT an export.
    @ToolbarContentBuilder
    private var analyzeToolbar: some ToolbarContent {
        ToolbarItem {
            if videoAnalyzer.isAnalyzing {
                // UI: progress chip — "Scanning… 12/40" + per-task label
                HStack(spacing: 8) {
                    ProgressView(value: videoAnalyzer.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Scanning \(videoAnalyzer.completedVideos)/\(videoAnalyzer.totalVideos)")
                            .font(.caption.monospacedDigit())
                        if !videoAnalyzer.currentTaskLabel.isEmpty {
                            Text(videoAnalyzer.currentTaskLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .help("Scanning clips for people, vehicles, and license plates. No files are exported — results power event tags, scores, and AI summaries.")
            } else {
                Button {
                    runAnalysis()
                } label: {
                    Label("Scan clips for people & plates", systemImage: "wand.and.stars")
                }
                .disabled(videos.isEmpty)
                .help("Runs on-device Vision detection on every clip to find people, vehicles, and license plates. Results power event tags, scores, and AI summaries. No files are exported.")
            }
        }
    }

    // MARK: - Actions

    /// Group videos by formatted date (used for the section headers).
    private var grouped: [(key: String, value: [VideoRecording])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let groups = Dictionary(grouping: videos) { formatter.string(from: $0.startTime) }
        return groups.sorted { $0.key > $1.key }
    }

    private func runAnalysis() {
        let snapshot = Array(videos)
        Task { @MainActor in
            await VideoAnalysisRunner.runAnalysis(
                videos: snapshot,
                analyzer: videoAnalyzer,
                modelContext: modelContext
            )
        }
    }
}
