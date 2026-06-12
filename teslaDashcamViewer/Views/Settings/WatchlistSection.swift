//
//  WatchlistSection.swift
//  teslaDashcamViewer
//
//  Settings UI for the plate watchlist. List + an "Add plate" button that
//  opens a WatchlistAddSheet (the inline-form layout was fiddly on macOS).
//

import SwiftUI
import SwiftData

struct WatchlistSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Watchlist.plateText) private var entries: [Watchlist]

    @State private var showAddSheet: Bool = false

    var body: some View {
        Section("Watchlist plates") {
            if entries.isEmpty {
                Text("Add a plate to flag matching events across your library.")
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
        .sheet(isPresented: $showAddSheet) {
            WatchlistAddSheet { plate, note, colorHex in
                let entry = Watchlist(plateText: plate, note: note, colorHex: colorHex)
                modelContext.insert(entry)
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
