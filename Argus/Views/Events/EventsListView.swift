//
//  EventsListView.swift
//  Argus
//
//  The primary list of imported Sentry events. Handles search, smart-filter
//  chips, multi-select, import, and navigation into EventDetailView.
//
//  Structure: the thin outer EventsListView owns the filter state and
//  rebuilds EventsListRoot whenever a filter changes. The root's @Query is
//  constructed in init from that filter snapshot, so archived/favorites/tag/
//  week/zone filtering and sorting all run in the SwiftData store instead of
//  fetching every event and filtering in memory. Only free-text search stays
//  in-memory (EventSearchMatcher spans fields a #Predicate can't express).
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
    @State private var filterState = EventsListFilterState()

    /// Needed by the At Home / At Work smart-filter chips so they can map
    /// the user's zone names to the icon family the user picked.
    @Query(sort: \Geofence.name) private var fences: [Geofence]

    var body: some View {
        // Reading filterState inside EventsListRoot.init is tracked by this
        // body, so any filter change re-creates the root with a fresh query.
        EventsListRoot(filterState: filterState, fences: fences)
    }
}

private struct EventsListRoot: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var filterState: EventsListFilterState

    /// Filter + sort applied store-side; see descriptor(for:fences:).
    @Query private var events: [Event]

    /// fetchLimit-1 probe used only to distinguish "no events imported yet"
    /// (hero import UI) from "current filter matches nothing".
    @Query private var anyEvent: [Event]

    // === Extracted state ===
    @State private var selection = EventsListSelection()
    /// macOS folder picker. iOS dropped the folder option entirely: the system
    /// folder picker doesn't surface an "Open" affordance for USB / SD storage
    /// providers, so the multi-file picker (with Select All) is both more
    /// reliable and just as fast.
    #if os(macOS)
    @State private var showImportView: Bool = false
    #endif
    #if os(iOS)
    @State private var showImportFilesView: Bool = false
    #endif

    // === Export state ===
    @State private var exportInProgress: Bool = false
    @State private var exportProgress: Double = 0
    @State private var exportLabel: String = ""
    @State private var exportedZipURL: URL? = nil
    /// Non-nil when the finished zip is missing clips (unplugged drive etc.);
    /// shown as a warning on the success pane.
    @State private var exportWarning: String? = nil

    // === Navigation ===
    /// NAV: typed path for the events tab. Push events with `path.append(event)`.
    @State private var path: [Event] = []

    // === Rename (long-press context menu) ===
    /// UI: event currently being renamed via the row long-press / right-click menu.
    /// Drives the rename alert below.
    @State private var renamingEvent: Event? = nil
    @State private var renameDraft: String = ""

    init(filterState: EventsListFilterState, fences: [Geofence]) {
        self.filterState = filterState
        _events = Query(Self.descriptor(for: filterState, fences: fences))
        var probe = FetchDescriptor<Event>()
        probe.fetchLimit = 1
        _anyEvent = Query(probe)
    }

    // MARK: - Query construction

    /// Translate the filter state into a store-side fetch. Comparisons that
    /// don't involve the model are precomputed into flags so the #Predicate
    /// body only contains model-field expressions SwiftData can translate.
    private static func descriptor(
        for state: EventsListFilterState,
        fences: [Geofence]
    ) -> FetchDescriptor<Event> {
        let showArchived = state.showArchived
        let favoritesOnly = state.favoritesOnly || state.smartFilter == .starred
        let tagFilter = state.tagFilter
        let anyTag = tagFilter == "all"
        let cutoff: Date = state.smartFilter == .thisWeek
            ? Date().addingTimeInterval(-7 * 24 * 60 * 60)
            : .distantPast

        // At Home / At Work match by the icon family of the fence, not the
        // literal zone name, so "Dad's house" with the house icon still
        // falls under "At Home".
        var zoneNames: [String] = []
        var inZoneNames = false
        var outsideZoneOnly = false
        switch state.smartFilter {
        case .atHome:
            zoneNames = Array(GeofenceCategory.homeZoneNames(in: fences))
            inZoneNames = true
        case .atWork:
            zoneNames = Array(GeofenceCategory.workZoneNames(in: fences))
            inZoneNames = true
        case .outsideZone:
            outsideZoneOnly = true
        case .all, .starred, .thisWeek:
            break
        }

        let predicate = #Predicate<Event> { event in
            (showArchived || !event.isArchived)
            && (!favoritesOnly || event.isFavorite)
            && (anyTag || event.tag == tagFilter)
            && event.timestamp >= cutoff
            && (!inZoneNames || zoneNames.contains(event.zone))
            // `== ""` rather than .isEmpty — SwiftData mistranslates .isEmpty
            // on stored strings and the clause silently matches nothing.
            && (!outsideZoneOnly || event.zone == "")
        }

        let sort: [SortDescriptor<Event>]
        switch state.sortMode {
        case .newest:
            sort = [SortDescriptor(\Event.timestamp, order: .reverse)]
        case .oldest:
            sort = [SortDescriptor(\Event.timestamp, order: .forward)]
        case .score:
            sort = [SortDescriptor(\Event.interestingnessScore, order: .reverse),
                    SortDescriptor(\Event.timestamp, order: .reverse)]
        }
        return FetchDescriptor<Event>(predicate: predicate, sortBy: sort)
    }

    // MARK: - Filter pipeline

    /// Free-text search over the already query-filtered set. This is the only
    /// remaining in-memory pass.
    var filteredEvents: [Event] {
        guard !filterState.searchText.isEmpty else { return events }
        return events.filter { EventSearchMatcher.matches(event: $0, query: filterState.searchText) }
    }

    private var hasAnyEvents: Bool { !anyEvent.isEmpty }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Events")
                #if os(macOS)
                .navigationSubtitle(hasAnyEvents
                    ? "\(filteredEvents.count) of \(totalEventCount)"
                    : "")
                #endif
                .navigationDestination(for: Event.self) { event in
                    EventDetailView(event: event)
                }
                // LAYOUT: Apply the same modifiers in both states so the
                // navigation bar reserves identical space — otherwise the
                // search-bar height delta makes the tab bar appear shifted
                // between empty and populated states.
                .searchable(text: $filterState.searchText, prompt: "Search city, plate, summary, name…")
                .toolbar { toolbarContent }
                #if os(macOS)
                .fileImporter(isPresented: $showImportView, allowedContentTypes: [.directory]) { result in
                    EventsImportRunner.handle(result: result, modelContext: modelContext)
                }
                #endif
                #if os(iOS)
                .fileImporter(
                    isPresented: $showImportFilesView,
                    allowedContentTypes: [.movie, .json],
                    allowsMultipleSelection: true
                ) { result in
                    EventsImportRunner.handleFiles(result: result, modelContext: modelContext)
                }
                #endif
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
                warning: $exportWarning,
                onDismiss: { exportInProgress = false }
            )
        }
        .alert("Rename event", isPresented: Binding(
            get: { renamingEvent != nil },
            set: { if !$0 { renamingEvent = nil } }
        )) {
            TextField("Name this event", text: $renameDraft)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingEvent = nil }
        }
    }

    #if os(macOS)
    /// Total row count for the "X of Y" subtitle. A COUNT query — cheap even
    /// on big libraries, and re-evaluated whenever the filtered query updates.
    private var totalEventCount: Int {
        (try? modelContext.fetchCount(FetchDescriptor<Event>())) ?? 0
    }
    #endif

    @ViewBuilder
    private var content: some View {
        if !hasAnyEvents {
            emptyState
        } else {
            populatedContent
        }
    }

    // MARK: - Empty state

    /// Hero layout shown when no events have been imported. Larger artwork
    /// and a prominent primary action — the top-right toolbar import button
    /// is too small to discover on first launch.
    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("No events yet")
                .font(.largeTitle.bold())
            Text("Drop in a Tesla Sentry folder from your USB drive. We'll pull every clip, location, and trigger reason in automatically.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
            #if os(iOS)
            // BUTTON: empty-state import (iOS) — opens the multi-file picker.
            // The system folder picker doesn't surface an "Open" affordance
            // for USB / SD providers, so we standardize on the file picker
            // (Select All works on every provider).
            Button {
                showImportFilesView = true
            } label: {
                Label("Import Sentry footage", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)
            Text("Open your event folder, tap Select All, and pick both event.json and the .mp4 clips. Both are required — event.json carries the metadata, the .mp4s are the footage.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            #else
            Button {
                showImportView = true
            } label: {
                Label("Import Sentry folder", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)
            Text("You can also tap the import icon in the top-right corner anytime.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            #endif
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Populated content

    /// Smart-filter bar is rendered above the list/empty-results pane so it
    /// stays visible (and tappable) when a chip filters to zero results —
    /// otherwise the user has no way to undo the filter. The empty-results
    /// pane is stretched to .infinity so the chip bar stays pinned at the
    /// top (matching List's greedy fill); without that, the VStack
    /// shrink-wraps and the chips drift toward the screen's center.
    private var populatedContent: some View {
        VStack(spacing: 0) {
            EventsSmartFilterBar(state: filterState)
            if filteredEvents.isEmpty {
                ContentUnavailableView.search
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listBody
            }
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
                .contextMenu {
                    EventRowContextMenu(event: event, onRename: { beginRename(event) })
                }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if hasAnyEvents {
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
        }
        #if os(iOS)
        EventsImportToolbar(showImportFilesView: $showImportFilesView)
        #else
        EventsImportToolbar(showImportView: $showImportView)
        #endif
    }

    // MARK: - Rename

    /// Pre-fills the draft with the current display name so users edit from a
    /// familiar baseline, then opens the rename alert.
    private func beginRename(_ event: Event) {
        let original = event.reason.isEmpty ? "" : EventSummarizer.humanizeReason(event.reason)
        renameDraft = event.customName.isEmpty ? original : event.customName
        renamingEvent = event
    }

    /// Treat blank or "matches the auto-generated label" as "no custom name"
    /// so we don't shadow future humanizeReason changes with a frozen copy.
    private func commitRename() {
        guard let event = renamingEvent else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = event.reason.isEmpty ? "" : EventSummarizer.humanizeReason(event.reason)
        event.customName = (trimmed.isEmpty || trimmed == original) ? "" : trimmed
        renamingEvent = nil
    }

    // MARK: - Export

    private func runExport() {
        let selected = selection.resolveSelected(from: events)
        guard !selected.isEmpty else { return }
        exportProgress = 0
        exportLabel = "Preparing…"
        exportInProgress = true
        exportedZipURL = nil
        exportWarning = nil

        Task { @MainActor in
            do {
                let result = try await EventExporter.export(
                    events: selected,
                    modelContext: modelContext,
                    progress: { p, label in
                        exportProgress = p
                        exportLabel = label
                    }
                )
                if !result.skippedClips.isEmpty {
                    let n = result.skippedClips.count
                    exportWarning = "\(n) file\(n == 1 ? "" : "s") couldn't be read and \(n == 1 ? "is" : "are") missing from the zip — is the source drive still connected? Missing: \(result.skippedClips.joined(separator: ", "))"
                }
                exportedZipURL = result.zipURL
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
