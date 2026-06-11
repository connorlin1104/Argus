//
//  EventsListView.swift
//  teslaDashcamViewer
//
//  The primary list of imported Sentry events. Handles search, filter, sort,
//  import, and navigation into EventDetailView.
//
//  Sub-components:
//   - EventRow              — single row in the list
//   - EventChips            — ZoneChip / TagChip / ScoreBadge
//   - EventsImport          — file-importer plumbing
//   - EventsListToolbar     — filter / import toolbar items + row context menu
//   - LiquidGlassStyle      — chip / card backgrounds
//
//  Search keywords: UI:events-list, TEXT:events-list, LAYOUT:events-list
//

import SwiftUI
import SwiftData

struct EventsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Event.timestamp, order: .reverse)])
    private var events: [Event]

    // === Filter / sort state ===
    @State private var showImportView: Bool = false
    @State private var searchText: String = ""
    @State private var tagFilter: String = "all"
    @State private var sortMode: SortMode = .newest
    @State private var favoritesOnly: Bool = false
    @State private var showArchived: Bool = false

    // === Navigation ===
    /// NAV: typed path for the events tab. Push events with `path.append(event)`.
    /// Descendant views (e.g. the mini-map in EventDetailView) push via the
    /// `\.openEvent` environment action below.
    @State private var path: [Event] = []

    /// TEXT: visible sort options in the filter menu.
    enum SortMode: String, CaseIterable, Identifiable {
        case newest, oldest, score
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            case .score:  return "Highest score"
            }
        }
    }

    // MARK: - Filter pipeline

    /// Apply favorites/archive/tag/search/sort to the query results.
    var filteredEvents: [Event] {
        var result = events
        if !showArchived       { result = result.filter { !$0.isArchived } }
        if favoritesOnly       { result = result.filter { $0.isFavorite } }
        if tagFilter != "all"  { result = result.filter { $0.tag == tagFilter } }
        if !searchText.isEmpty { result = result.filter { matchesSearch($0) } }

        switch sortMode {
        case .newest: result.sort { $0.timestamp > $1.timestamp }
        case .oldest: result.sort { $0.timestamp < $1.timestamp }
        case .score:  result.sort { $0.interestingnessScore > $1.interestingnessScore }
        }
        return result
    }

    private func matchesSearch(_ e: Event) -> Bool {
        let q = searchText.lowercased()
        return e.city.lowercased().contains(q) ||
            e.reason.lowercased().contains(q) ||
            e.zone.lowercased().contains(q) ||
            e.summary.lowercased().contains(q) ||
            e.address.lowercased().contains(q) ||
            e.tag.lowercased().contains(q) ||
            e.camera.lowercased().contains(q) ||
            e.notes.lowercased().contains(q)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            content
                // TEXT: navigation title at the top of the tab
                .navigationTitle("Events")
                #if os(macOS)
                .navigationSubtitle("\(filteredEvents.count) of \(events.count)")
                #endif
                // NAV: typed destination so any descendant can push another
                // event by appending to `path` (used by the detail mini-map).
                .navigationDestination(for: Event.self) { event in
                    EventDetailView(event: event)
                }
        }
        // NAV: expose a push action so descendants don't need to own the path.
        .environment(\.openEvent, OpenEventAction { event in
            path.append(event)
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if events.isEmpty {
            emptyState
        } else if filteredEvents.isEmpty {
            // UI: search returned nothing
            ContentUnavailableView.search
                .toolbar { EventsImportToolbar(showImportView: $showImportView) }
                .searchable(text: $searchText, prompt: "Search events")
        } else {
            eventList
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // UI: shown when no events are imported yet
        ContentUnavailableView {
            // TEXT: empty-state title + icon
            Label("No events yet", systemImage: "tray")
        } description: {
            Text("Import a folder of Tesla Sentry event exports to get started.")
        } actions: {
            // BUTTON: open file importer
            Button("Import…") { showImportView = true }
                .buttonStyle(.borderedProminent)
        }
        .toolbar { EventsImportToolbar(showImportView: $showImportView) }
        .fileImporter(isPresented: $showImportView, allowedContentTypes: [.directory]) { result in
            EventsImportRunner.handle(result: result, modelContext: modelContext)
        }
    }

    // MARK: - List

    private var eventList: some View {
        // UI: tap-driven list. Each row owns its own hover highlight and
        // its own tap handler — a tap on the row opens the detail; a tap on
        // the row's trigger label opens the inline rename instead (the
        // trigger's gesture wins because it's the deeper view).
        List {
            ForEach(filteredEvents) { event in
                EventRow(event: event)
                    .contentShape(Rectangle())
                    .onTapGesture { path.append(event) }
                    .contextMenu { EventRowContextMenu(event: event) }
            }
        }
        .listStyle(.inset)
        // TEXT: search placeholder shown in the search field
        .searchable(text: $searchText, prompt: "Search city, reason, plate, summary…")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            #endif
            EventsFilterMenu(
                favoritesOnly: $favoritesOnly,
                showArchived: $showArchived,
                tagFilter: $tagFilter,
                sortMode: $sortMode
            )
            EventsImportToolbar(showImportView: $showImportView)
        }
        .fileImporter(isPresented: $showImportView, allowedContentTypes: [.directory]) { result in
            EventsImportRunner.handle(result: result, modelContext: modelContext)
        }
    }
}

#Preview {
    EventsListView()
}

// MARK: - Cross-view navigation

/// NAV: action that pushes an Event onto the events-tab navigation stack.
/// Descendant views (currently the detail-view mini map) call this to open
/// another event without needing to own the navigation path themselves.
struct OpenEventAction {
    var callback: (Event) -> Void
    func callAsFunction(_ event: Event) { callback(event) }
}

extension EnvironmentValues {
    @Entry var openEvent: OpenEventAction = OpenEventAction { _ in }
}
