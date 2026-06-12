//
//  VideoRecording.swift
//  Argus
//
//  Created by Connor Lin on 8/15/25.
//

import SwiftData
import Foundation

@Model
final class VideoRecording {
    var url: URL
    var bookmark: Data
    var camera: String
    var startTime: Date
    var endTime: Date

    /// Serialized [DetectionMarker] JSON, written by the analyzer.
    var markersJSON: String = ""

    init(url: URL, bookmark: Data, camera: String, startTime: Date, endTime: Date) {
        self.url = url
        self.bookmark = bookmark
        self.camera = camera
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct DetectionMarker: Codable, Hashable, Sendable {
    /// "human" | "vehicle" | "licensePlate"
    let kind: String
    /// Milliseconds from the start of this VideoRecording.
    let timestampMs: Int
}

extension VideoRecording {
    var markers: [DetectionMarker] {
        guard !markersJSON.isEmpty, let data = markersJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DetectionMarker].self, from: data)) ?? []
    }

    func setMarkers(_ markers: [DetectionMarker]) {
        guard let data = try? JSONEncoder().encode(markers),
              let str = String(data: data, encoding: .utf8) else {
            markersJSON = ""
            return
        }
        markersJSON = str
    }
}
