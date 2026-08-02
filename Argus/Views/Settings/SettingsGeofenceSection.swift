//
//  SettingsGeofenceSection.swift
//  Argus
//
//  Settings UI for the geofence list + "Add zone" button.
//  Extracted from SettingsView to keep that file focused on its
//  navigation chrome.
//

import SwiftUI
import SwiftData
import CoreLocation

struct SettingsGeofenceSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Geofence.name) private var fences: [Geofence]

    /// Bound up to SettingsView so the parent can show the add-zone sheet.
    @Binding var showPicker: Bool

    var body: some View {
        Section("Geofences") {
            if fences.isEmpty {
                Text("No zones yet. Tap “Add zone” to pin one on the map.")
                    .foregroundStyle(.secondary)
            }
            ForEach(fences) { fence in
                geofenceRow(fence)
            }
            // BUTTON: open the geofence picker sheet
            Button {
                showPicker = true
            } label: {
                Label("Add zone", systemImage: "mappin.and.ellipse")
            }
        }
    }

    private func geofenceRow(_ fence: Geofence) -> some View {
        HStack {
            // Visual tag for the zone's tint + icon.
            Image(systemName: fence.iconSymbol.isEmpty ? "house.fill" : fence.iconSymbol)
                .foregroundStyle(GeofenceStyle.color(hex: fence.colorHex) ?? .green)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(fence.name).font(.headline)
                Text(String(format: "%.5f, %.5f · %.0f m",
                            fence.latitude, fence.longitude, fence.radiusMeters))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                modelContext.delete(fence)
                // Strip the deleted zone's label off any events that had it.
                SettingsBulkActions.recomputeZones(modelContext: modelContext)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

}
