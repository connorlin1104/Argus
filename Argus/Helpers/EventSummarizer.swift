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
            You write a 2–3 sentence summary of a Tesla Sentry Mode event for \
            the vehicle owner, using only the supplied facts.

            Rules:
            - Use only facts listed. Do not invent passengers, gestures, emotions, \
              dialog, weather, time of day, or anything not in the facts.
            - If no detection facts are given, write one sentence noting the trigger, \
              camera, and place, then say on-device analysis has not been run.
            - Never repeat raw units like milliseconds, "ms", frame counts, \
              "bbox", or 0-to-1 scores. Use plain English ("about 30 seconds", \
              "roughly 2 meters"). Round to whole numbers.
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
        return lines.joined(separator: "\n")
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
        // Compact fallback used when the on-device model can't run.
        return "Event recorded.\n\(facts)"
    }
}
