//
//  MainView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import SwiftUI
import SwiftData

struct MainView: View {
    var body: some View {
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
