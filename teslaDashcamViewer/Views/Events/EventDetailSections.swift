//
//  EventDetailSections.swift
//  teslaDashcamViewer
//
//  Sub-sections rendered inside EventDetailView: AI Summary, Details, Notes.
//  Pulled into their own file to keep EventDetailView small and so each
//  section can be tweaked without scrolling past the others.
//  Search keywords: UI:event-detail, LAYOUT:detail, TEXT:detail
//

import SwiftUI

// MARK: - AI Summary

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

// MARK: - Details

/// The "Details" card — camera, city, address, coords, trigger, behavior, score.
struct EventMetadataSection: View {
    @Bindable var event: Event

    var body: some View {
        // UI: details card
        SectionCard(title: "Details", symbol: "info.circle") {
            VStack(spacing: 0) {
                let camera = TeslaCamera.displayName(for: event.camera)
                if !camera.isEmpty { row("Camera", value: camera) }
                if !event.city.isEmpty { row("City", value: event.city) }
                addressRow
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

    @ViewBuilder
    private var addressRow: some View {
        if event.address.isEmpty {
            // UI: address row with "Look up" reverse-geocode action
            HStack {
                Text("Address").foregroundStyle(.secondary) // TEXT
                Spacer()
                // BUTTON: trigger reverse-geocode
                Button("Look up") {
                    Task { await lookupAddress() }
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 6)
        } else {
            row("Address", value: event.address)
        }
    }

    // UI: single label/value row used inside the details card
    private func row(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            // COLOR: dimmed label
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        // LAYOUT: row vertical padding
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            // COLOR: subtle 0.5pt separator between rows
            Rectangle().fill(.separator).frame(height: 0.5)
        }
    }

    private func lookupAddress() async {
        if let addr = await ReverseGeocoder.reverseGeocode(
            latString: event.estLatitude,
            lonString: event.estLongitude
        ) {
            event.address = addr
        }
    }
}

// MARK: - Notes

/// The free-form "Notes" editor card at the bottom of the detail view.
struct EventNotesSection: View {
    @Bindable var event: Event

    var body: some View {
        // UI: notes card. Editor grows to fill any leftover vertical space in
        // its container so the left info column matches the player column height.
        SectionCard(title: "Notes", symbol: "note.text") {
            TextEditor(text: $event.notes)
                // LAYOUT: minimum height; maxHeight: .infinity lets it absorb slack
                .frame(minHeight: 90, maxHeight: .infinity)
                .padding(8)
                // COLOR: editor background
                .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5)
                )
        }
        .frame(maxHeight: .infinity)
    }
}
