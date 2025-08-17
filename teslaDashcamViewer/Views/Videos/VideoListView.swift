//
//  VideoListView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import SwiftUI
import SwiftData

struct VideoListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var videoAnalyzer = VideoAnalyzer()
    var eventTime: Date?
    @Query(
        sort: [
            SortDescriptor(\VideoRecording.startTime, order: .reverse)
        ]
    ) var videos: [VideoRecording]
    
    init(eventTime: Date?) {
        self.eventTime = eventTime
        if let et = eventTime {
            _videos = Query(
                filter: #Predicate { video in
                    video.startTime <= et && video.endTime >= et
                },
                sort: [SortDescriptor(\VideoRecording.startTime, order: .reverse)]
            )
        }

    }

    var body: some View {
        Button("Analyze all") {
            for video in videos {
                
                let videoURL = resolveBookmark(bookmarkData: video.bookmark)!
                videoURL.startAccessingSecurityScopedResource()

                videoAnalyzer.analyzeVideo(url: videoURL) {result in
                    if let r = result {
                        let (startTime, cameraName) = parseFilename(videoURL.lastPathComponent)

                        let event = Event(
                            source: "App",
                            camera: cameraName,
                            city: "unknown",
                            estLatitude: "12",
                            estLongitude: "12",
                            reason: "human detected",
                            timestamp: startTime!)

                        modelContext.insert(event)
                        try! modelContext.save()
                    }
                }
                videoURL.stopAccessingSecurityScopedResource()

            }
        }
        List (videos) { video in
            Text(video.url.path)
            Text(video.camera)

            Text("\(video.startTime) to \(video.endTime)")
            VideoPlayerView(videoURL: resolveBookmark(bookmarkData: video.bookmark)!)
                .frame(width: 320, height: 240)
        }
    }

    private func resolveBookmark(bookmarkData: Data) -> URL? {
        do {
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData,
                                      options: .withSecurityScope,
                                      bookmarkDataIsStale: &isStale)

            
            return resolvedURL
        } catch {
            print("Bookmark resolution error: \(error)")
            return nil
        }
    }
}
