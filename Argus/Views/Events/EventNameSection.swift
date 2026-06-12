//
//  EventNameSection.swift
//  Argus
//
//  Large editable event-name badge shown at the top of EventDetailView's
//  left info column. Mirrors the trigger-rename behavior in EventRow.
//  Search keywords: UI:event-detail, TEXT:detail, RENAME:name
//

import SwiftUI

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

    /// FONT: sized so the badge frame matches the wall-clock badge on the right.
    /// The wall-clock badge is a two-line VStack (26pt time + caption2 date), so
    /// a single-line title needs a larger font to occupy the same vertical span.
    private static let titleFontSize: CGFloat = 36

    var body: some View {
        Group {
            if isEditing {
                // UI: inline rename field
                TextField("Name this event", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: Self.titleFontSize, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    #if os(macOS)
                    .onExitCommand { cancel() }
                    #endif
                    .onAppear { fieldFocused = true }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused && isEditing { commit() }
                    }
            } else {
                // TEXT: prominent event name — single-tap to rename
                Text(displayName)
                    .font(.system(size: Self.titleFontSize, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .contentShape(Rectangle())
                    .onTapGesture { begin() }
                    .help("Click to rename this event")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // LAYOUT/COLOR: match the wall-clock badge chrome so the name reads as
        // a peer to the timer on the right column.
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
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
