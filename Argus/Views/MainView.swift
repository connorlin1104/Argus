//
//  MainView.swift
//  Argus
//
//  Top-level tab container: Events list, Map, Videos, Settings.
//  Search keywords: UI:main-tabs, TEXT:tab-labels, ICON:tab-icons
//

import SwiftUI
import SwiftData

struct MainView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // UI: root TabView holding the four primary tabs.
        // TEXT: change labels here to rename the tabs site-wide.
        // ICON: change `systemImage` to swap the tab icons.
        TabView {
            EventsListView()
                .tabItem {
                    Label("Events", systemImage: "list.bullet")
                }
            EventsMapView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
            VideoListView(eventTime: nil)
                .tabItem {
                    Label("Videos", systemImage: "play.rectangle.fill")
                }
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        // Events hidden behind isPendingAnalysis whose follow-up scan died
        // with a previous session would otherwise stay invisible forever.
        // Stored clip files nothing references (an import killed before its
        // records saved) are swept here too — before any import can start
        // copying new files.
        .onAppear {
            ImportFollowUpScheduler.shared.releaseStrandedEvents(modelContext: modelContext)
            // Never sweep while an import is copying — its files aren't
            // referenced by saved records yet (onAppear can re-fire when a
            // macOS window is closed and reopened mid-import).
            guard !ImportFeedback.shared.isImporting else { return }
            var descriptor = FetchDescriptor<VideoRecording>()
            descriptor.propertiesToFetch = [\.localFileName]
            let referenced = Set(((try? modelContext.fetch(descriptor)) ?? [])
                .map(\.localFileName)
                .filter { !$0.isEmpty })
            ClipStore.removeOrphans(keeping: referenced)
        }
    }
}

#Preview {
    MainView()
}
