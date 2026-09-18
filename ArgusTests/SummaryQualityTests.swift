//
//  SummaryQualityTests.swift
//  ArgusTests
//
//  Guards against the two AI-summary failure modes testers hit: hallucinated
//  narratives on vehicle-only events, and wrong license plates (single-frame
//  OCR misreads, or duplicate clip rows narrated as separate incidents).
//  Everything here is pure logic — no model call ever runs, because facts
//  without human/plate activity short-circuit to deterministic copy.
//

import CoreGraphics
import Foundation
import Testing
@testable import Argus

@MainActor
struct SummaryQualityTests {

    private nonisolated static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(reason: String = "sentry_aware_object_detection") -> Event {
        Event(source: "Tesla", camera: "front", city: "Austin",
              estLatitude: "30.0", estLongitude: "-97.0",
              reason: reason, timestamp: Self.base)
    }

    private func clip(camera: String = "front",
                      start: Date = base,
                      path: String = "/tmp/clip.mp4",
                      markers: [DetectionMarker] = []) -> VideoRecording {
        let video = VideoRecording(url: URL(fileURLWithPath: path),
                                   bookmark: Data(),
                                   camera: camera,
                                   startTime: start,
                                   endTime: start.addingTimeInterval(60))
        video.setMarkers(markers)
        return video
    }

    private func plateRead(_ text: String, atMs ms: Int) -> Detection {
        Detection(kind: .licensePlate, timestampMs: ms, bbox: .zero,
                  confidence: 0.9, estimatedDistanceMeters: nil,
                  licensePlateText: text)
    }

    // MARK: - Plate consensus

    @Test func singleFrameReadIsNeverVerified() {
        let detections = [plateRead("BSNY1B5", atMs: 0)]
        #expect(VideoAnalyzer.verifiedPlateReads(in: detections).isEmpty)
        #expect(VideoAnalyzer.summarize(detections: detections).firstPlateText == nil)
    }

    @Test func consensusPicksTheRepeatedRead() {
        // Two frames agree on the real plate; one blurry frame misread it.
        let detections = [
            plateRead("8SNY185", atMs: 0),
            plateRead("8SNY185", atMs: 500),
            plateRead("BSNY1B5", atMs: 1000),
        ]
        let verified = VideoAnalyzer.verifiedPlateReads(in: detections)
        #expect(verified == ["8SNY185"])
        #expect(VideoAnalyzer.summarize(detections: detections).firstPlateText == "8SNY185")
    }

    // MARK: - Vehicle-only gating

    @Test func vehicleOnlyEventsSkipTheModel() async {
        let detection = DetectionSummary(
            humanCount: 0, vehicleCount: 12, plateCount: 0,
            closestHumanMeters: nil, humanPresenceSeconds: 0,
            meanHumanMotion: 0, score: 0.1, firstPlateText: nil)
        let videos = [clip(markers: [
            DetectionMarker(kind: "vehicle", timestampMs: 1_000),
            DetectionMarker(kind: "vehicle", timestampMs: 2_000),
        ])]
        let facts = EventSummarizer.makeFacts(event: event(), detection: detection, videos: videos)
        #expect(facts.hasActivity == false)
        #expect(facts.sawVehicles == true)

        let summary = await EventSummarizer.summarize(facts: facts)
        #expect(summary.contains("no people were detected"))
        // Deterministic vehicle copy must stay upgradeable by a later scan.
        #expect(EventSummarizer.isPlaceholderSummary(summary))
    }

    @Test func honkWithVehiclesIsNarratable() {
        // The vehicle-only gate must NOT mute honk events — the nearby car is
        // the story there. The facts also anchor the moment of the honk.
        let detection = DetectionSummary(
            humanCount: 0, vehicleCount: 5, plateCount: 0,
            closestHumanMeters: nil, humanPresenceSeconds: 0,
            meanHumanMotion: 0, score: 0.1, firstPlateText: nil)
        let honk = event(reason: "user_interaction_honk")
        honk.timestamp = Self.base.addingTimeInterval(37)
        let facts = EventSummarizer.makeFacts(
            event: honk, detection: detection, videos: [clip()])
        #expect(facts.hasActivity == true)
        #expect(facts.isDriverReaction == true)
        #expect(facts.text.contains("the driver honked around 0:37"))
    }

    @Test func sentryVehiclesStayGatedButHonkDoesNot() {
        // Same vehicle-only detections: sentry events skip the model, honk
        // events reach it — the trigger is what makes vehicles narratable.
        let detection = DetectionSummary(
            humanCount: 0, vehicleCount: 5, plateCount: 0,
            closestHumanMeters: nil, humanPresenceSeconds: 0,
            meanHumanMotion: 0, score: 0.1, firstPlateText: nil)
        let sentry = EventSummarizer.makeFacts(event: event(), detection: detection, videos: [])
        let honk = EventSummarizer.makeFacts(
            event: event(reason: "user_interaction_honk"), detection: detection, videos: [])
        #expect(sentry.hasActivity == false)
        #expect(honk.hasActivity == true)
    }

    // MARK: - Brief sightings

    @Test func briefSightingsAggregateInsteadOfListing() {
        // Two separate blips plus one sustained sighting: the blips must
        // collapse into one aggregate line, the sustained one stays detailed.
        let markers = [
            DetectionMarker(kind: "human", timestampMs: 5_000),
            DetectionMarker(kind: "human", timestampMs: 15_000),
            DetectionMarker(kind: "human", timestampMs: 30_000),
            DetectionMarker(kind: "human", timestampMs: 33_000),
            DetectionMarker(kind: "human", timestampMs: 36_000),
            DetectionMarker(kind: "human", timestampMs: 39_000),
        ]
        let facts = EventSummarizer.makeFacts(
            event: event(), detection: nil, videos: [clip(markers: markers)])
        #expect(facts.text.contains("brief passing sightings"))
        #expect(facts.text.contains("a person 2 times"))
        #expect(facts.text.contains("a person in view from 0:30 to 0:39"))
        // No per-blip timeline entries survive.
        #expect(!facts.text.contains("0:05"))
        #expect(!facts.text.contains("0:15"))
    }

    @Test func humanActivityIsNarratable() {
        let detection = DetectionSummary(
            humanCount: 8, vehicleCount: 0, plateCount: 0,
            closestHumanMeters: 2.0, humanPresenceSeconds: 12,
            meanHumanMotion: 0.02, score: 0.6, firstPlateText: nil)
        let facts = EventSummarizer.makeFacts(event: event(), detection: detection, videos: [])
        #expect(facts.hasActivity == true)
    }

    @Test func verifiedPlateAloneIsNarratable() {
        let detection = DetectionSummary(
            humanCount: 0, vehicleCount: 3, plateCount: 4,
            closestHumanMeters: nil, humanPresenceSeconds: 0,
            meanHumanMotion: 0, score: 0.2, firstPlateText: "8SNY185")
        let facts = EventSummarizer.makeFacts(event: event(), detection: detection, videos: [])
        #expect(facts.hasActivity == true)
        #expect(facts.text.contains("license plate read (verified): 8SNY185"))
    }

    @Test func unverifiedPlateStaysOutOfFacts() {
        // plateCount > 0 but no consensus text — the facts must not carry any
        // plate line the model could dress up as a real read.
        let detection = DetectionSummary(
            humanCount: 2, vehicleCount: 1, plateCount: 1,
            closestHumanMeters: 3.0, humanPresenceSeconds: 4,
            meanHumanMotion: 0.01, score: 0.4, firstPlateText: nil)
        let facts = EventSummarizer.makeFacts(event: event(), detection: detection, videos: [])
        #expect(!facts.text.contains("plate read"))
    }

    // MARK: - Duplicate clip rows

    @Test func duplicateClipCopiesCollapseInFacts() {
        // Tesla writes the same minute into overlapping event folders: same
        // camera + start, different paths. The scanned copy must win and the
        // timeline must not repeat per copy.
        let markers = [
            DetectionMarker(kind: "human", timestampMs: 40_000),
            DetectionMarker(kind: "human", timestampMs: 41_000),
        ]
        let scanned = clip(path: "/tmp/SentryClips/a/clip.mp4", markers: markers)
        let unscannedCopy = clip(path: "/tmp/SentryClips/b/clip.mp4")
        let scannedCopy = clip(path: "/tmp/SentryClips/c/clip.mp4", markers: markers)

        let alone = EventSummarizer.makeFacts(event: event(), detection: nil, videos: [scanned])
        let withCopies = EventSummarizer.makeFacts(
            event: event(), detection: nil,
            videos: [unscannedCopy, scanned, scannedCopy])
        #expect(withCopies.text == alone.text)
        // The unscanned duplicate must never shadow the scanned copy.
        #expect(withCopies.hasActivity == true)
    }

    // MARK: - Import dedupe key

    @Test func copiesOfOneClipShareAVideoKey() {
        let a = clip(path: "/tmp/SentryClips/a/clip.mp4")
        let b = clip(path: "/tmp/SentryClips/b/clip.mp4")
        let other = clip(camera: "back", path: "/tmp/SentryClips/a/rear.mp4")
        #expect(EventsImportRunner.videoKey(a) == EventsImportRunner.videoKey(b))
        #expect(EventsImportRunner.videoKey(a) != EventsImportRunner.videoKey(other))
    }
}
