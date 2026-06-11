//
//  EventNotesSection.swift
//  teslaDashcamViewer
//
//  Free-form "Notes" editor card at the bottom of EventDetailView.
//  Search keywords: UI:event-detail, TEXT:detail, NOTES
//

import SwiftUI

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
