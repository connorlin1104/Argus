//
//  ContentView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/12/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sentryEvents: [Event4]
    @State private var showImportView: Bool = false

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(sentryEvents) { event in
                    NavigationLink {
                        List (event.videos) { video in
                            Text(video.url.path)
                            VideoPlayerView(videoURL: resolveBookmark(bookmarkData: video.bookmark)!)
                        }
                    } label: {
                        Text("\(event.timestamp) - camera: \(event.camera)")
                    }
                }
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
#endif
                ToolbarItem {
                    Button("import") {
                        showImportView = true
                    }
                }
            }
            .fileImporter(isPresented: $showImportView, allowedContentTypes: [.directory]) { result in
                switch result {
                case .success(let url):
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

                    let fileManager = FileManager.default
                    do {
                        let items = try fileManager.contentsOfDirectory(
                            at: url,
                            includingPropertiesForKeys: nil,
                            options: []
                        )
                        for child in items {
                            let values = try child.resourceValues(forKeys: [.isDirectoryKey])

                            if values.isDirectory == true {
                                let eventURL = child.appendingPathComponent("event.json")
                                if fileManager.fileExists(atPath: eventURL.path) {
                                    do {
                                        let data = try Data(contentsOf: eventURL)
                                        if let jsonDict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                                            
                                            let camera = jsonDict["camera"] as? String
                                            let city = jsonDict["city"] as? String
                                            let estLatitude = jsonDict["est_lat"] as? String
                                            let estLongitude = jsonDict["est_lon"] as? String
                                            let reason = jsonDict["reason"] as? String
                                            let timestamp = jsonDict["timestamp"] as? String
                                            
                                            let sentryEvent = Event4(camera: camera!,
                                                                          city: city!,
                                                                          estLatitude: estLatitude!,
                                                                          estLongitude: estLongitude!,
                                                                          reason: reason!,
                                                                          timestamp: timestamp!)
                                            
                                            let videoURLs = try fileManager.contentsOfDirectory(
                                                at: child,
                                                includingPropertiesForKeys: nil,
                                                options: []
                                            )
                                            
                                            sentryEvent.videos = videoURLs.map { videoURL in

                                                let bookmarkData = try! videoURL.bookmarkData(options: .withSecurityScope)
                                                return VideoRecording(url: videoURL, bookmark: bookmarkData)
                                            }
                                            
                                            modelContext.insert(sentryEvent)
                                        }
                                    } catch {
                                        print("Failed to read/parse event.json at \(eventURL.path): \(error)")
                                    }
                                }
                            }
                        }
                    } catch {
                        print("error \(error)")
                    }
                    try! modelContext.save()
                    break
                case .failure:
                    print("nothing was selected")
                }
            }
        } detail: {
            Text("Select an item")
        }
    }
    
    // Helper to resolve bookmark (call when needed, e.g., in views)
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

#Preview {
    ContentView()
        //.modelContainer(for: Item.self, inMemory: true)
}
