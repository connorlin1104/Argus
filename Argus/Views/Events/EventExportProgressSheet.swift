//
//  EventExportProgressSheet.swift
//  Argus
//
//  Modal sheet shown while EventExporter is staging + zipping the bundle.
//  When the run finishes, the sheet swaps progress for share/save actions
//  that confirm their outcome — handing a zip to the share sheet with no
//  follow-up left users unsure whether anything actually happened.
//

import SwiftUI
import UniformTypeIdentifiers

struct EventExportProgressSheet: View {
    @Binding var progress: Double
    @Binding var label: String
    @Binding var exportedURL: URL?
    /// Non-nil when the zip finished but is missing clips — the user must
    /// see this before sharing what they may assume is complete footage.
    @Binding var warning: String?
    let onDismiss: () -> Void

    /// Result of the last share/save attempt, shown under the buttons.
    @State private var outcome: (message: String, success: Bool)? = nil

    var body: some View {
        VStack(spacing: 16) {
            if let url = exportedURL {
                Image(systemName: warning == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(warning == nil ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                Text(warning == nil ? "Export ready" : "Export incomplete")
                    .font(.headline)
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                HStack {
                    #if os(macOS)
                    ShareLink(item: url) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    // BUTTON: save the zip straight to disk — the macOS share
                    // sheet has no save-to-disk service.
                    Button {
                        saveZip(url)
                    } label: {
                        Label("Save zip…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    #else
                    // Programmatic share (not ShareLink) so the completion
                    // handler can confirm whether the send/save went through.
                    Button {
                        presentShare(url)
                    } label: {
                        Label("Save / share…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    #endif
                    Button("Close", action: onDismiss)
                        .buttonStyle(.bordered)
                }
                if let outcome {
                    Label(outcome.message,
                          systemImage: outcome.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(outcome.success ? .green : .orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            } else {
                ProgressView(value: progress) {
                    Text(label.isEmpty ? "Exporting…" : label)
                        .font(.callout)
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
                Button("Cancel", action: onDismiss)
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(minWidth: 360)
    }

    #if os(macOS)
    /// Copy the finished zip to a user-chosen location and confirm where it
    /// landed.
    private func saveZip(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            outcome = ("Saved to \(dest.deletingLastPathComponent().lastPathComponent)/\(dest.lastPathComponent)", true)
        } catch {
            outcome = ("Couldn't save: \(error.localizedDescription)", false)
        }
    }
    #else
    /// UIActivityViewController instead of ShareLink: its completion handler
    /// is the only way to tell the user the send/save actually finished.
    private func presentShare(_ url: URL) {
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        av.completionWithItemsHandler = { _, completed, _, error in
            Task { @MainActor in
                if let error {
                    outcome = ("Couldn't share: \(error.localizedDescription)", false)
                } else if completed {
                    outcome = ("Export sent / saved successfully.", true)
                }
                // Dismissed without picking anything → no message.
            }
        }
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .keyWindow?
            .rootViewController?
            .present(av, animated: true)
    }
    #endif
}
