//
//  Geocoder.swift
//  Argus
//
//  Thin wrapper around CLGeocoder for reverse-geocoding event coordinates.
//

import Foundation
import CoreLocation

enum ReverseGeocoder {
    static func reverseGeocode(latString: String, lonString: String) async -> String? {
        guard let lat = Double(latString), let lon = Double(lonString) else { return nil }
        if abs(lat) < 0.0001 && abs(lon) < 0.0001 { return nil }

        let location = CLLocation(latitude: lat, longitude: lon)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let place = placemarks.first else { return nil }
            return formatted(place)
        } catch {
            print("Reverse geocode failed: \(error)")
            return nil
        }
    }

    private static func formatted(_ p: CLPlacemark) -> String {
        var parts: [String] = []
        if let n = p.subThoroughfare, let s = p.thoroughfare {
            parts.append("\(n) \(s)")
        } else if let s = p.thoroughfare {
            parts.append(s)
        }
        if let city = p.locality { parts.append(city) }
        if let state = p.administrativeArea { parts.append(state) }
        if let zip = p.postalCode { parts.append(zip) }
        return parts.joined(separator: ", ")
    }
}
