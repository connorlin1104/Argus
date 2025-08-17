//
//  VideoRecording.swift
//  teslaDashcamViewer
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
    
    init(url: URL, bookmark: Data, camera: String, startTime: Date, endTime: Date) {
        self.url = url
        self.bookmark = bookmark
        self.camera = camera
        self.startTime = startTime
        self.endTime = endTime
    }
}
