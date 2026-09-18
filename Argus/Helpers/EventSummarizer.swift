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

    /// Prompt-ready facts plus whether they contain any actual on-screen
    /// activity for the model to narrate. Built on the main actor (the
    /// @Model-backed event can't cross actors), then handed to the off-actor
    /// `summarize(facts:)` as a plain Sendable value.
    struct Facts: Sendable {
        /// The facts block fed to the model.
        let text: String
        /// True when there's human activity or a verified plate to narrate.
        /// Camera / trigger / tag / vehicle-only lines don't count — they give
        /// the model nothing to narrate, and it invents activity to fill the
        /// gap (vehicle-only events were the worst offenders: "other vehicles
        /// visible: yes" reads as an invitation to make up a story).
        let hasActivity: Bool
        /// Humanized trigger reason ("" when the event has none), used for
        /// the deterministic no-activity summary.
        let trigger: String
        /// True when vehicles were detected — picks the deterministic
        /// vehicles-only sentence over the generic no-activity one.
        let sawVehicles: Bool
        /// True for driver-reaction triggers (honk, panic save). These events
        /// exist because the driver reacted to something, so vehicle sightings
        /// become narratable (the nearby car IS the story) and the model may
        /// offer one clearly hedged guess at the cause.
        let isDriverReaction: Bool
    }

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

    /// Why summaries can't run right now, worded for direct display in the
    /// Settings UI. `nil` when the model is ready. Every tap on the
    /// generate button must produce a visible response (App Review flagged
    /// the silent no-op as "app not responsive"), so this string is what
    /// the button surfaces when it can't start a run.
    static var unavailabilityExplanation: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This device doesn't support Apple Intelligence, which is required for on-device summaries."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in the Settings app, then come back here to generate summaries. Summaries are generated entirely on-device."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading or getting ready. Try again in a few minutes."
            case .unavailable:
                return "On-device summaries are temporarily unavailable."
            }
        }
        return "On-device summaries require a newer version of the operating system."
        #else
        return "On-device summaries aren't supported on this device."
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
        // crosses an actor boundary — then hand the resulting Sendable value
        // to the off-actor model call below.
        let facts = buildFacts(event: event, detection: detection, videos: videos)
        return await summarize(facts: facts)
    }

    /// Off-actor entry point used after facts have already been built on the
    /// main actor. Safe to call from `@Sendable` closures because `Facts` is
    /// `Sendable` and the language-model call uses only the facts + literals.
    static func summarize(facts: Facts) async -> String {
        // The on-device model fabricates people, distances, and actions when
        // handed nothing but a trigger reason or a bare "vehicles visible"
        // fact — the prompt rules below aren't enough to stop it. Events with
        // no human/plate facts get a deterministic sentence instead of a
        // model call.
        guard facts.hasActivity else {
            return noActivitySummary(trigger: facts.trigger, sawVehicles: facts.sawVehicles)
        }
        let factsBlock = facts.text
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                return deterministicSummary()
            }
            var instructions = """
            You report what an automated detector recorded during a Tesla \
            Sentry Mode dashcam event, for the vehicle owner.

            The facts come from a detector, not from watching the footage. It \
            only knows THAT something was in view: a person, a vehicle, an \
            item carried, which camera saw it, roughly how close it came, how \
            long it stayed, and whether it was moving or still. It never \
            knows what anyone was doing or why.

            Rules:
            - Describe, don't tell a story. Every claim must come from a \
              listed fact. When the facts are thin, write one short sentence \
              instead of filling space.
            - The only things you may say about a person or vehicle: it was \
              seen, which camera saw it, how close it came, how long it \
              stayed in view, whether it was moving or standing still, and \
              what was seen with the person (a backpack, a box, a dog).
            - Never describe actions, behavior, or intent the facts don't \
              state: no walking up, checking, looking around, waiting, \
              circling, touching, taking anything, acting suspiciously. Stick \
              to verbs like "was seen", "came within", "stayed in view".
            - Summarize the overall activity. Do NOT recite the timeline \
              entries one by one or give a clock offset for each appearance — \
              mention at most the closest approach or the longest stay.
            - Brief passing sightings are routine people and cars going by. \
              Cover them in one short clause at most ("a few cars passed by") \
              — and leave them out entirely when anything more notable is \
              listed.
            - Do NOT mention the street address, city, zone, GPS coordinates, \
              or the date — that information is already shown next to the summary.
            - Never guess, reconstruct, or invent license plate characters. \
              Mention a plate's characters only when a "license plate read \
              (verified)" fact supplies them, and copy them exactly. If the \
              facts only say a plate was seen, say the plate wasn't readable.
            - Never repeat raw units like milliseconds, "ms", frame counts, \
              "bbox", or 0-to-1 scores. Use plain English ("about 30 seconds in", \
              "roughly 2 meters away"). Round to whole numbers.
            - Name cameras as Front, Rear, Left, or Right. If the camera is missing, \
              say "one of the cameras".
            - Plain prose, at most 2 short sentences, no bullet lists, no \
              markdown, no headings, no technical jargon.
            """
            // The one sanctioned exception to "never guess": the driver honked
            // or saved this clip on purpose, so the reader's question is "why?"
            // A single hedged hypothesis is allowed — but it must be anchored
            // to a listed detection, never free-floating.
            if facts.isDriverReaction {
                instructions += """
                \n
                This clip exists because the driver reacted — a honk or a \
                manual save. Lead with what was detected around that moment. \
                You may suggest ONE possible cause (for example, a vehicle \
                coming close in front), but only when a listed detection \
                supports it, and word it as a possibility — "possibly" or \
                "may have" — never as a fact.
                """
            }
            let session = LanguageModelSession(instructions: instructions)
            do {
                let prompt = "Here are the detector facts for this Sentry event. Describe what was seen.\n\n\(factsBlock)"
                // Greedy decoding: always take the most likely token. The
                // default sampler adds randomness for natural-sounding prose,
                // which on sparse facts shows up as invented detail.
                let response = try await session.respond(
                    to: prompt,
                    options: GenerationOptions(sampling: .greedy))
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? deterministicSummary() : text
            } catch {
                return deterministicSummary()
            }
        } else {
            return deterministicSummary()
        }
        #else
        return deterministicSummary()
        #endif
    }

    /// Public on the main actor so callers (e.g. AutoSummaryRunner) can
    /// pre-build the facts string while they still hold the SwiftData models,
    /// then hand the string off to the off-actor `summarize(facts:)`.
    @MainActor
    static func makeFacts(event: Event,
                          detection: DetectionSummary?,
                          videos: [VideoRecording] = []) -> Facts {
        buildFacts(event: event, detection: detection, videos: videos)
    }

    /// Facts fed to the model. Deliberately excludes location/date metadata
    /// (address, city, zone, timestamp) — that's already visible in the
    /// Details card, and the summary should describe what happens on screen.
    @MainActor
    private static func buildFacts(event: Event,
                                   detection: DetectionSummary?,
                                   videos: [VideoRecording]) -> Facts {
        // Tesla writes the same minute-clip into every event folder that
        // overlaps it, so the store can hold several rows for one recording.
        // Narrating each copy repeats the same activity with slightly
        // different marker times — the model then describes it as several
        // separate incidents. Keep one copy per camera + start.
        let videos = dedupeClipCopies(videos)

        var lines: [String] = []
        let camName = TeslaCamera.displayName(for: event.camera)
        if !camName.isEmpty {
            lines.append("- triggering camera: \(camName)")
        }
        if !event.reason.isEmpty {
            lines.append("- trigger reason: \(humanizeReason(event.reason))")
        }
        // The behavior tag ("touched", "lingered") is deliberately NOT a fact:
        // it's an inference from the distance/duration facts already listed,
        // and a word like "touched" reads as an action the model then narrates
        // as if it were observed.
        var hasHumanFacts = false
        var sawVehicles = false
        var hasVerifiedPlate = false
        if let d = detection {
            if d.humanCount > 0 {
                lines.append("- person visible: yes")
                hasHumanFacts = true
            }
            if let close = d.closestHumanMeters {
                lines.append("- closest approach: about \(formatMeters(close))")
            }
            if d.humanPresenceSeconds > 0, d.humanCount > 0 {
                lines.append("- person stayed in view for about \(formatSeconds(d.humanPresenceSeconds))")
            }
            if d.meanHumanMotion > 0 {
                // Categorical only — never expose the raw 0-1 score to the model.
                lines.append("- movement: \(d.meanHumanMotion > 0.05 ? "active" : "mostly still")")
            }
            if d.vehicleCount > 0 {
                lines.append("- other vehicles visible: yes")
                sawVehicles = true
            }
            // Only a consensus-verified read reaches the model — a
            // single-frame OCR misread repeated in prose looks authoritative
            // and then pollutes watchlist matching (summaries are matched).
            if let plate = d.firstPlateText {
                lines.append("- license plate read (verified): \(plate)")
                hasVerifiedPlate = true
            }
        }
        // What the person had with them — a backpack, a box, a dog. Written
        // by the clip scan; this is what turns "a person approached" into
        // "a person carrying a box approached".
        var contextPhrases: [String] = []
        for video in videos {
            let phrases = video.humanContext
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for phrase in phrases where !phrase.isEmpty && !contextPhrases.contains(phrase) {
                contextPhrases.append(phrase)
            }
        }
        if !contextPhrases.isEmpty {
            lines.append("- seen with the person: \(contextPhrases.joined(separator: ", "))")
            hasHumanFacts = true
        }
        // Driver-reaction events: the moment of the honk / save anchors the
        // description, so the model can focus on what was in view right then.
        let isDriverReaction = event.reason == "user_interaction_honk"
            || event.reason == "user_interaction_dashcam_panic_save"
        if isDriverReaction {
            let verb = event.reason == "user_interaction_honk"
                ? "honked" : "pressed the save button"
            if let covering = videos.first(where: {
                EventClipMatcher.covers(start: $0.startTime, end: $0.endTime,
                                        timestamp: event.timestamp)
            }) {
                let offset = max(0, event.timestamp.timeIntervalSince(covering.startTime))
                lines.append("- the driver \(verb) around \(clockString(offset)) in the timeline")
            } else {
                lines.append("- the driver \(verb) during this event")
            }
        }
        let timeline = timelineFacts(videos: videos)
        if !timeline.isEmpty {
            lines.append("Activity timeline (times are minutes:seconds from the start of the clip):")
            lines.append(contentsOf: timeline)
        }
        for video in videos {
            let kinds = Set(video.markers.map(\.kind))
            if kinds.contains("human") { hasHumanFacts = true }
            if kinds.contains("vehicle") { sawVehicles = true }
        }
        return Facts(
            text: lines.joined(separator: "\n"),
            // Vehicle-only facts don't count as narratable: they carry no
            // story, and the model fills the gap with invented people and
            // actions. Those events get the deterministic sentence instead —
            // EXCEPT when the driver honked or saved on purpose, where the
            // vehicles around that moment are exactly what's worth telling.
            hasActivity: hasHumanFacts || hasVerifiedPlate
                || (isDriverReaction && sawVehicles),
            trigger: event.reason.isEmpty ? "" : humanizeReason(event.reason),
            sawVehicles: sawVehicles,
            isDriverReaction: isDriverReaction
        )
    }

    /// Collapse duplicate rows of the same physical clip (same camera, same
    /// start second), preferring the copy that has been scanned — most
    /// markers wins, so an unscanned duplicate never shadows real activity.
    @MainActor
    private static func dedupeClipCopies(_ videos: [VideoRecording]) -> [VideoRecording] {
        var best: [String: VideoRecording] = [:]
        for video in videos {
            let key = "\(TeslaCamera.canonical(video.camera))|\(Int(video.startTime.timeIntervalSince1970))"
            if let current = best[key], current.markers.count >= video.markers.count {
                continue
            }
            best[key] = video
        }
        return best.values.sorted {
            ($0.camera, $0.startTime) < ($1.camera, $1.startTime)
        }
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
        // not narrative, and tempt the model into reciting every sighting.
        let maxLines = 8
        // TUNING: sightings shorter than this many seconds are routine
        // passers-by and traffic. They collapse into one aggregate line —
        // handed individual entries, the model recites every one of them.
        let briefCutoff = 5.0

        var lines: [String] = []
        var briefCounts: [String: Int] = [:]
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
                    if interval.end - interval.start < briefCutoff {
                        briefCounts[label, default: 0] += 1
                    } else {
                        lines.append("- \(cam): \(label) in view from \(clockString(interval.start)) to \(clockString(interval.end)) (about \(formatSeconds(interval.end - interval.start)))")
                    }
                }
            }
        }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines.append("- (additional sightings omitted)")
        }
        // Aggregate after the cap so the brief-sightings line always survives.
        if !briefCounts.isEmpty {
            let parts = briefCounts.sorted { $0.key < $1.key }.map { label, count in
                count == 1 ? label : "\(label) \(count) times"
            }
            lines.append("- brief passing sightings, routine (each under \(Int(briefCutoff)) seconds): \(parts.joined(separator: ", "))")
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

    private static let unsupportedDeviceText = "This device doesn't support on-device AI summaries."
    private static let noActivityTail = "No on-screen activity has been detected in this event's clips yet."
    private static let vehiclesOnlyTail = "Passing or parked vehicles were seen, but no people were detected in this event's clips."

    private static func deterministicSummary() -> String {
        // Shown when the on-device model can't run (unsupported device, OS too
        // old, or the model failed). The raw facts are already visible in the
        // Details card, so we keep this short instead of dumping them again.
        return unsupportedDeviceText
    }

    /// Deterministic copy for events with nothing to narrate. Worded to cover
    /// both "clips not scanned yet" and "scanned, nothing found" — the caller
    /// can't tell them apart, so the sentence must not claim either. The
    /// vehicles-only variant is what Sentry's most common trigger gets: it
    /// states honestly what was seen instead of letting the model invent.
    private static func noActivitySummary(trigger: String, sawVehicles: Bool) -> String {
        let tail = sawVehicles ? vehiclesOnlyTail : noActivityTail
        return trigger.isEmpty ? tail : "\(trigger). \(tail)"
    }

    /// True for summaries that carry no narrated activity — empty, the
    /// no-activity / vehicles-only placeholders, or the unsupported-device
    /// notice — so a later scan that finds real detections knows it may
    /// overwrite them.
    static func isPlaceholderSummary(_ text: String) -> Bool {
        text.isEmpty || text == unsupportedDeviceText
            || text.hasSuffix(noActivityTail) || text.hasSuffix(vehiclesOnlyTail)
    }
}
