//
//  EventDetailView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import SwiftUI
import SwiftData

struct EventDetailView: View {
    @Bindable var event: Event
    @State private var isGenerating: Bool = false

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

    private var hasHeader: Bool {
        !event.zone.isEmpty || event.tag != "unknown" || event.interestingnessScore > 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if hasHeader { header }

                if !matchedVideos.isEmpty {
                    SyncedMultiCamPlayerView(videos: matchedVideos)
                } else {
                    ContentUnavailableView(
                        "No matching clips",
                        systemImage: "play.slash",
                        description: Text("No imported videos overlap this event's timestamp (\(event.timestamp.formatted())).")
                    )
                    .frame(height: 220)
                    .liquidGlassCard(cornerRadius: 14)
                }

                summarySection
                metadataSection
                notesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            print("EventDetailView: event.timestamp=\(event.timestamp), matchedVideos.count=\(matchedVideos.count)")
            for v in matchedVideos {
                print("  - cam=\(v.camera) start=\(v.startTime) end=\(v.endTime) path=\(v.url.lastPathComponent)")
            }
        }
        .navigationTitle(event.timestamp.formatted(date: .abbreviated, time: .shortened))
        #if os(macOS)
        .navigationSubtitle({
            let n = TeslaCamera.displayName(for: event.camera)
            return n.isEmpty ? "" : n
        }())
        #endif
        .toolbar {
            ToolbarItem {
                Button {
                    event.isFavorite.toggle()
                } label: {
                    Image(systemName: event.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(event.isFavorite ? .yellow : .secondary)
                }
            }
            ToolbarItem {
                Button {
                    event.isArchived.toggle()
                } label: {
                    Image(systemName: event.isArchived ? "tray.and.arrow.up" : "archivebox")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !event.zone.isEmpty { ZoneChip(zone: event.zone) }
            if event.tag != "unknown" { TagChip(tag: event.tag) }
            if event.interestingnessScore > 0 { ScoreBadge(score: event.interestingnessScore) }
            Spacer()
        }
    }

    private var summarySection: some View {
        Section_Card(title: "AI Summary", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                if event.summary.isEmpty {
                    Text("No summary yet.").foregroundStyle(.secondary)
                } else {
                    Text(event.summary)
                }
                Button {
                    Task { await generateSummary() }
                } label: {
                    if isGenerating {
                        HStack { ProgressView().controlSize(.small); Text("Generating…") }
                    } else {
                        Text(event.summary.isEmpty ? "Generate summary" : "Regenerate")
                    }
                }
                .disabled(isGenerating)
            }
        }
    }

    private var metadataSection: some View {
        Section_Card(title: "Details", symbol: "info.circle") {
            VStack(spacing: 0) {
                let camera = TeslaCamera.displayName(for: event.camera)
                if !camera.isEmpty { row("Camera", value: camera) }
                if !event.city.isEmpty { row("City", value: event.city) }
                if event.address.isEmpty {
                    HStack {
                        Text("Address").foregroundStyle(.secondary)
                        Spacer()
                        Button("Look up") {
                            Task { await lookupAddress() }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                } else {
                    row("Address", value: event.address)
                }
                row("Latitude", value: event.estLatitude)
                row("Longitude", value: event.estLongitude)
                if !event.reason.isEmpty {
                    row("Trigger", value: EventSummarizer.humanizeReason(event.reason))
                }
                if event.tag != "unknown" { row("Behavior", value: event.tag.capitalized) }
                if event.interestingnessScore > 0 {
                    row("Score", value: String(format: "%.0f", event.interestingnessScore * 100))
                }
            }
        }
    }

    private func row(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 0.5)
        }
    }

    private var notesSection: some View {
        Section_Card(title: "Notes", symbol: "note.text") {
            TextEditor(text: $event.notes)
                .frame(minHeight: 90)
                .padding(8)
                .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5)
                )
        }
    }

    private func lookupAddress() async {
        if let addr = await ReverseGeocoder.reverseGeocode(latString: event.estLatitude, lonString: event.estLongitude) {
            event.address = addr
        }
    }

    private func generateSummary() async {
        isGenerating = true
        defer { isGenerating = false }
        let text = await EventSummarizer.summarize(event: event, detection: nil)
        event.summary = text
    }
}

private struct Section_Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .liquidGlassCard(cornerRadius: 14)
    }
}

#Preview {
    //EventDetailView()
}
