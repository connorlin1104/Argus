//
//  EventsDensityLayer.swift
//  Argus
//
//  v1 of the "heatmap" — quantizes event coords into a coarse grid and
//  renders one translucent MapCircle per populated bucket, with alpha and
//  radius scaling by bucket count. Not a true Gaussian raster (deferred to
//  v2); good enough to surface dense clusters at a glance.
//

import SwiftUI
import MapKit

@MainActor
@MapContentBuilder
func densityCircles(events: [Event], visibleRegion: MKCoordinateRegion?) -> some MapContent {
    let buckets = DensityBucketer.bucket(events)
    let maxCount = Double(buckets.map(\.count).max() ?? 1)
    // MapCircle radii are in meters, so a fixed radius vanishes when zoomed
    // out. Scale with the visible span instead: the base circle is always
    // ~3% of the viewport. The floor keeps close-up circles near the ~100 m
    // bucket footprint (densest = 2.5×base = 100 m) instead of ballooning.
    let spanMeters = (visibleRegion?.span.latitudeDelta ?? 0.05) * 111_000
    let base = Swift.max(40.0, spanMeters * 0.03)
    ForEach(buckets) { bucket in
        let weight = Double(bucket.count) / maxCount
        // TUNING: densest bucket draws at 2.5× the base radius.
        let radius = base * (1 + 1.5 * weight)
        MapCircle(center: bucket.coordinate, radius: radius)
            .foregroundStyle(
                Color.red.opacity(0.18 + 0.45 * weight)
            )
            .stroke(.red.opacity(0.35), lineWidth: 1)
    }
}

/// Coarse quantization helper. Bucket size ≈ 100 m at the equator.
enum DensityBucketer {
    static let bucketDegrees: Double = 0.001  // ~111 m latitudinally

    struct Bucket: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let count: Int
    }

    static func bucket(_ events: [Event]) -> [Bucket] {
        var counts: [String: (lat: Double, lon: Double, n: Int)] = [:]
        for event in events {
            guard let coord = MarkerStyle.coordinate(event) else { continue }
            let kLat = (coord.latitude / bucketDegrees).rounded() * bucketDegrees
            let kLon = (coord.longitude / bucketDegrees).rounded() * bucketDegrees
            let key = "\(kLat),\(kLon)"
            let prev = counts[key]
            counts[key] = (kLat, kLon, (prev?.n ?? 0) + 1)
        }
        return counts.map { key, value in
            Bucket(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: value.lat, longitude: value.lon),
                count: value.n
            )
        }
    }
}
