//
//  Untitled.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/15/25.
//

import SwiftData
import Foundation

@Model
final class Event {
    var source: String
    var camera: String
    var city: String
    var estLatitude: String
    var estLongitude: String
    var reason: String
    var timestamp: Date

    var videos: [VideoRecording] = []

    init(source: String, camera: String, city: String, estLatitude: String, estLongitude: String, reason: String, timestamp: Date) {
        self.source = source
        self.camera = camera
        self.city = city
        self.estLatitude = estLatitude
        self.estLongitude = estLongitude
        self.reason = reason
        self.timestamp = timestamp
    }
}
