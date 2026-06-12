//
//  TripGrouper.swift
//  Argus
//
//  Stamps Event.tripID by walking events in time order and starting a new
//  trip whenever there's a >20 min gap or >5 km location jump.
//

import Foundation
import CoreLocation

enum TripGrouper {

    /// TUNING: time gap that ends a trip.
    static let tripGapSeconds: TimeInterval = 20 * 60

    /// TUNING: distance jump that ends a trip.
    static let tripJumpMeters: Double = 5_000

    /// Walk events in chronological order, stamping tripID. Existing IDs are
    /// overwritten.
    static func regroup(events: [Event]) {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var currentID = UUID()
        var prev: (time: Date, loc: CLLocation?)? = nil

        for event in sorted {
            let loc = location(for: event)
            if let p = prev {
                let dt = event.timestamp.timeIntervalSince(p.time)
                let jumped: Bool = {
                    guard let a = p.loc, let b = loc else { return false }
                    return a.distance(from: b) > tripJumpMeters
                }()
                if dt > tripGapSeconds || jumped {
                    currentID = UUID()
                }
            }
            event.tripID = currentID
            prev = (event.timestamp, loc)
        }
    }

    /// Aggregate stats for a trip — used by EventTripSection.
    struct TripMetadata {
        let start: Date
        let end: Date
        let count: Int
        /// Sum of distance between consecutive events with valid GPS.
        let distanceMeters: Double
    }

    static func metadata(forTrip tripID: UUID, in events: [Event]) -> TripMetadata? {
        let members = events
            .filter { $0.tripID == tripID }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = members.first, let last = members.last else { return nil }

        var dist: Double = 0
        var prev: CLLocation? = nil
        for event in members {
            if let loc = location(for: event) {
                if let p = prev { dist += p.distance(from: loc) }
                prev = loc
            }
        }
        return TripMetadata(start: first.timestamp, end: last.timestamp,
                            count: members.count, distanceMeters: dist)
    }

    private static func location(for event: Event) -> CLLocation? {
        guard let lat = Double(event.estLatitude), let lon = Double(event.estLongitude),
              abs(lat) > 0.0001 || abs(lon) > 0.0001,
              CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lon)) else {
            return nil
        }
        return CLLocation(latitude: lat, longitude: lon)
    }
}
