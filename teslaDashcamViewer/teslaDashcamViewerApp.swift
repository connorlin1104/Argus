//
//  teslaDashcamViewerApp.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/12/25.
//

import SwiftUI
import SwiftData

@main
struct teslaDashcamViewerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Event.self,
            VideoRecording.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .modelContainer(sharedModelContainer)
    }
}
