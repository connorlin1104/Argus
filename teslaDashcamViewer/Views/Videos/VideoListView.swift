//
//  VideoListView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import SwiftUI
import SwiftData
import AVFoundation

struct VideoListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var videoAnalyzer = VideoAnalyzer()
    @State private var playingURL: URL?
    var eventTime: Date?
    @Query(
        sort: [
            SortDescriptor(\VideoRecording.startTime, order: .reverse)
        ]
    ) var videos: [VideoRecording]

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

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(eventTime == nil ? "Videos" : "Event clips")
                #if os(macOS)
                .navigationSubtitle("\(videos.count) clip\(videos.count == 1 ? "" : "s")")
                #endif
                .toolbar { analyzeToolbar }
                .sheet(item: Binding(
                    get: { playingURL.map(IdentifiableURL.init) },
                    set: { playingURL = $0?.url }
                )) { wrapper in
                    PlayerSheet(url: wrapper.url) { playingURL = nil }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if videos.isEmpty {
            ContentUnavailableView(
                "No videos",
                systemImage: "play.rectangle.on.rectangle",
                description: Text(eventTime == nil
                    ? "Import a Tesla Sentry event folder to populate this list."
                    : "No clips overlap this event's timestamp.")
            )
        } else {
            List {
                Section {
                    ForEach(grouped, id: \.key) { group in
                        Section(header: Text(group.key)) {
                            ForEach(group.value) { video in
                                VideoRow(video: video) {
                                    play(video)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ToolbarContentBuilder
    private var analyzeToolbar: some ToolbarContent {
        ToolbarItem {
            if videoAnalyzer.isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView(value: videoAnalyzer.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                    Text("\(videoAnalyzer.completedVideos)/\(videoAnalyzer.totalVideos)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    runAnalysis()
                } label: {
                    Label("Analyze all", systemImage: "wand.and.stars")
                }
                .disabled(videos.isEmpty)
            }
        }
    }

    private var grouped: [(key: String, value: [VideoRecording])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let groups = Dictionary(grouping: videos) { formatter.string(from: $0.startTime) }
        return groups.sorted { $0.key > $1.key }
    }

    private func play(_ video: VideoRecording) {
        guard let url = resolveBookmark(bookmarkData: video.bookmark) else { return }
        playingURL = url
    }

    private func runAnalysis() {
        let snapshot = Array(videos)
        Task { @MainActor in
            videoAnalyzer.beginBatch(total: snapshot.count)
            defer { videoAnalyzer.endBatch() }

            for video in snapshot {
                guard let videoURL = resolveBookmark(bookmarkData: video.bookmark) else {
                    videoAnalyzer.tickBatch(label: "Skipped (bookmark)")
                    continue
                }
                let didAccess = videoURL.startAccessingSecurityScopedResource()
                defer { if didAccess { videoURL.stopAccessingSecurityScopedResource() } }

                videoAnalyzer.currentTaskLabel = "Analyzing \(videoURL.lastPathComponent)"
                let (startTime, cameraName) = parseFilename(videoURL.lastPathComponent)
                let detections = await videoAnalyzer.analyzeVideo(url: videoURL, cameraID: cameraName)
                let summary = VideoAnalyzer.summarize(detections: detections)
                let tag = classifyEventTag(summary)

                let markers = detections.map { DetectionMarker(kind: $0.kind.rawValue, timestampMs: $0.timestampMs) }
                video.setMarkers(markers)

                if let r = videoAnalyzer.firstProximityEvent(in: detections), let startTime {
                    let closest = summary.closestHumanMeters ?? 0
                    var reason = String(format: "human within %.1fm at %dms (presence %.1fs)", closest, r, summary.humanPresenceSeconds)
                    if let plate = summary.firstPlateText {
                        reason += " · plate \(plate)"
                    }
                    let event = Event(
                        source: "App",
                        camera: cameraName,
                        city: "unknown",
                        estLatitude: "0",
                        estLongitude: "0",
                        reason: reason,
                        timestamp: startTime,
                        interestingnessScore: summary.score,
                        tag: tag.rawValue
                    )
                    let llmSummary = await EventSummarizer.summarize(event: event, detection: summary)
                    event.summary = llmSummary
                    modelContext.insert(event)
                    do { try modelContext.save() } catch { print("save failed: \(error)") }
                }
                videoAnalyzer.tickBatch(label: "Done \(videoURL.lastPathComponent)")
            }
        }
    }

    private func resolveBookmark(bookmarkData: Data) -> URL? {
        do {
            var isStale = false
            #if os(iOS)
                return try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
            #else
                return try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            #endif
        } catch {
            print("Bookmark resolution error: \(error)")
            return nil
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct VideoRow: View {
    let video: VideoRecording
    var onPlay: () -> Void
    @State private var thumbnail: Image?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.6))
                if let thumbnail {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
                RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.1), lineWidth: 0.5)
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(TeslaCamera.displayName(for: video.camera))
                    .font(.headline)
                Text(video.startTime.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(durationString)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                onPlay()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .task(id: video.url.path) {
            await loadThumbnail()
        }
    }

    private var durationString: String {
        let s = max(0, Int(video.endTime.timeIntervalSince(video.startTime)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        guard let url = resolve() else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 384, height: 216)
        do {
            let (cgImage, _) = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            #if os(macOS)
            thumbnail = Image(nsImage: NSImage(cgImage: cgImage, size: .zero))
            #else
            thumbnail = Image(uiImage: UIImage(cgImage: cgImage))
            #endif
        } catch {
            // leave nil; row will show placeholder
        }
    }

    private func resolve() -> URL? {
        do {
            var isStale = false
            #if os(iOS)
                return try URL(resolvingBookmarkData: video.bookmark, bookmarkDataIsStale: &isStale)
            #else
                return try URL(resolvingBookmarkData: video.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            #endif
        } catch {
            return nil
        }
    }
}

private struct PlayerSheet: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            VideoPlayerView(videoURL: url)
                .aspectRatio(16/9, contentMode: .fit)
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}
