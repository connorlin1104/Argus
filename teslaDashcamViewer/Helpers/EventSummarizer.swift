//
//  EventSummarizer.swift
//  teslaDashcamViewer
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
            You are an assistant that writes short, factual descriptions of Tesla \
            Sentry Mode events. Use 1-2 plain sentences. Don't speculate. Never invent \
            details that are not in the facts.
            """
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: "Summarize this Sentry event:\n\(factsBlock)")
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
        lines.append("- camera: \(TeslaCamera.displayName(for: event.camera))")
        if !event.city.isEmpty { lines.append("- city: \(event.city)") }
        if !event.reason.isEmpty { lines.append("- reason: \(event.reason)") }
        if event.tag != "unknown" { lines.append("- behavior: \(event.tag)") }
        if let d = detection {
            lines.append("- humans observed: \(d.humanCount)")
            if let close = d.closestHumanMeters {
                lines.append(String(format: "- closest approach: %.1f m", close))
            }
            if d.humanPresenceSeconds > 0 {
                lines.append(String(format: "- presence: %.1f s", d.humanPresenceSeconds))
            }
            if d.vehicleCount > 0 { lines.append("- vehicles observed: \(d.vehicleCount)") }
            if let plate = d.firstPlateText { lines.append("- plate seen: \(plate)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func deterministicSummary(facts: String) -> String {
        // Compact fallback used when the on-device model can't run.
        return "Event recorded.\n\(facts)"
    }
}
