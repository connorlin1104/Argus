//
//  SettingsView.swift
//  teslaDashcamViewer
//
//  Manages Home/Work geofences and bulk operations like recomputing zones.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Geofence.name) private var fences: [Geofence]
    @Query private var allEvents: [Event]

    @State private var newName: String = ""
    @State private var newLat: String = ""
    @State private var newLon: String = ""
    @State private var newRadius: String = "100"

    var body: some View {
        NavigationStack {
            settingsForm
                .navigationTitle("Settings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsForm: some View {
        Form {
            Section("Geofences") {
                if fences.isEmpty {
                    Text("No zones yet. Add Home and Work below.").foregroundStyle(.secondary)
                }
                ForEach(fences) { fence in
                    HStack {
                        Text(fence.name).bold()
                        Spacer()
                        Text(String(format: "%.5f, %.5f", fence.latitude, fence.longitude))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0fm", fence.radiusMeters))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            modelContext.delete(fence)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("Add zone") {
                TextField("Name (e.g. Home)", text: $newName)
                TextField("Latitude", text: $newLat)
                TextField("Longitude", text: $newLon)
                TextField("Radius (meters)", text: $newRadius)
                Button("Add") { addFence() }
                    .disabled(newName.isEmpty || Double(newLat) == nil || Double(newLon) == nil)
            }

            Section("Bulk actions") {
                Button("Recompute zones for all events") {
                    recomputeAll()
                }
                .disabled(fences.isEmpty)
                Text("\(allEvents.count) events in library")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("iCloud") {
                Toggle("Sync events & geofences via iCloud", isOn: $iCloudSyncEnabled)
                Text("Requires iCloud capability enabled in Signing & Capabilities. Restart the app after toggling. VideoRecording stays local (security-scoped bookmarks aren't portable).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @AppStorage(teslaDashcamViewerApp.iCloudSyncDefaultsKey) private var iCloudSyncEnabled: Bool = false

    private func addFence() {
        guard let lat = Double(newLat), let lon = Double(newLon) else { return }
        let radius = Double(newRadius) ?? 100
        let fence = Geofence(name: newName, latitude: lat, longitude: lon, radiusMeters: radius)
        modelContext.insert(fence)
        newName = ""
        newLat = ""
        newLon = ""
    }

    private func recomputeAll() {
        for event in allEvents {
            event.zone = GeofenceClassifier.classify(
                latString: event.estLatitude,
                lonString: event.estLongitude,
                fences: fences
            )
        }
    }
}
