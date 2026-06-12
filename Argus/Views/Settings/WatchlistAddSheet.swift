//
//  WatchlistAddSheet.swift
//  Argus
//
//  Modal "Add plate" sheet. Mirrors the GeofencePickerSheet pattern so the
//  Watchlist UX matches the rest of Settings.
//

import SwiftUI

struct WatchlistAddSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with the user's final values when they tap Save.
    var onSave: (_ plate: String, _ note: String, _ colorHex: String) -> Void

    @State private var plate: String = ""
    @State private var note: String = ""
    @State private var color: Color = .red

    var body: some View {
        NavigationStack {
            Form {
                Section("Plate") {
                    TextField("Plate (e.g. 7XYZ123)", text: $plate)
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        #endif
                    TextField("Note (optional)", text: $note)
                    ColorPicker("Chip color", selection: $color, supportsOpacity: false)
                }
                Section {
                    Text("The chip color appears on events whose detected plate matches this one. Use different colors when you're watching multiple plates so you can tell which match fired at a glance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Watchlist Plate")
            .toolbar { toolbarContent }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                let trimmed = plate.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(trimmed, note, GeofenceStyle.hex(from: color))
                dismiss()
            }
            .disabled(plate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
