//
//  MainView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import SwiftUI
import SwiftData

struct MainView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView {
            TabSection("Events") {
                Tab("Events", systemImage: "book.fill") {
                    EventsListView()
                }
            }
            TabSection("Videos") {
                Tab("Videos", systemImage: "book.fill") {
                    VideoListView(eventTime: nil)
                }
            }

        }
        //.tabViewStyle(.sidebarAdaptable)

    }
}

#Preview {
    MainView()
}
