//
//  EventDetailView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import SwiftUI

struct EventDetailView: View {
    @Bindable var event: Event

    var body: some View {
        List {
            Section("Summary") {
                Text("City: \(event.city)")
                Text("Camera: \(event.camera)")
                Text("Latitude: \(event.estLatitude)")
                Text("Longitude: \(event.estLongitude)")
                Text("Reason: \(event.reason)")

            }
        }
        VideoListView(eventTime: event.timestamp)
    }
}

#Preview {
    //EventDetailView()
}
