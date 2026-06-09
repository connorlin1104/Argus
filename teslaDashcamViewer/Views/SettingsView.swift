//
//  SettingsView.swift
//  teslaDashcamViewer
//
//  Manages Home/Work geofences and bulk operations like recomputing zones.
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

    @AppStorage(teslaDashcamViewerApp.iCloudSyncDefaultsKey) private var iCloudSyncEnabled: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Geofences") {
                    if fences.isEmpty {
                        Text("No zones yet. Tap “Add zone” to pin one on the map.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(fences) { fence in
                        HStack {
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
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        showPicker = true
                    } label: {
                        Label("Add zone", systemImage: "mappin.and.ellipse")
                    }
                }

                Section("Bulk actions") {
                    Button("Recompute zones for all events") {
                        recomputeAll()
                    }
                    .disabled(fences.isEmpty)
                    Button("Remove duplicate events and videos") {
                        removeDuplicates()
                    }
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

    private func recomputeAll() {
        for event in allEvents {
            event.zone = GeofenceClassifier.classify(
                latString: event.estLatitude,
                lonString: event.estLongitude,
                fences: fences
            )
        }
    }

    private func removeDuplicates() {
        // Events keyed by source|camera|timestamp(sec)
        var seenEvents: Set<String> = []
        for event in allEvents.sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = "\(event.source)|\(event.camera)|\(Int(event.timestamp.timeIntervalSince1970))"
            if seenEvents.contains(key) {
                modelContext.delete(event)
            } else {
                seenEvents.insert(key)
            }
        }

        // Videos keyed by URL path
        let videoDescriptor = FetchDescriptor<VideoRecording>()
        let videos = (try? modelContext.fetch(videoDescriptor)) ?? []
        var seenPaths: Set<String> = []
        for video in videos {
            let key = video.url.path
            if seenPaths.contains(key) {
                modelContext.delete(video)
            } else {
                seenPaths.insert(key)
            }
        }
        try? modelContext.save()
    }
}

private struct GeofencePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (_ name: String, _ coordinate: CLLocationCoordinate2D, _ radius: Double) -> Void

    @State private var name: String = ""
    @State private var radius: Double = 100
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )
    @State private var pinned: CLLocationCoordinate2D? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $position) {
                        if let pinned {
                            Marker(name.isEmpty ? "New zone" : name, coordinate: pinned)
                                .tint(.green)
                            MapCircle(center: pinned, radius: radius)
                                .foregroundStyle(.green.opacity(0.2))
                                .stroke(.green, lineWidth: 1)
                        }
                    }
                    .onTapGesture { screenPoint in
                        if let coord = proxy.convert(screenPoint, from: .local) {
                            pinned = coord
                        }
                    }
                }
                .overlay(alignment: .top) {
                    Text("Tap on the map to drop a pin")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                }

                Form {
                    Section("Zone") {
                        TextField("Name (e.g. Home)", text: $name)
                        VStack(alignment: .leading) {
                            Text("Radius: \(Int(radius)) m")
                            Slider(value: $radius, in: 25...500, step: 5)
                        }
                        if let pinned {
                            Text(String(format: "%.5f, %.5f", pinned.latitude, pinned.longitude))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No pin yet — tap on the map above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxHeight: 260)
            }
            .navigationTitle("Add Zone")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let pinned, !name.isEmpty {
                            onSave(name, pinned, radius)
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || pinned == nil)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 600)
    }
}
