//
//  SectionCard.swift
//  Argus
//
//  Reusable titled card used by EventDetailView and friends.
//  Search keywords: UI:SectionCard, LAYOUT:card, COLOR:card
//

import SwiftUI

/// Titled card with an SF Symbol header label and a liquid-glass background.
/// Used for AI Summary, Details, Notes blocks in the event detail view.
struct SectionCard<Content: View>: View {
    // TEXT: shown as the card's header label
    let title: String
    // ICON: SF Symbol shown next to the title
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // UI: card header — change here to restyle headings on all cards
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // LAYOUT: card internal padding. Bump for roomier cards.
        .padding(16)
        // COLOR: glass background. Restyle in LiquidGlassStyle.swift.
        .liquidGlassCard(cornerRadius: 14)
    }
}
