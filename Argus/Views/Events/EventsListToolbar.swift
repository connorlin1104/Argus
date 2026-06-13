//
//  EventsListToolbar.swift
//  Argus
//
//  Toolbar content + row context menu for EventsListView.
//  Search keywords: UI:events-toolbar, BUTTON:events-toolbar
//

import SwiftUI
import SwiftData

/// Right-click menu on a row: favorite / archive / share / delete.
struct EventRowContextMenu: View {
    @Environment(\.modelContext) private var modelContext
    let event: Event

    var body: some View {
        // BUTTON: favorite toggle (context menu)
        Button {
            event.isFavorite.toggle()
        } label: {
            Label(event.isFavorite ? "Unfavorite" : "Favorite",
                  systemImage: event.isFavorite ? "star.slash" : "star")
        }
        // BUTTON: archive toggle (context menu)
        Button {
            event.isArchived.toggle()
        } label: {
            Label(event.isArchived ? "Unarchive" : "Archive",
                  systemImage: event.isArchived ? "tray.and.arrow.up" : "archivebox")
        }
        Divider()
        // BUTTON: share / quick-look via EventShareMenu
        EventShareMenu(event: event)
        Divider()
        // BUTTON: delete (context menu)
        Button(role: .destructive) {
            modelContext.delete(event)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// The "filter funnel" menu in the navigation bar.
struct EventsFilterMenu: ToolbarContent {
    @Binding var favoritesOnly: Bool
    @Binding var showArchived: Bool
    @Binding var tagFilter: String
    @Binding var sortMode: EventsListFilterState.SortMode

    var body: some ToolbarContent {
        // BUTTON: filter menu (funnel icon)
        ToolbarItem {
            Menu {
                // TEXT: filter menu items
                Toggle("Favorites only", isOn: $favoritesOnly)
                Toggle("Show archived", isOn: $showArchived)
                Picker("Tag", selection: $tagFilter) {
                    Text("All").tag("all")
                    // TEXT: tag options — keep in sync with TagChip switch
                    ForEach(["touched", "lingered", "approached", "passing", "vehicle", "noise", "unknown"], id: \.self) { t in
                        Text(t.capitalized).tag(t)
                    }
                }
                Picker("Sort by", selection: $sortMode) {
                    ForEach(EventsListFilterState.SortMode.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

/// "Import" button used on both the empty state and the populated list.
///
/// On iOS the toolbar item is a menu: the system folder picker doesn't
/// surface an "Open" affordance for all storage providers (e.g. USB / SD
/// readers), so we offer an "Import individual files" fallback alongside it.
/// macOS keeps the single folder-picker button since its picker works.
struct EventsImportToolbar: ToolbarContent {
    @Binding var showImportView: Bool
    #if os(iOS)
    @Binding var showImportFilesView: Bool
    #endif

    var body: some ToolbarContent {
        // BUTTON: import (top-right cloud-arrow icon)
        ToolbarItem {
            #if os(iOS)
            Menu {
                Button {
                    showImportView = true
                } label: {
                    Label("Import folder…", systemImage: "folder")
                }
                Button {
                    showImportFilesView = true
                } label: {
                    Label("Import individual files…", systemImage: "doc.on.doc")
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            #else
            Button {
                showImportView = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            #endif
        }
    }
}
