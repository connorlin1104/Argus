//
//  GeofencePickerSheet.swift
//  Argus
//
//  Modal sheet for dropping a pin on a map and saving it as a Geofence.
//  Used by SettingsView's "Add zone" button.
//  Search keywords: UI:geofence-picker, BUTTON:save-zone, LAYOUT:geofence
//

import SwiftUI
import MapKit
import CoreLocation

struct GeofencePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (_ name: String, _ coordinate: CLLocationCoordinate2D, _ radius: Double,
                 _ colorHex: String, _ iconSymbol: String) -> Void

    @State private var name: String = ""
    /// TUNING: default geofence radius in meters
    @State private var radius: Double = 100
    /// User-chosen tint for the zone chip + map marker.
    @State private var color: Color = .green
    /// SF Symbol the map marker uses for this zone.
    @State private var symbol: String = GeofenceStyle.symbolPalette.first ?? "house.fill"
    /// LAYOUT: default map starting region (downtown SF)
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
                mapArea
                formArea
            }
            // TEXT: sheet title
            .navigationTitle("Add Zone")
            .toolbar { toolbarContent }
        }
        #if os(macOS)
        // LAYOUT: minimum sheet dimensions (macOS only — iOS uses native sheet sizing)
        .frame(minWidth: 500, minHeight: 600)
        #endif
    }

    // MARK: - Map

    private var mapArea: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let pinned {
                    // UI: marker at the pinned coordinate
                    Marker(name.isEmpty ? "New zone" : name, coordinate: pinned)
                        .tint(.green) // COLOR: zone marker
                    // UI: shaded circle showing the radius
                    MapCircle(center: pinned, radius: radius)
                        .foregroundStyle(.green.opacity(0.2)) // COLOR: radius fill
                        .stroke(.green, lineWidth: 1)
                }
            }
            .onTapGesture { screenPoint in
                if let coord = proxy.convert(screenPoint, from: .local) {
                    pinned = coord
                }
            }
        }
        // UI: small instruction badge floating over the map
        .overlay(alignment: .top) {
            // TEXT: tap-to-pin hint
            Text("Tap on the map to drop a pin")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    // MARK: - Form

    private var formArea: some View {
        Form {
            Section("Zone") {
                // TEXT: zone name placeholder
                TextField("Name (e.g. Home)", text: $name)
                VStack(alignment: .leading) {
                    // TEXT: "Radius: 120 m"
                    Text("Radius: \(Int(radius)) m")
                    Slider(value: $radius, in: 25...500, step: 5)
                }
                ColorPicker("Tint", selection: $color, supportsOpacity: false)
                Picker("Icon", selection: $symbol) {
                    ForEach(GeofenceStyle.symbolPalette, id: \.self) { sym in
                        Label(GeofenceStyle.displayName(for: sym), systemImage: sym)
                            .tag(sym)
                    }
                }
                if let pinned {
                    // TEXT: lat/lon readout under the slider
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
        // LAYOUT: keep the form compact so the map takes the most space
        .frame(maxHeight: 320)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // BUTTON: cancel sheet
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        // BUTTON: save zone
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                if let pinned, !name.isEmpty {
                    onSave(name, pinned, radius, GeofenceStyle.hex(from: color), symbol)
                    dismiss()
                }
            }
            // Disabled until both name + pin are set.
            .disabled(name.isEmpty || pinned == nil)
        }
    }
}
