//
//  Geofence.swift
//  teslaDashcamViewer
//
//  User-defined location zone (e.g. Home, Work) used to auto-tag events.
//

import Foundation
import SwiftData
import CoreLocation

@Model
final class Geofence {
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double

    /// Hex color string (e.g. "#34C759"). Drives the row chip + map marker tint.
    var colorHex: String = "#34C759"

    /// SF Symbol used on the map marker for this zone.
    var iconSymbol: String = "house.fill"

    init(name: String, latitude: Double, longitude: Double, radiusMeters: Double = 100,
         colorHex: String = "#34C759", iconSymbol: String = "house.fill") {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
    }

    func distanceMeters(to lat: Double, lon: Double) -> Double {
        let a = CLLocation(latitude: latitude, longitude: longitude)
        let b = CLLocation(latitude: lat, longitude: lon)
        return a.distance(from: b)
    }
}

enum GeofenceClassifier {
    /// Returns the closest matching geofence name within radius, or "" if none.
    static func classify(latString: String, lonString: String, fences: [Geofence]) -> String {
        guard let lat = Double(latString), let lon = Double(lonString) else { return "" }
        if abs(lat) < 0.0001 && abs(lon) < 0.0001 { return "" }
        var best: (name: String, dist: Double)? = nil
        for fence in fences {
            let d = fence.distanceMeters(to: lat, lon: lon)
            if d <= fence.radiusMeters {
                if best == nil || d < best!.dist {
                    best = (fence.name, d)
                }
            }
        }
        return best?.name ?? ""
    }
}
