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
                .sheet(item: $playingVideo) { video in
                    PlayerSheet(video: video) { playingVideo = nil }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
