//
//  SettingsGeofenceSection.swift
//  Argus
//
//  Settings UI for geofence list + "Suggest Home from data" button.
//  Extracted from SettingsView to keep that file focused on its
//  navigation chrome.
//

import SwiftUI
import SwiftData
import CoreLocation

struct SettingsGeofenceSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Geofence.name) private var fences: [Geofence]
    @Query private var allEvents: [Event]

    /// Bound up to SettingsView so the parent can show the add-zone sheet.
    @Binding var showPicker: Bool

    @State private var suggestion: HomeFenceSuggester.Suggestion? = nil
    @State private var showSuggestionAlert: Bool = false

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
            // BUTTON: suggest a Home fence from the user's overnight cluster
            Button {
                suggestion = HomeFenceSuggester.suggest(events: allEvents)
                showSuggestionAlert = true
            } label: {
                Label("Suggest Home from data", systemImage: "sparkles")
            }
            .disabled(allEvents.isEmpty)
        }
        .alert("Suggested Home zone", isPresented: $showSuggestionAlert) {
            Button("Save", action: insertSuggested)
                .disabled(suggestion == nil)
            Button("Cancel", role: .cancel) { suggestion = nil }
        } message: {
            if let s = suggestion {
                Text(String(
                    format: "Found a cluster of %d overnight events near (%.5f, %.5f). Save as 'Home' with a %.0f m radius?",
                    s.sampleCount, s.latitude, s.longitude, s.radiusMeters
                ))
            } else {
                Text("Not enough overnight data to suggest a Home zone yet.")
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

    private func insertSuggested() {
        guard let s = suggestion else { return }
        let fence = Geofence(
            name: "Home",
            latitude: s.latitude,
            longitude: s.longitude,
            radiusMeters: s.radiusMeters
        )
        modelContext.insert(fence)
        // New zones apply immediately — no manual recompute needed.
        SettingsBulkActions.recomputeZones(modelContext: modelContext)
        suggestion = nil
    }
}
