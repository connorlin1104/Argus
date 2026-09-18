//
//  WatchlistSection.swift
//  Argus
//
//  Settings UI for the plate watchlist. List + an "Add plate" button that
//  opens a WatchlistAddSheet. Presentation state lives in SettingsView (like
//  the geofence picker) — a .sheet attached to a Section inside the Form
//  dismissed itself on first presentation when the row re-rendered.
//

import SwiftUI
import SwiftData

struct WatchlistSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Watchlist.plateText) private var entries: [Watchlist]
    // Match counts only consider events the list can actually show.
    @Query(filter: #Predicate<Event> { !$0.isArchived && !$0.isPendingAnalysis })
    private var events: [Event]

    @Binding var showAddSheet: Bool

    var body: some View {
        Section {
            ForEach(entries) { entry in
                row(entry)
            }
            Button {
                showAddSheet = true
            } label: {
                Label("Add plate", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Watchlist plates")
        } footer: {
            // Persistent (not an empty state) — testers read the vanishing
            // explainer as a broken feature once their first plate hid it.
            Text("Add a plate to flag matching events across your videos.")
        }
    }

    private func row(_ entry: Watchlist) -> some View {
        HStack {
            Circle()
                .fill(GeofenceStyle.color(hex: entry.colorHex) ?? .red)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading) {
                Text(entry.plateText.uppercased())
                    .font(.headline.monospaced())
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).foregroundStyle(.secondary)
                }
                Text(matchCaption(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                modelContext.delete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func matchCaption(for entry: Watchlist) -> String {
        let count = WatchlistMatcher.matchCount(entry: entry, events: events)
        switch count {
        case 0: return "No matches yet"
        case 1: return "1 matching event"
        default: return "\(count) matching events"
        }
    }
}
