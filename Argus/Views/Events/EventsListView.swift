//
//  EventsListView.swift
//  Argus
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

    /// Needed by the At Home / At Work smart-filter chips so they can map
    /// the user's zone names to the icon family the user picked.
    @Query(sort: \Geofence.name) private var fences: [Geofence]

    // === Extracted state ===
    @State private var filterState = EventsListFilterState()
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

    // === Navigation ===
    /// NAV: typed path for the events tab. Push events with `path.append(event)`.
    @State private var path: [Event] = []

    // === Rename (long-press context menu) ===
    /// UI: event currently being renamed via the row long-press / right-click menu.
    /// Drives the rename alert below.
    @State private var renamingEvent: Event? = nil
    @State private var renameDraft: String = ""

    // MARK: - Filter pipeline

    var filteredEvents: [Event] {
        filterState.apply(to: events, fences: fences)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Events")
                #if os(macOS)
                .navigationSubtitle(events.isEmpty
                    ? ""
                    : "\(filteredEvents.count) of \(events.count)")
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

    @ViewBuilder
    private var content: some View {
        if events.isEmpty {
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
        if !events.isEmpty {
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
