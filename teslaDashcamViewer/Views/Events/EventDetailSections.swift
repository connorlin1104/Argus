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

// MARK: - Event Name

/// Large editable event name shown at the top of the left info column.
/// Mirrors the trigger-rename behavior in EventRow: tapping swaps the label
/// for an inline TextField. Reads/writes `event.customName` so changes here
/// also show up in the events list (and vice versa).
/// FONT: matches the wall-clock timer (size 26, semibold, monospaced) so the
/// name visually sits at the same height as the timer in the player column.
/// LAYOUT: lineLimit(1) + minimumScaleFactor shrinks long names so they don't
/// run into the timer on narrow windows.
struct EventNameSection: View {
    @Bindable var event: Event
    @State private var isEditing: Bool = false
    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                // UI: inline rename field
                TextField("Name this event", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .onAppear { fieldFocused = true }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused && isEditing { commit() }
                    }
            } else {
                // TEXT: prominent event name — single-tap to rename
                Text(displayName)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentShape(Rectangle())
                    .onTapGesture { begin() }
                    .help("Click to rename this event")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What renders on the name line: customName if set, else humanized reason.
    private var displayName: String {
        if !event.customName.isEmpty { return event.customName }
        if !event.reason.isEmpty { return EventSummarizer.humanizeReason(event.reason) }
        return "Untitled event"
    }

    /// The auto-derived label (regardless of customName).
    private var originalTrigger: String {
        event.reason.isEmpty ? "" : EventSummarizer.humanizeReason(event.reason)
    }

    private func begin() {
        // Pre-fill with the current display name so users edit from a familiar baseline.
        draft = event.customName.isEmpty ? originalTrigger : event.customName
        isEditing = true
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Treat blank or "matches the auto-generated label" as "no custom name".
        event.customName = (trimmed.isEmpty || trimmed == originalTrigger) ? "" : trimmed
        isEditing = false
    }

    private func cancel() {
        isEditing = false
    }
}

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
