//
//  ImportScopeSheet.swift
//  Argus
//
//  Asked right after the user picks a folder, before the import starts:
//  import everything, or only a date range? A months-deep SSD holds tens of
//  gigabytes of events — clips outside the chosen range are never probed or
//  copied, which is what makes a scoped import fast. Every option proceeds
//  (2.1a); Cancel just dismisses without importing.
//  Search keywords: UI:import-scope, TEXT:import-scope
//

import SwiftUI

struct ImportScopeSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Name of the folder that's about to be imported, for the header.
    let folderName: String
    /// Called with the chosen window; the parent starts the import from its
    /// onDismiss so the sheet and the banner never race.
    let onChoose: (ImportScope) -> Void

    /// Custom-range defaults: the last week, ending today.
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // BUTTON: scope presets
                    option("Import everything", symbol: "tray.full",
                           detail: "Every event in “\(folderName)”.") {
                        choose(.everything)
                    }
                    option("Last 7 days", symbol: "calendar.badge.clock",
                           detail: "Only events from the past week.") {
                        choose(.lastDays(7))
                    }
                    option("Last 30 days", symbol: "calendar",
                           detail: "Only events from the past month.") {
                        choose(.lastDays(30))
                    }
                } footer: {
                    // TEXT: scope explainer
                    Text("Events outside the range are skipped without copying their clips, so a smaller range imports much faster on big drives. You can always import the folder again with a wider range.")
                }

                Section("Custom range") {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                    // BUTTON: custom-range go
                    Button {
                        choose(.custom(start: customStart, end: customEnd))
                    } label: {
                        Label("Import this range", systemImage: "square.and.arrow.down")
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("What to import?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private func choose(_ scope: ImportScope) {
        onChoose(scope)
        dismiss()
    }

    private func option(_ title: String, symbol: String, detail: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ImportScopeSheet(folderName: "TeslaCam", onChoose: { _ in })
}
