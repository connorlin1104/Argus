//
//  HomeFenceSuggester.swift
//  teslaDashcamViewer
//
//  Mines overnight (22:00–06:00) events for the densest GPS cluster and
//  proposes it as a Home geofence. Greedy, O(n²) — fine for tens of
//  thousands of events.
//

import Foundation
import CoreLocation

enum HomeFenceSuggester {

    struct Suggestion {
        let latitude: Double
        let longitude: Double
        /// Suggested radius in meters (max distance from cluster center).
        let radiusMeters: Double
        /// Events that fell inside the cluster — used for "based on N events" copy.
        let sampleCount: Int
    }

    /// Returns a Home-fence suggestion if there's a clearly dominant overnight
    /// cluster, or nil if there isn't enough data.
    static func suggest(events: [Event]) -> Suggestion? {
        let overnight = events.compactMap(overnightCoord(from:))
        guard overnight.count >= 5 else { return nil }

        // Greedy: for each candidate, count neighbors within `clusterRadiusMeters`.
        // Pick the candidate with the most neighbors as the cluster center.
        let clusterRadiusMeters: Double = 80
        var bestIdx = 0
        var bestCount = 0
        for i in overnight.indices {
            var count = 0
            let center = overnight[i]
            for j in overnight.indices {
                if center.distance(from: overnight[j]) <= clusterRadiusMeters {
                    count += 1
                }
            }
            if count > bestCount {
                bestCount = count
                bestIdx = i
            }
        }
        guard bestCount >= 3 else { return nil }

        // Centroid of the cluster + max distance → radius (clamped 40–200 m).
        let center = overnight[bestIdx]
        let members = overnight.filter { center.distance(from: $0) <= clusterRadiusMeters }
        let avgLat = members.map { $0.coordinate.latitude }.reduce(0, +) / Double(members.count)
        let avgLon = members.map { $0.coordinate.longitude }.reduce(0, +) / Double(members.count)
        let centroid = CLLocation(latitude: avgLat, longitude: avgLon)
        let maxDist = members.map { centroid.distance(from: $0) }.max() ?? 60
        let radius = min(200, max(40, maxDist + 15))

        return Suggestion(
            latitude: avgLat,
            longitude: avgLon,
            radiusMeters: radius,
            sampleCount: members.count
        )
    }

    /// Filter events to those occurring overnight with valid GPS.
    private static func overnightCoord(from event: Event) -> CLLocation? {
        guard let lat = Double(event.estLatitude), let lon = Double(event.estLongitude),
              CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lon)),
              abs(lat) > 0.0001 || abs(lon) > 0.0001 else { return nil }
        let hour = Calendar.current.component(.hour, from: event.timestamp)
        guard hour >= 22 || hour < 6 else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }
}
