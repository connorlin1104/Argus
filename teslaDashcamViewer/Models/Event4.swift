//
//  Untitled.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/15/25.
//

import SwiftData
import Foundation

@Model
final class Event4 {

    var camera: String
    var city: String
    var estLatitude: String
    var estLongitude: String
    var reason: String
    var timestamp: String

    var videos: [VideoRecording] = []

    init(camera: String, city: String, estLatitude: String, estLongitude: String, reason: String, timestamp: String) {
        self.camera = camera
        self.city = city
        self.estLatitude = estLatitude
        self.estLongitude = estLongitude
        self.reason = reason
        self.timestamp = timestamp
    }
}
