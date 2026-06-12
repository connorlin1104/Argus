//
//  EventsListView.swift
//  teslaDashcamViewer
//
//  The primary list of imported Sentry events. Handles search, smart-filter
//  chips, multi-select, import, and navigation into EventDetailView.
//
//  Sub-components:
//   - EventRow                   — single row in the list
//   - EventChips                 — ZoneChip / TagChip / ScoreBadge
//   - EventsImport               — file-importer plumbing
//   - EventsListToolbar          — filter / import toolbar items + row context menu
//   - EventsListFilterState      — extracted filter+sort state
//   - EventsListSelection        — extracted multi-select state
//   - EventsSmartFilterBar       — chip bar above the list
//   - EventExportProgressSheet   — modal sheet shown during export
//   - LiquidGlassStyle           — chip / card backgrounds
//
//  Search keywords: UI:events-list, TEXT:events-list, LAYOUT:events-list
//

import SwiftUI
import SwiftData

struct EventsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Event.timestamp, order: .reverse)])
    private var events: [Event]

    // === Extracted state ===
    @State private var filterState = EventsListFilterState()
    @State private var selection = EventsListSelection()
    @State private var showImportView: Bool = false

    // === Export state ===
    @State private var exportInProgress: Bool = false
    @State private var exportProgress: Double = 0
    @State private var exportLabel: String = ""
    @State private var exportedZipURL: URL? = nil

    // === Navigation ===
    /// NAV: typed path for the events tab. Push events with `path.append(event)`.
    @State private var path: [Event] = []

    // MARK: - Filter pipeline

    var filteredEvents: [Event] {
        filterState.apply(to: events)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Events")
                #if os(macOS)
                .navigationSubtitle("\(filteredEvents.count) of \(events.count)")
                #endif
                .navigationDestination(for: Event.self) { event in
                    EventDetailView(event: event)
                }
        }
        .environment(\.openEvent, OpenEventAction { event in
            path.append(event)
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $exportInProgress) {
            EventExportProgressSheet(
                progress: $exportProgress,
                label: $exportLabel,
                exportedURL: $exportedZipURL,
                onDismiss: { exportInProgress = false }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if events.isEmpty {
            emptyState
        } else {
            populatedContent
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No events yet", systemImage: "tray")
        } description: {
            Text("Import a folder of Tesla Sentry event exports to get started.")
        } actions: {
            Button("Import…") { showImportView = true }
                .buttonStyle(.borderedProminent)
        }
        .toolbar { EventsImportToolbar(showImportView: $showImportView) }
        .fileImporter(isPresented: $showImportView, allowedContentTypes: [.directory]) { result in
            EventsImportRunner.handle(result: result, modelContext: modelContext)
        }
    }

    // MARK: - Populated content

    /// Smart-filter bar is rendered above the list/empty-results pane so it
    /// stays visible (and tappable) when a chip filters to zero results —
    /// otherwise the user has no way to undo the filter.
    private var populatedContent: some View {
        VStack(spacing: 0) {
            EventsSmartFilterBar(state: filterState)
            if filteredEvents.isEmpty {
                ContentUnavailableView.search
            } else {
                listBody
            }
        }
        .searchable(text: $filterState.searchText, prompt: "Search city, plate, summary, name…")
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $showImportView, allowedContentTypes: [.directory]) { result in
            EventsImportRunner.handle(result: result, modelContext: modelContext)
        }
    }

    @ViewBuilder
    private var listBody: some View {
        if selection.isSelecting {
            List(selection: $selection.selectedIDs) { rows }
                .listStyle(.inset)
        } else {
            List { rows }
                .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(filteredEvents) { event in
            EventRow(event: event)
                .tag(event.persistentModelID)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !selection.isSelecting { path.append(event) }
                }
                .contextMenu { EventRowContextMenu(event: event) }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(selection.isSelecting ? "Done" : "Select") {
                if selection.isSelecting { selection.clear() }
                else { selection.isSelecting = true }
            }
        }
        #else
        ToolbarItem {
            Button(selection.isSelecting ? "Done selecting" : "Select") {
                if selection.isSelecting { selection.clear() }
                else { selection.isSelecting = true }
            }
        }
        #endif

        if selection.isSelecting && !selection.selectedIDs.isEmpty {
            ToolbarItem {
                Button {
                    runExport()
                } label: {
                    Label("Export selected (\(selection.selectedIDs.count))",
                          systemImage: "square.and.arrow.up.on.square")
                }
            }
        }

        EventsFilterMenu(
            favoritesOnly: $filterState.favoritesOnly,
            showArchived: $filterState.showArchived,
            tagFilter: $filterState.tagFilter,
            sortMode: $filterState.sortMode
        )
        EventsImportToolbar(showImportView: $showImportView)
    }

    // MARK: - Export

    private func runExport() {
        let selected = selection.resolveSelected(from: events)
        guard !selected.isEmpty else { return }
        exportProgress = 0
        exportLabel = "Preparing…"
        exportInProgress = true
        exportedZipURL = nil

        Task { @MainActor in
            do {
                let zipURL = try await EventExporter.export(
                    events: selected,
                    modelContext: modelContext,
                    progress: { p, label in
                        exportProgress = p
                        exportLabel = label
                    }
                )
                exportedZipURL = zipURL
                exportLabel = "Done"
            } catch {
                exportLabel = "Failed: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    EventsListView()
}

// MARK: - Cross-view navigation

/// NAV: action that pushes an Event onto the events-tab navigation stack.
struct OpenEventAction {
    var callback: (Event) -> Void
    func callAsFunction(_ event: Event) { callback(event) }
}

extension EnvironmentValues {
    @Entry var openEvent: OpenEventAction = OpenEventAction { _ in }
}
