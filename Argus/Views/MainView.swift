//
//  MainView.swift
//  Argus
//
//  Top-level tab container: Events list, Map, Videos, Settings.
//  Search keywords: UI:main-tabs, TEXT:tab-labels, ICON:tab-icons
//

import SwiftUI
import SwiftData

/// Tab identity — needed so the Map tab can programmatically switch to Events.
enum MainTab: Hashable {
    case events, map, videos, settings
}

struct MainView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab: MainTab = .events
    /// NAV: event a map pin asked to open — handed to the Events tab, which
    /// pushes it onto its own stack and clears this.
    @State private var mapOpenedEvent: Event?

    /// One-shot migration: libraries imported before reference-only import
    /// shipped have every clip copied — mark those events kept so the new
    /// Keep/Remove semantics see them correctly. Never deletes anything.
    @AppStorage("didBackfillKeptOnDevice") private var didBackfillKeptOnDevice = false

    /// Trip grouping rules version this library was last stamped with —
    /// regroup normally only runs at import, so rule changes need a one-shot
    /// restamp to reach existing events.
    @AppStorage("tripGroupingVersion") private var tripGroupingVersion = 0

    var body: some View {
        // UI: root TabView holding the four primary tabs.
        // TEXT: change labels here to rename the tabs site-wide.
        // ICON: change `systemImage` to swap the tab icons.
        TabView(selection: $selectedTab) {
            EventsListView(externalOpenEvent: $mapOpenedEvent)
                .tabItem {
                    Label("Events", systemImage: "list.bullet")
                }
                .tag(MainTab.events)
            EventsMapView(openInEventsTab: { event in
                mapOpenedEvent = event
                selectedTab = .events
            })
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .tag(MainTab.map)
            VideoListView(eventTime: nil)
                .tabItem {
                    Label("Videos", systemImage: "play.rectangle.fill")
                }
                .tag(MainTab.videos)
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(MainTab.settings)
        }
        // Events hidden behind isPendingAnalysis whose follow-up scan died
        // with a previous session would otherwise stay invisible forever.
        // Stored clip files nothing references (an import killed before its
        // records saved) are swept here too — before any import can start
        // copying new files.
        .onAppear {
            #if os(macOS)
            healOversizedWindows()
            #endif
            ImportFollowUpScheduler.shared.releaseStrandedEvents(modelContext: modelContext)
            if !didBackfillKeptOnDevice {
                EventFootageKeeper.backfillKeptFlags(modelContext: modelContext)
                didBackfillKeptOnDevice = true
            }
            if tripGroupingVersion < TripGrouper.groupingVersion {
                let allEvents = (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
                TripGrouper.regroup(events: allEvents)
                try? modelContext.save()
                tripGroupingVersion = TripGrouper.groupingVersion
            }
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

    #if os(macOS)
    /// Earlier builds computed a bogus ~1950pt ideal window height from the
    /// empty-state text (see EventsListView.emptyState) and macOS saved that
    /// frame — every later launch restored a window whose bottom sat far
    /// below the screen, pushing content and the map pin down. Shrink any
    /// restored window that's bigger than its screen back into the visible
    /// area, keeping its top-left corner where the user expects it.
    private func healOversizedWindows() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { continue }
                var frame = window.frame
                guard frame.width > visible.width + 1 || frame.height > visible.height + 1 else { continue }
                let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin = CGPoint(x: max(visible.minX, min(topLeft.x, visible.maxX - frame.width)),
                                       y: max(visible.minY, min(topLeft.y - frame.height, visible.maxY - frame.height)))
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }
    #endif
}

#Preview {
    MainView()
}
