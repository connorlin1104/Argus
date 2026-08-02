//
//  EventSummarySection.swift
//  Argus
//
//  "AI Summary" card with generate/regenerate button shown in
//  EventDetailView's left info column.
//  Search keywords: UI:event-detail, TEXT:detail, AI:summary
//

import SwiftUI
import SwiftData

/// The "AI Summary" card with regenerate button.
/// TEXT: change copy in this view to edit the summary section labels.
struct EventSummarySection: View {
    @Bindable var event: Event
    @Binding var isGenerating: Bool

    @Environment(\.modelContext) private var modelContext

    /// Observed so the card can say "scanning" while the post-import Vision
    /// pass is still working through this event's clips. Computed so the
    /// memberwise initializer stays non-private.
    private var analyzer: VideoAnalyzer { .shared }

    var body: some View {
        // UI: AI summary card
        SectionCard(title: "AI Summary", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                if event.summary.isEmpty {
                    if analyzer.isAnalyzing {
                        // TEXT: shown while the import's clip scan is running
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scanning this event's clips — the summary appears when the scan reaches it.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // TEXT: empty-state copy
                        Text("No summary yet.").foregroundStyle(.secondary)
                    }
                } else {
                    Text(event.summary)
                        .textSelection(.enabled)
                }
                // BUTTON: generate / regenerate summary
                Button {
                    Task { await generateSummary() }
                } label: {
                    if isGenerating {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Generating…") // TEXT: button label while running
                        }
                    } else {
                        Text(event.summary.isEmpty ? "Generate summary" : "Regenerate") // TEXT
                    }
                }
                .disabled(isGenerating)
            }
        }
    }

    private func generateSummary() async {
        isGenerating = true
        defer { isGenerating = false }
        let text = await EventSummarizer.summarize(
            event: event,
            detection: nil,
            videos: matchedVideos()
        )
        event.summary = text
    }

    /// Clips whose recording window covers this event — their stored
    /// detection markers give the summarizer a timeline of on-screen activity
    /// to narrate.
    private func matchedVideos() -> [VideoRecording] {
        let t = event.timestamp
        let descriptor = FetchDescriptor<VideoRecording>(
            predicate: #Predicate { video in
                video.startTime <= t && video.endTime >= t
            }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
