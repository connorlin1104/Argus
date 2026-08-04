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

    @Binding var showAddSheet: Bool

    var body: some View {
        Section("Watchlist plates") {
            if entries.isEmpty {
                Text("Add a plate to flag matching events across your videos.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                row(entry)
            }
            Button {
                showAddSheet = true
            } label: {
                Label("Add plate", systemImage: "plus.circle.fill")
            }
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
}
