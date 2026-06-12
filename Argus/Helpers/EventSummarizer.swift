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
    /// Falls back to a deterministic string if the model is unavailable.
    static func summarize(event: Event, detection: DetectionSummary?) async -> String {
        let factsBlock = buildFacts(event: event, detection: detection)

        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                return deterministicSummary(facts: factsBlock)
            }
            let instructions = """
            You analyze Tesla Sentry Mode dashcam events and write a short, factual \
            summary for the vehicle owner. You receive structured facts gathered from \
            on-device computer vision and the Tesla event metadata.

            STRICT GROUNDING — read first:
            - Describe ONLY what appears in the facts. Do not invent scene content. \
              In particular: do not mention passengers, drivers, gestures, gazes, \
              emotions, intentions, conversations, dialog, traffic, pedestrians, \
              weather, time of day, or any activity that is not explicitly listed \
              in the facts.
            - If the facts contain no detection data (no people, vehicle, or plate \
              counts), do NOT describe the video's contents at all. Instead, write \
              just 1–2 sentences stating only the trigger reason, the camera, the \
              time, and the location — whichever of those are provided. Explicitly \
              say that no on-device analysis has been run yet.
            - If detection facts ARE provided, write 3 to 5 sentences covering: \
              what the detections imply (presence durations, distances, plates), \
              severity (casual passerby vs. lingering vs. deliberate approach vs. \
              contact vs. vehicle-only), and concrete signals to follow up on.

            Style:
            - Refer to cameras by name (Front, Rear, Left, Right). If the triggering \
              camera isn't given, say "one of the cameras" — never invent a camera id.
            - Convert presence durations and distances into natural phrases ("lingered \
              for about 12 seconds", "came within roughly 1.8 meters").
            - If a field is missing, just omit it; do not write "unknown" or "N/A".
            - Plain prose, no bullet lists, no markdown.
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

    private static func buildFacts(event: Event, detection: DetectionSummary?) -> String {
        var lines: [String] = []
        lines.append("- timestamp: \(event.timestamp.formatted(date: .abbreviated, time: .standard))")
        let camName = TeslaCamera.displayName(for: event.camera)
        if !camName.isEmpty {
            lines.append("- triggering camera: \(camName)")
        }
        if !event.city.isEmpty { lines.append("- city: \(event.city)") }
        if !event.address.isEmpty { lines.append("- address: \(event.address)") }
        if !event.zone.isEmpty { lines.append("- zone: \(event.zone)") }
        if !event.reason.isEmpty {
            lines.append("- trigger reason: \(humanizeReason(event.reason))")
        }
        if event.tag != "unknown" {
            lines.append("- automatic behavior tag: \(event.tag)")
        }
        if let d = detection {
            lines.append("- detected people frames: \(d.humanCount)")
            if let close = d.closestHumanMeters {
                lines.append(String(format: "- closest human approach: %.1f m", close))
            }
            if d.humanPresenceSeconds > 0 {
                lines.append(String(format: "- continuous human presence: %.1f s", d.humanPresenceSeconds))
            }
            if d.meanHumanMotion > 0 {
                lines.append(String(format: "- average bbox motion (0-1): %.3f", d.meanHumanMotion))
            }
            if d.vehicleCount > 0 {
                lines.append("- frames containing other vehicles: \(d.vehicleCount)")
            }
            if d.plateCount > 0 {
                lines.append("- license plate readings: \(d.plateCount)")
            }
            if let plate = d.firstPlateText {
                lines.append("- first plate text observed: \(plate)")
            }
        }
        return lines.joined(separator: "\n")
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
        // Compact fallback used when the on-device model can't run.
        return "Event recorded.\n\(facts)"
    }
}
