//
//  EventMetadataSection.swift
//  Argus
//
//  "Details" card — camera, city, address, coords, trigger, behavior, score —
//  shown in EventDetailView's left info column.
//  Search keywords: UI:event-detail, TEXT:detail, LAYOUT:details
//

import SwiftUI

/// The "Details" card — camera, city, address, coords, trigger, behavior, score.
struct EventMetadataSection: View {
    @Bindable var event: Event

    var body: some View {
        // UI: details card
        SectionCard(title: "Details", symbol: "info.circle") {
            VStack(spacing: 0) {
                let camera = TeslaCamera.displayName(for: event.camera)
                if !camera.isEmpty { row("Camera", value: camera) }
                if !event.city.isEmpty { row("City", value: event.city) }
                addressRow
                row("Latitude", value: event.estLatitude)
                row("Longitude", value: event.estLongitude)
                if !event.reason.isEmpty {
                    row("Trigger", value: EventSummarizer.humanizeReason(event.reason))
                }
                if event.tag != "unknown" { row("Behavior", value: event.tag.capitalized) }
                if event.interestingnessScore > 0 {
                    row("Score", value: String(format: "%.0f", event.interestingnessScore * 100))
                }
            }
        }
    }

    @ViewBuilder
    private var addressRow: some View {
        if event.address.isEmpty {
            // UI: address row with "Look up" reverse-geocode action
            HStack {
                Text("Address").foregroundStyle(.secondary) // TEXT
                Spacer()
                // BUTTON: trigger reverse-geocode
                Button("Look up") {
                    Task { await lookupAddress() }
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 6)
        } else {
            row("Address", value: event.address)
        }
    }

    // UI: single label/value row used inside the details card
    private func row(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            // COLOR: dimmed label
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        // LAYOUT: row vertical padding
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            // COLOR: subtle 0.5pt separator between rows
            Rectangle().fill(.separator).frame(height: 0.5)
        }
    }

    private func lookupAddress() async {
        if let addr = await ReverseGeocoder.reverseGeocode(
            latString: event.estLatitude,
            lonString: event.estLongitude
        ) {
            event.address = addr
        }
    }
}
