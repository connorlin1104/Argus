//
//  ImportInstructionsSheet.swift
//  Argus
//
//  Step-by-step guide for importing clips from a USB drive or SSD plugged
//  into the phone. Shown automatically before the very first import and
//  reachable anytime from the Import menu and the empty-state hero — the
//  Files-app dance (find the drive, open the right folder, fall back to
//  picking files) is invisible otherwise and testers never discovered it.
//  "TeslaCam" / "SavedClips" / "SentryClips" appear only as literal folder
//  names.
//  Search keywords: UI:import-help, TEXT:import-help
//

import SwiftUI

struct ImportInstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps the continue button; the parent presents the
    /// import picker from its onDismiss so the two presentations never race.
    /// The sheet always offers continue — a gate that dead-ends the Import
    /// tap it intercepted would read as the app not responding.
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // TEXT: import help steps
                    step(1, symbol: "cable.connector",
                         title: "Plug in your drive",
                         detail: "Connect the USB drive or SSD with your dashcam footage to your iPhone.")
                    step(2, symbol: "square.and.arrow.down",
                         title: "Choose Import Folder",
                         detail: "Tap Import, then Import Folder… to open the file browser.")
                    step(3, symbol: "externaldrive",
                         title: "Find the drive",
                         detail: "In the browser, look under Locations (tap Browse if you don't see it). If the folder list looks empty, try searching for “TeslaCam”.")
                    step(4, symbol: "folder",
                         title: "Open the TeslaCam folder",
                         detail: "Select the TeslaCam folder — or SavedClips / SentryClips inside it — and tap Open. Every event inside is imported automatically.")
                    step(5, symbol: "doc.on.doc",
                         title: "No Open button?",
                         detail: "Some drives don't allow folder access. Go back, choose Select Files…, open one event's folder, and select its event.json together with the .mp4 clips.")
                    step(6, symbol: "checkmark.circle",
                         title: "Keep the drive plugged in",
                         detail: "Footage stays on your drive — importing just catalogs it, so it's fast. Leave the drive connected until analysis finishes, and use Keep on Device to save the events you care about before the car overwrites the drive.")
                }
                .padding(16)
                .liquidGlassCard(cornerRadius: 14)
                .padding(16)
            }
            .navigationTitle("How to import")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // BUTTON: proceed from the guide straight into the picker.
                Button {
                    onContinue()
                    dismiss()
                } label: {
                    Label("Continue to import", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private func step(_ number: Int, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(number). \(title)")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ImportInstructionsSheet(onContinue: {})
}
