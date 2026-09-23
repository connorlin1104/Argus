//
//  MapTimelineTests.swift
//  ArgusTests
//
//  Pure-logic tests for the map timeline scrubber: histogram bucketing and
//  the window's inclusive-bounds filtering.
//

import Foundation
import Testing
@testable import Argus

struct MapTimelineTests {

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    // MARK: - Histogram

    @Test func edgeDatesLandInFirstAndLastBucket() {
        let span = date(0)...date(1000)
        let counts = TimelineHistogram.buckets(
            dates: [date(0), date(1000)],
            span: span,
            count: 10
        )
        #expect(counts.count == 10)
        #expect(counts[0] == 1)
        #expect(counts[9] == 1)
        #expect(counts.reduce(0, +) == 2)
    }

    @Test func datesSpreadAcrossExpectedBuckets() {
        let span = date(0)...date(1000)
        // 50 → bucket 0, 250 → bucket 2, 990 → bucket 9, 250 again → bucket 2
        let counts = TimelineHistogram.buckets(
            dates: [date(50), date(250), date(990), date(250)],
            span: span,
            count: 10
        )
        #expect(counts[0] == 1)
        #expect(counts[2] == 2)
        #expect(counts[9] == 1)
        #expect(counts.reduce(0, +) == 4)
    }

    @Test func outOfSpanDatesClampInsteadOfDropping() {
        let span = date(100)...date(200)
        let counts = TimelineHistogram.buckets(
            dates: [date(0), date(300)],
            span: span,
            count: 5
        )
        #expect(counts[0] == 1)
        #expect(counts[4] == 1)
        #expect(counts.reduce(0, +) == 2)
    }

    @Test func zeroLengthSpanPutsEverythingInFirstBucket() {
        // Every event at the same instant — the span collapses to a point.
        let span = date(0)...date(0)
        let counts = TimelineHistogram.buckets(
            dates: [date(0), date(0), date(0)],
            span: span,
            count: 8
        )
        #expect(counts[0] == 3)
        #expect(counts.dropFirst().allSatisfy { $0 == 0 })
    }

    @Test func zeroBucketCountReturnsEmpty() {
        let counts = TimelineHistogram.buckets(
            dates: [date(0)],
            span: date(0)...date(10),
            count: 0
        )
        #expect(counts.isEmpty)
    }

    // MARK: - Window

    @Test func windowBoundsAreInclusive() {
        let window = TimelineWindow(start: date(100), end: date(200))
        #expect(window.contains(date(100)))
        #expect(window.contains(date(200)))
        #expect(window.contains(date(150)))
        #expect(!window.contains(date(99)))
        #expect(!window.contains(date(201)))
    }
}
