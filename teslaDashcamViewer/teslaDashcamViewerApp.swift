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
    static let iCloudSyncDefaultsKey = "iCloudSyncEnabled"

    var sharedModelContainer: ModelContainer = {
        let useICloud = UserDefaults.standard.bool(forKey: iCloudSyncDefaultsKey)

        // Event + Geofence are syncable; VideoRecording stays local because it
        // holds security-scoped URLs and bookmarks that don't translate across devices.
        let cloudConfig = ModelConfiguration(
            "MetadataStore",
            schema: Schema([Event.self, Geofence.self]),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: useICloud ? .automatic : .none
        )
        let localConfig = ModelConfiguration(
            "VideosStore",
            schema: Schema([VideoRecording.self]),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(
                for: Event.self, Geofence.self, VideoRecording.self,
                configurations: cloudConfig, localConfig
            )
        } catch {
            // Most common cause: iCloud entitlement missing. Fall back to local-only.
            print("CloudKit-backed container failed (\(error)); falling back to local store.")
            let fallbackCloud = ModelConfiguration(
                "MetadataStore",
                schema: Schema([Event.self, Geofence.self]),
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
            do {
                return try ModelContainer(
                    for: Event.self, Geofence.self, VideoRecording.self,
                    configurations: fallbackCloud, localConfig
                )
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .modelContainer(sharedModelContainer)
    }
}
