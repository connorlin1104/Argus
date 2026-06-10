//
//  SettingsView.swift
//  teslaDashcamViewer
//
//  Settings tab. Manages Home/Work geofences and bulk operations like
//  recomputing zones for all events.
//
//  Sub-components:
//   - GeofencePickerSheet — the "Add zone" modal sheet
//
//  Search keywords: UI:settings, TEXT:settings, BUTTON:settings
//

import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Geofence.name) private var fences: [Geofence]
    @Query private var allEvents: [Event]

    @State private var showPicker: Bool = false

    @AppStorage(teslaDashcamViewerApp.iCloudSyncDefaultsKey)
    private var iCloudSyncEnabled: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                geofencesSection
                bulkActionsSection
                iCloudSection
            }
            .formStyle(.grouped)
            // TEXT: navigation title at top of the Settings tab
            .navigationTitle("Settings")
            .sheet(isPresented: $showPicker) {
                GeofencePickerSheet { name, coord, radius in
                    let fence = Geofence(
                        name: name,
                        latitude: coord.latitude,
                        longitude: coord.longitude,
                        radiusMeters: radius
                    )
                    modelContext.insert(fence)
                }
            }
        }
    }

    // MARK: - Geofences

    /// UI: list of saved zones with delete buttons + "Add zone" button.
    private var geofencesSection: some View {
        Section("Geofences") {
            if fences.isEmpty {
                // TEXT: empty-state copy
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
                Label("Add zone", systemImage: "mappin.and.ellipse") // TEXT/ICON
            }
        }
    }

    /// One row in the geofences list.
    private func geofenceRow(_ fence: Geofence) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(fence.name).font(.headline)
                // TEXT: lat/lon + radius readout
                Text(String(format: "%.5f, %.5f · %.0f m",
                            fence.latitude, fence.longitude, fence.radiusMeters))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // BUTTON: delete this geofence
            Button(role: .destructive) {
                modelContext.delete(fence)
            } label: {
                Image(systemName: "trash") // ICON
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Bulk actions

    /// BUTTON group: bulk maintenance operations on the library.
    private var bulkActionsSection: some View {
        Section("Bulk actions") {
            // BUTTON: walk every event and reclassify its zone
            Button("Recompute zones for all events") {
                SettingsBulkActions.recomputeZones(events: allEvents, fences: fences)
            }
            .disabled(fences.isEmpty)
            // BUTTON: dedupe events + videos
            Button("Remove duplicate events and videos") {
                SettingsBulkActions.removeDuplicates(events: allEvents, modelContext: modelContext)
            }
            // TEXT: counter shown under the buttons
            Text("\(allEvents.count) events in library")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - iCloud

    /// UI: opt-in iCloud sync toggle + caveat copy.
    private var iCloudSection: some View {
        Section("iCloud") {
            // TEXT: toggle label
            Toggle("Sync events & geofences via iCloud", isOn: $iCloudSyncEnabled)
            // TEXT: explanation under the toggle
            Text("Requires iCloud capability enabled in Signing & Capabilities. Restart the app after toggling. VideoRecording stays local (security-scoped bookmarks aren't portable).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
