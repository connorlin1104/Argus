//
//  EventSummarySection.swift
//  Argus
//
//  "AI Summary" card with generate/regenerate button shown in
//  EventDetailView's left info column.
//  Search keywords: UI:event-detail, TEXT:detail, AI:summary
//

import SwiftUI

/// The "AI Summary" card with regenerate button.
/// TEXT: change copy in this view to edit the summary section labels.
struct EventSummarySection: View {
    @Bindable var event: Event
    @Binding var isGenerating: Bool

    var body: some View {
        // UI: AI summary card
        SectionCard(title: "AI Summary", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                if event.summary.isEmpty {
                    // TEXT: empty-state copy
                    Text("No summary yet.").foregroundStyle(.secondary)
                } else {
                    Text(event.summary)
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
        let text = await EventSummarizer.summarize(event: event, detection: nil)
        event.summary = text
    }
}
