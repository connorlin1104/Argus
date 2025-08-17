//
//  EventsListView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import SwiftUI
import SwiftData

struct EventsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\Event.timestamp, order: .reverse)
        ]
    ) private var events: [Event]
    @State private var showImportView: Bool = false

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(events) { event in
                    NavigationLink {
                        EventDetailView(event: event)
                    } label: {
                        Text("\(event.timestamp) \(event.source)(camera: \(event.camera))")
                    }
                }
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
#endif
                ToolbarItem {
                    Button("Import") {
                        showImportView = true
                    }
                }
            }
            .fileImporter(isPresented: $showImportView, allowedContentTypes: [.directory]) { result in
                switch result {
                case .success(let url):
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

                    let events = importEvents(url: url)
                    for event in events {
                        modelContext.insert(event)
                    }
                    try! modelContext.save()
                    break
                case .failure:
                    print("nothing was selected")
                }
            }
        } detail: {
            Text("Select an item")
        }
    }
    


}

#Preview {
    EventsListView()
        //.modelContainer(for: Item.self, inMemory: true)
}
