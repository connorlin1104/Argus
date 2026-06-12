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
    }
}

#Preview {
    MainView()
}
