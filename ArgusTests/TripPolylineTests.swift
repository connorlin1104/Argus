//
//  TripPolylineTests.swift
//  ArgusTests
//
//  Pure-logic tests for TripPolylineBuilder: trip grouping, chronological
//  ordering, and exclusion of singletons / nil trips / invalid coordinates.
//  Models are plain instances — the builder never touches a ModelContext.
//

import Foundation
import Testing
@testable import Argus

@MainActor
struct TripPolylineTests {

    private func event(lat: String, lon: String,
                       offset: TimeInterval, tripID: UUID?) -> Event {
        let event = Event(source: "Tesla", camera: "front", city: "Austin",
                          estLatitude: lat, estLongitude: lon,
                          reason: "sentry_aware_object_detection",
                          timestamp: Date(timeIntervalSince1970: 1_700_000_000 + offset))
        event.tripID = tripID
        return event
    }

    @Test func groupsByTripAndSkipsNilAndSingletons() {
        let tripA = UUID(), tripB = UUID(), singleton = UUID()
        let events = [
            event(lat: "30.00", lon: "-97.00", offset: 0, tripID: tripA),
            event(lat: "30.01", lon: "-97.01", offset: 60, tripID: tripA),
            event(lat: "31.00", lon: "-98.00", offset: 0, tripID: tripB),
            event(lat: "31.01", lon: "-98.01", offset: 60, tripID: tripB),
            event(lat: "31.02", lon: "-98.02", offset: 120, tripID: tripB),
            event(lat: "32.00", lon: "-99.00", offset: 0, tripID: singleton),
            event(lat: "33.00", lon: "-100.00", offset: 0, tripID: nil),
        ]
        let lines = TripPolylineBuilder.tripLines(events: events)
        #expect(lines.count == 2)
        #expect(Set(lines.map(\.id)) == [tripA, tripB])
    }

    @Test func coordinatesFollowTimestampOrderNotInputOrder() {
        let trip = UUID()
        // Fed newest-first; the line must still run oldest → newest.
        let events = [
            event(lat: "30.02", lon: "-97.02", offset: 120, tripID: trip),
            event(lat: "30.00", lon: "-97.00", offset: 0, tripID: trip),
            event(lat: "30.01", lon: "-97.01", offset: 60, tripID: trip),
        ]
        let lines = TripPolylineBuilder.tripLines(events: events)
        #expect(lines.count == 1)
        let lats = lines[0].coordinates.map(\.latitude)
        #expect(lats == [30.00, 30.01, 30.02])
    }

    @Test func invalidCoordinatesAreExcluded() {
        let trip = UUID()
        let events = [
            event(lat: "30.00", lon: "-97.00", offset: 0, tripID: trip),
            event(lat: "0", lon: "0", offset: 60, tripID: trip),        // null island
            event(lat: "not-a-number", lon: "-97.0", offset: 90, tripID: trip),
            event(lat: "30.01", lon: "-97.01", offset: 120, tripID: trip),
        ]
        let lines = TripPolylineBuilder.tripLines(events: events)
        #expect(lines.count == 1)
        #expect(lines[0].coordinates.count == 2)
    }

    @Test func tripWithOneValidCoordinateDrawsNothing() {
        let trip = UUID()
        let events = [
            event(lat: "30.00", lon: "-97.00", offset: 0, tripID: trip),
            event(lat: "0", lon: "0", offset: 60, tripID: trip),
        ]
        #expect(TripPolylineBuilder.tripLines(events: events).isEmpty)
    }

    @Test func parkedTripAtOneSpotDrawsNothing() {
        // A Sentry session: many events, all at the same parking spot.
        let trip = UUID()
        let events = (0..<5).map { index in
            event(lat: "30.000000", lon: "-97.000000",
                  offset: TimeInterval(index * 60), tripID: trip)
        }
        #expect(TripPolylineBuilder.tripLines(events: events).isEmpty)
    }

    @Test func loopTripKeepsReturnToStart() {
        // A → B → back to A: consecutive-only dedupe must keep all 3 points.
        let trip = UUID()
        let events = [
            event(lat: "30.00", lon: "-97.00", offset: 0, tripID: trip),
            event(lat: "30.01", lon: "-97.01", offset: 60, tripID: trip),
            event(lat: "30.00", lon: "-97.00", offset: 120, tripID: trip),
        ]
        let lines = TripPolylineBuilder.tripLines(events: events)
        #expect(lines.count == 1)
        #expect(lines[0].coordinates.count == 3)
    }

    @Test func consecutiveDuplicatesCollapseButDistinctStopsSurvive() {
        let trip = UUID()
        let events = [
            event(lat: "30.00", lon: "-97.00", offset: 0, tripID: trip),
            event(lat: "30.00003", lon: "-97.00003", offset: 30, tripID: trip), // ~4 m away
            event(lat: "30.01", lon: "-97.01", offset: 60, tripID: trip),
        ]
        let lines = TripPolylineBuilder.tripLines(events: events)
        #expect(lines.count == 1)
        #expect(lines[0].coordinates.count == 2)
    }

    @Test func segmentOpacityRampsTowardTripEnd() {
        let trip = UUID()
        let events = [
            event(lat: "30.00", lon: "-97.00", offset: 0, tripID: trip),
            event(lat: "30.01", lon: "-97.01", offset: 60, tripID: trip),
            event(lat: "30.02", lon: "-97.02", offset: 120, tripID: trip),
        ]
        let line = TripPolylineBuilder.tripLines(events: events)[0]
        let segments = TripPolylineBuilder.segments(for: line)
        #expect(segments.count == 2)
        #expect(segments[0].opacity < segments[1].opacity)
        // Two-point trip: single leg draws fully opaque end-of-ramp.
        let short = TripLine(id: trip, coordinates: Array(line.coordinates.prefix(2)))
        #expect(TripPolylineBuilder.segments(for: short).count == 1)
    }
}
