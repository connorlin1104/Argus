//
//  LiquidGlassStyle.swift
//  teslaDashcamViewer
//
//  View modifiers for the Liquid Glass look used across the app.
//  Falls back to .thinMaterial on older OS versions.
//  Search keywords: COLOR:glass, UI:glass, LAYOUT:card-bg
//

import SwiftUI

extension View {
    /// Liquid Glass on supported OSes, falling back to a tinted material capsule.
    /// COLOR: chip background — change tint multiplier here to brighten/dim chips.
    @ViewBuilder
    func liquidGlassChip(tint: Color) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            // TUNING: 0.25 = chip glass tint strength.
            self.glassEffect(.regular.tint(tint.opacity(0.25)), in: .capsule)
        } else {
            // Fallback for older OSes
            self.background(tint.opacity(0.2), in: Capsule())
        }
    }

    /// Liquid Glass card background, falling back to .thinMaterial.
    /// COLOR: card background — used by SectionCard, MapEventPopover, etc.
    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
