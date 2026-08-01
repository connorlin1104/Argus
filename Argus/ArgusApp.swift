//
//  ArgusApp.swift
//  Argus
//
//  Created by Connor Lin on 8/12/25.
//

import SwiftUI
import SwiftData

@main
struct ArgusApp: App {
    static let iCloudSyncDefaultsKey = "iCloudSyncEnabled"

    /// Whether the sync toggle was on when the container was built this
    /// launch. Container config is fixed at launch, so a mid-session toggle
    /// flip only takes effect after a relaunch — Settings uses the pair of
    /// these flags to say so.
    static private(set) var cloudSyncRequestedAtLaunch = false

    /// True only when the CloudKit-backed MetadataStore actually
    /// initialized. False when sync was requested but the container fell
    /// back to local-only (missing iCloud entitlement, signed-out account),
    /// so Settings can tell the user their data is NOT syncing.
    static private(set) var cloudSyncActive = false

    var sharedModelContainer: ModelContainer = {
        let useICloud = UserDefaults.standard.bool(forKey: iCloudSyncDefaultsKey)
        ArgusApp.cloudSyncRequestedAtLaunch = useICloud

        // Event + Geofence + Watchlist are syncable; VideoRecording stays local
        // because it holds security-scoped URLs and bookmarks that don't
        // translate across devices.
        let cloudConfig = ModelConfiguration(
            "MetadataStore",
            schema: Schema([Event.self, Geofence.self, Watchlist.self]),
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
            let container = try ModelContainer(
                for: Event.self, Geofence.self, Watchlist.self, VideoRecording.self,
                configurations: cloudConfig, localConfig
            )
            ArgusApp.cloudSyncActive = useICloud
            return container
        } catch {
            // Most common cause: iCloud entitlement missing. Fall back to local-only.
            print("CloudKit-backed container failed (\(error)); falling back to local store.")
            let fallbackCloud = ModelConfiguration(
                "MetadataStore",
                schema: Schema([Event.self, Geofence.self, Watchlist.self]),
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
            do {
                return try ModelContainer(
                    for: Event.self, Geofence.self, Watchlist.self, VideoRecording.self,
                    configurations: fallbackCloud, localConfig
                )
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    init() {
        // Privacy: remove share/export video copies staged in the temp dir
        // by previous sessions (see EventFileVendor.sweepStaleStaging).
        EventFileVendor.sweepStaleStaging()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .modelContainer(sharedModelContainer)
    }
}
