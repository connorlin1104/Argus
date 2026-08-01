//
//  EventExportProgressSheet.swift
//  Argus
//
//  Modal sheet shown while EventExporter is staging + zipping the bundle.
//  When the run finishes, the sheet swaps progress for a ShareLink so the
//  user can move the zip wherever they want.
//

import SwiftUI

struct EventExportProgressSheet: View {
    @Binding var progress: Double
    @Binding var label: String
    @Binding var exportedURL: URL?
    /// Non-nil when the zip finished but is missing clips — the user must
    /// see this before sharing what they may assume is complete footage.
    @Binding var warning: String?
    let onDismiss: () -> Void

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
                    ShareLink(item: url) {
                        Label("Save / share…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Close", action: onDismiss)
                        .buttonStyle(.bordered)
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
}
