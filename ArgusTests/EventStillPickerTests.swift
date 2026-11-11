//
//  EventStillPickerTests.swift
//  ArgusTests
//
//  Pure-logic tests for the Evidence Package still picker: human-run
//  selection, plate fill, the cap, dedupe, fallbacks, and caption time math.
//

import Foundation
import Testing
@testable import Argus

struct EventStillPickerTests {

    private func human(_ ms: Int) -> DetectionMarker {
        DetectionMarker(kind: "human", timestampMs: ms)
    }

    private func plate(_ ms: Int) -> DetectionMarker {
        DetectionMarker(kind: "licensePlate", timestampMs: ms)
    }

    private func clip(_ index: Int, _ markers: [DetectionMarker]) -> EventStillPicker.ClipMarkers {
        EventStillPicker.ClipMarkers(clipIndex: index, markers: markers)
    }

    // MARK: - Human run selection

    @Test func longestHumanRunWinsAndMidpointIsChosen() {
        // Clip 0: short run (2 markers). Clip 1: long run (5 markers,
        // 10000–14000ms) — its middle marker (12000) should be the still.
        let clips = [
            clip(0, [human(1000), human(1500)]),
            clip(1, [human(10000), human(11000), human(12000), human(13000), human(14000)]),
        ]
        let stills = EventStillPicker.pick(clips: clips)
        #expect(stills.first == EventStillPicker.Still(clipIndex: 1, timestampMs: 12000, reason: "human"))
    }

    @Test func gapSplitsRunsAndBiggerSegmentWins() {
        // One clip, two runs separated by a > 1500ms gap: 3 markers early,
        // 2 markers late. The 3-marker run's midpoint (2000) wins.
        let markers = [human(1000), human(2000), human(3000),
                       human(10000), human(10500)]
        let stills = EventStillPicker.pick(clips: [clip(0, markers)])
        #expect(stills.first?.timestampMs == 2000)
        #expect(stills.first?.reason == "human")
    }

    @Test func singleHumanMarkerDegradesToThatTimestamp() {
        let stills = EventStillPicker.pick(clips: [clip(0, [human(7000)])])
        #expect(stills == [EventStillPicker.Still(clipIndex: 0, timestampMs: 7000, reason: "human")])
    }

    // MARK: - Plates fill remaining slots

    @Test func plateMomentsFollowTheHumanStill() {
        let clips = [
            clip(0, [human(1000), human(2000), human(3000),
                     plate(30000), plate(45000)]),
        ]
        let stills = EventStillPicker.pick(clips: clips)
        #expect(stills.count == 3)
        #expect(stills[0].reason == "human")
        #expect(stills[1] == EventStillPicker.Still(clipIndex: 0, timestampMs: 30000, reason: "plate"))
        #expect(stills[2] == EventStillPicker.Still(clipIndex: 0, timestampMs: 45000, reason: "plate"))
    }

    @Test func capLimitsTotalStills() {
        // 1 human run + 6 plates spread far apart → only 4 stills total.
        let clips = [
            clip(0, [human(1000),
                     plate(10000), plate(20000), plate(30000),
                     plate(40000), plate(50000), plate(60000)]),
        ]
        let stills = EventStillPicker.pick(clips: clips)
        #expect(stills.count == 4)
        #expect(stills[0].reason == "human")
        #expect(stills.dropFirst().allSatisfy { $0.reason == "plate" })
    }

    @Test func nearDuplicateTimestampsAreDeduped() {
        // Plate read 500ms after the human still, same clip → dropped; the
        // distant plate survives.
        let clips = [
            clip(0, [human(5000), plate(5500), plate(20000)]),
        ]
        let stills = EventStillPicker.pick(clips: clips)
        #expect(stills.count == 2)
        #expect(stills[0].timestampMs == 5000)
        #expect(stills[1].timestampMs == 20000)
    }

    @Test func sameTimestampDifferentClipsIsNotADuplicate() {
        // Dedupe is per clip — two cameras reading a plate at the same
        // moment are two different frames worth printing.
        let clips = [
            clip(0, [plate(10000)]),
            clip(1, [plate(10000)]),
        ]
        let stills = EventStillPicker.pick(clips: clips)
        #expect(stills.count == 2)
    }

    // MARK: - Fallbacks

    @Test func noMarkersAnywhereFallsBackToOneSecond() {
        let stills = EventStillPicker.pick(clips: [clip(0, []), clip(1, [])])
        #expect(stills == [EventStillPicker.Still(clipIndex: 0, timestampMs: 1000, reason: "fallback")])
    }

    @Test func vehicleOnlyMarkersAlsoFallBack() {
        // Vehicle markers alone don't pick a still — the fallback frame does.
        let vehicles = [DetectionMarker(kind: "vehicle", timestampMs: 4000)]
        let stills = EventStillPicker.pick(clips: [clip(0, vehicles)])
        #expect(stills.first?.reason == "fallback")
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(EventStillPicker.pick(clips: []).isEmpty)
    }

    // MARK: - Captions

    @Test func captionUsesCameraNameAndWallClockWithSeconds() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let caption = EventStillPicker.caption(cameraID: "front",
                                               clipStart: start,
                                               offsetMs: 17_500)
        #expect(caption.hasPrefix("Front camera — "))
        // 17.5s offset lands on the :17 second mark of the formatted time.
        let expectedTime = start.addingTimeInterval(17.5)
            .formatted(date: .abbreviated, time: .standard)
        #expect(caption.hasSuffix(expectedTime))
    }

    @Test func unknownCameraFallsBackToPlainCamera() {
        let caption = EventStillPicker.caption(cameraID: "mystery",
                                               clipStart: Date(timeIntervalSince1970: 0),
                                               offsetMs: 0)
        #expect(caption.hasPrefix("Camera — "))
    }
}
