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
    
    init(url: URL, bookmark: Data) {
        self.url = url
        self.bookmark = bookmark
    }
}
