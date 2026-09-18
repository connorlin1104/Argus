//
//  EventClipMatcher.swift
//  Argus
//
//  Single home for the event↔clip time-matching rule. Tesla writes
//  event.json a few seconds AFTER the final clips stop recording — measured
//  0–13 s across a real library — so exact "window contains timestamp"
//  containment misses the event's own footage: events show the Incomplete
//  chip despite having clips, and cameras whose final clip ends a second or
//  two earlier than the others drop out of the detail view. Every matcher
//  extends the clip window past its end by the tolerance below.
//
//  The start side is NOT extended: an event can never belong to a clip that
//  began after it, and widening the start would pull the next minute's clips
//  into every event near a seam.
//

import Foundation

enum EventClipMatcher {

    /// TUNING: how many seconds past a clip's end an event timestamp still
    /// counts as covered by that clip.
    static let toleranceSeconds: TimeInterval = 20

    /// True when the clip window [start, end + tolerance] covers `timestamp`.
    static func covers(start: Date, end: Date, timestamp: Date) -> Bool {
        start <= timestamp && end.addingTimeInterval(toleranceSeconds) >= timestamp
    }

    /// Lower bound for clip-side predicates. Use as:
    ///   `video.startTime <= t && video.endTime >= earliestClipEnd(for: t)`
    static func earliestClipEnd(for timestamp: Date) -> Date {
        timestamp.addingTimeInterval(-toleranceSeconds)
    }

    /// Upper bound for event-side predicates. Use as:
    ///   `event.timestamp >= clipStart && event.timestamp <= latestEventTimestamp(after: clipEnd)`
    static func latestEventTimestamp(after clipEnd: Date) -> Date {
        clipEnd.addingTimeInterval(toleranceSeconds)
    }
}
