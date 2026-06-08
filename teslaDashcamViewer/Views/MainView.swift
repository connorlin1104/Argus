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
            TabSection("Events") {
                Tab("Events", systemImage: "list.bullet") {
                    EventsListView()
                }
                Tab("Map", systemImage: "map.fill") {
                    EventsMapView()
                }
            }
            TabSection("Videos") {
                Tab("Videos", systemImage: "play.rectangle.fill") {
                    VideoListView(eventTime: nil)
                }
            }
            TabSection("Settings") {
                Tab("Settings", systemImage: "gearshape.fill") {
                    SettingsView()
                }
            }
        }
        #if os(iOS)
        .tabViewStyle(.sidebarAdaptable)
        #endif
    }
}

#Preview {
    MainView()
}
