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
    /// The picked folder itself, for the disk-size estimate; nil (previews)
    /// just hides the size labels.
    var folderURL: URL? = nil
    /// Called with the chosen window; the parent starts the import from its
    /// onDismiss so the sheet and the banner never race.
    let onChoose: (ImportScope) -> Void

    /// Custom-range defaults: the last week, ending today.
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()

    /// Per-directory clip sizes, scanned once off the main actor when the
    /// sheet appears; nil while the scan is still running (or unavailable).
    @State private var directorySizes: [ImportSizeEstimator.DirectorySize]? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // BUTTON: scope presets
                    option("Import everything", symbol: "tray.full",
                           detail: "Every event in “\(folderName)”.",
                           size: sizeLabel(for: .everything)) {
                        choose(.everything)
                    }
                    option("Last 7 days", symbol: "calendar.badge.clock",
                           detail: "Only events from the past week.",
                           size: sizeLabel(for: .lastDays(7))) {
                        choose(.lastDays(7))
                    }
                    option("Last 30 days", symbol: "calendar",
                           detail: "Only events from the past month.",
                           size: sizeLabel(for: .lastDays(30))) {
                        choose(.lastDays(30))
                    }
                } footer: {
                    // TEXT: scope explainer
                    Text("Sizes show how much footage each range holds on the drive. Importing only records where the clips live — nothing is copied, so even a full drive imports in moments and takes almost no space. The car reuses the drive and can overwrite old footage, so use Keep on Device to save the events that matter. You can always import the folder again with a wider range.")
                }

                Section {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                    // BUTTON: custom-range go
                    Button {
                        choose(.custom(start: customStart, end: customEnd))
                    } label: {
                        Label("Import this range", systemImage: "square.and.arrow.down")
                            .font(.headline)
                    }
                } header: {
                    Text("Custom range")
                } footer: {
                    // TEXT: live estimate for the picked custom window.
                    if let size = sizeLabel(for: .custom(start: customStart, end: customEnd)) {
                        Text("This range holds about \(size) of footage on the drive.")
                    }
                }
            }
            // macOS renders a plain Form with no section insets or card
            // grouping — rows, footer, and pickers all collapse into one
            // ragged column. Grouped style restores the inset cards on the
            // Mac and matches the iOS default.
            .formStyle(.grouped)
            .navigationTitle("What to import?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await scanFolderSizes() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func choose(_ scope: ImportScope) {
        onChoose(scope)
        dismiss()
    }

    /// Sum the folder's clip sizes off the main actor. Metadata-only, but a
    /// slow USB storage provider can still take a moment — the labels simply
    /// appear once the scan lands.
    private func scanFolderSizes() async {
        guard let folderURL, directorySizes == nil else { return }
        directorySizes = await Task.detached(priority: .userInitiated) {
            ImportSizeEstimator.scan(url: folderURL)
        }.value
    }

    /// "1.2 GB"-style disk cost for one scope; nil while the scan is running
    /// (or when the sheet has no folder, as in previews).
    private func sizeLabel(for scope: ImportScope) -> String? {
        guard let directorySizes else { return nil }
        let bytes = ImportSizeEstimator.bytes(for: scope, sizes: directorySizes)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func option(_ title: String, symbol: String, detail: String,
                        size: String? = nil,
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
                if let size {
                    // TEXT: per-option disk cost
                    Text(size)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
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
