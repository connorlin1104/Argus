//
//  EventsSmartFilterBar.swift
//  teslaDashcamViewer
//
//  Horizontal chip bar above the events list. Renders the prebuilt
//  smart-filter chips (All / Starred / This Week / At Home / etc.).
//

import SwiftUI

struct EventsSmartFilterBar: View {
    @Bindable var state: EventsListFilterState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SmartFilter.allCases) { filter in
                    chip(label: filter.label,
                         symbol: filter.symbol,
                         isActive: state.smartFilter == filter) {
                        state.smartFilter = filter
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func chip(label: String, symbol: String, isActive: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2)
                Text(label)
                    .font(.caption.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? Color.white : .primary)
            .background(
                Capsule().fill(isActive ? Color.accentColor : Color.gray.opacity(0.18))
            )
        }
        .buttonStyle(.plain)
    }
}
