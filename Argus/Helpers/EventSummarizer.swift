//
//  EventSummarizer.swift
//  Argus
//
//  Generates short natural-language summaries of dashcam events using the
//  on-device FoundationModels framework.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum EventSummarizer {

    /// True when Apple Intelligence / FoundationModels is available on this device.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        return false
        #else
        return false
        #endif
    }

    /// Build a short, human-readable summary from a detection summary.
    /// `videos` are the clips covering this event — their stored detection
    /// markers become an activity timeline the model can narrate from.
    /// Falls back to a deterministic string if the model is unavailable.
    @MainActor
    static func summarize(event: Event,
                          detection: DetectionSummary?,
                          videos: [VideoRecording] = []) async -> String {
        // Build facts on the main actor so the @Model-backed `event` never
        // crosses an actor boundary — then hand the resulting Sendable string
        // to the off-actor model call below.
        let factsBlock = buildFacts(event: event, detection: detection, videos: videos)
        return await summarize(facts: factsBlock)
    }

    /// Off-actor entry point used after facts have already been built on the
    /// main actor. Safe to call from `@Sendable` closures because `String` is
    /// `Sendable` and the language-model call uses only the string + literals.
    static func summarize(facts factsBlock: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                return deterministicSummary(facts: factsBlock)
            }
            let instructions = """
            You narrate what happens in a Tesla Sentry Mode dashcam event for \
            the vehicle owner, using only the supplied facts.

            Rules:
            - Describe the activity itself, like a brief play-by-play of the \
              clip: who or what appeared, when, on which camera, how close they \
              came, how long they stayed, and when they left.
            - Do NOT mention the street address, city, zone, GPS coordinates, \
              or the date — that information is already shown next to the summary.
            - Use only facts listed. Do not invent actions, passengers, gestures, \
              emotions, dialog, weather, time of day, or anything not in the facts.
            - If no detection or timeline facts are given, write one sentence \
              noting what triggered the recording, then say the clip hasn't been \
              analyzed yet.
            - Never repeat raw units like milliseconds, "ms", frame counts, \
              "bbox", or 0-to-1 scores. Use plain English ("about 30 seconds in", \
              "roughly 2 meters away"). Round to whole numbers.
            - Name cameras as Front, Rear, Left, or Right. If the camera is missing, \
              say "one of the cameras".
            - Plain prose, 2–3 sentences, no bullet lists, no markdown, no headings.
            """
            let session = LanguageModelSession(instructions: instructions)
            do {
                let prompt = "Here are the facts for this Sentry event. Write the summary now.\n\n\(factsBlock)"
                let response = try await session.respond(to: prompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? deterministicSummary(facts: factsBlock) : text
            } catch {
                return deterministicSummary(facts: factsBlock)
            }
        } else {
            return deterministicSummary(facts: factsBlock)
        }
        #else
        return deterministicSummary(facts: factsBlock)
        #endif
    }

    /// Public on the main actor so callers (e.g. AutoSummaryRunner) can
    /// pre-build the facts string while they still hold the SwiftData models,
    /// then hand the string off to the off-actor `summarize(facts:)`.
    @MainActor
    static func makeFacts(event: Event,
                          detection: DetectionSummary?,
                          videos: [VideoRecording] = []) -> String {
        buildFacts(event: event, detection: detection, videos: videos)
    }

    /// Facts fed to the model. Deliberately excludes location/date metadata
    /// (address, city, zone, timestamp) — that's already visible in the
    /// Details card, and the summary should describe what happens on screen.
    @MainActor
    private static func buildFacts(event: Event,
                                   detection: DetectionSummary?,
                                   videos: [VideoRecording]) -> String {
        var lines: [String] = []
        let camName = TeslaCamera.displayName(for: event.camera)
        if !camName.isEmpty {
            lines.append("- triggering camera: \(camName)")
        }
        if !event.reason.isEmpty {
            lines.append("- trigger reason: \(humanizeReason(event.reason))")
        }
        if event.tag != "unknown" {
            lines.append("- automatic behavior tag: \(event.tag)")
        }
        if let d = detection {
            if d.humanCount > 0 {
                lines.append("- person visible: yes")
            }
            if let close = d.closestHumanMeters {
                lines.append("- closest approach: about \(formatMeters(close))")
            }
            if d.humanPresenceSeconds > 0 {
                lines.append("- person stayed in view for about \(formatSeconds(d.humanPresenceSeconds))")
            }
            if d.meanHumanMotion > 0 {
                // Categorical only — never expose the raw 0-1 score to the model.
                lines.append("- movement: \(d.meanHumanMotion > 0.05 ? "active" : "mostly still")")
            }
            if d.vehicleCount > 0 {
                lines.append("- other vehicles visible: yes")
            }
            if d.plateCount > 0 {
                lines.append("- license plate visible: yes")
            }
            if let plate = d.firstPlateText {
                lines.append("- plate read: \(plate)")
            }
        }
        let timeline = timelineFacts(videos: videos)
        if !timeline.isEmpty {
            lines.append("Activity timeline (times are minutes:seconds from the start of the clip):")
            lines.append(contentsOf: timeline)
        }
        return lines.joined(separator: "\n")
    }

    /// Reconstruct per-camera activity intervals from the detection markers
    /// the analyzer stored on each clip — this is what lets the model narrate
    /// what happened over time ("a person came into view, stayed a minute,
    /// then left") instead of restating metadata.
    @MainActor
    private static func timelineFacts(videos: [VideoRecording]) -> [String] {
        // TUNING: markers are sampled a few times per second; gaps longer than
        // this many seconds split one sighting into two separate intervals.
        let mergeGap = 4.0
        // TUNING: cap the prompt size — beyond this the extra lines add noise,
        // not narrative.
        let maxLines = 12

        var lines: [String] = []
        for video in videos.sorted(by: { $0.camera < $1.camera }) {
            let camName = TeslaCamera.displayName(for: video.camera)
            let cam = camName.isEmpty ? "one of the cameras" : "\(camName) camera"
            let byKind = Dictionary(grouping: video.markers, by: \.kind)
            for (kind, markers) in byKind.sorted(by: { $0.key < $1.key }) {
                let label: String
                switch kind {
                case "human": label = "a person"
                case "vehicle": label = "a vehicle"
                case "licensePlate": label = "a license plate"
                default: label = kind
                }
                // Merge the raw per-frame markers into continuous sightings.
                let times = markers.map { Double($0.timestampMs) / 1000 }.sorted()
                var intervals: [(start: Double, end: Double)] = []
                for t in times {
                    if let last = intervals.last, t - last.end <= mergeGap {
                        intervals[intervals.count - 1].end = t
                    } else {
                        intervals.append((t, t))
                    }
                }
                for interval in intervals {
                    if interval.end - interval.start < 2 {
                        lines.append("- \(cam): \(label) seen briefly around \(clockString(interval.start))")
                    } else {
                        lines.append("- \(cam): \(label) in view from \(clockString(interval.start)) to \(clockString(interval.end)) (about \(formatSeconds(interval.end - interval.start)))")
                    }
                }
            }
        }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines.append("- (additional shorter sightings omitted)")
        }
        return lines
    }

    /// Formats seconds as `M:SS` for timeline facts.
    private static func clockString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Round meters to the nearest half so the model sees "about 2 meters"
    /// instead of "1.83 meters".
    private static func formatMeters(_ meters: Double) -> String {
        let rounded = (meters * 2).rounded() / 2
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) meters"
        }
        return String(format: "%.1f meters", rounded)
    }

    /// Convert raw seconds into a human-readable duration so the model can't
    /// echo back milliseconds or oddly precise decimals.
    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds < 1 { return "under a second" }
        if seconds < 60 {
            let whole = Int(seconds.rounded())
            return "\(whole) second\(whole == 1 ? "" : "s")"
        }
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// Map raw Tesla reason codes to human-readable phrases.
    static func humanizeReason(_ raw: String) -> String {
        switch raw {
        case "sentry_aware_object_detection":
            return "Sentry detected a nearby object/person"
        case "user_interaction_dashcam_panic_save":
            return "Driver pressed the panic save button"
        case "user_interaction_dashcam_launcher_action_on":
            return "Driver enabled dashcam recording"
        case "user_interaction_honk":
            return "Driver honked"
        case "user_interaction_drive":
            return "Driver was driving"
        default:
            // Otherwise turn snake_case into Title Case prose.
            if raw.contains("_") {
                let words = raw.replacingOccurrences(of: "_", with: " ")
                return words.prefix(1).uppercased() + words.dropFirst()
            }
            return raw
        }
    }

    private static func deterministicSummary(facts: String) -> String {
        // Shown when the on-device model can't run (unsupported device, OS too
        // old, or the model failed). The raw facts are already visible in the
        // Details card, so we keep this short instead of dumping them again.
        return "This device doesn't support on-device AI summaries."
    }
}
