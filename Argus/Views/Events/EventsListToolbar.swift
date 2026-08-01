//
//  EventsListToolbar.swift
//  Argus
//
//  Toolbar content + row context menu for EventsListView.
//  Search keywords: UI:events-toolbar, BUTTON:events-toolbar
//

import SwiftUI
import SwiftData

/// Right-click / long-press menu on a row: favorite / rename / archive / share / delete.
/// Rename is wired through a closure so the parent can drive an alert with a
/// TextField — context menus can't host inline text editing themselves.
struct EventRowContextMenu: View {
    @Environment(\.modelContext) private var modelContext
    let event: Event
    var onRename: (() -> Void)? = nil

    var body: some View {
        // BUTTON: favorite toggle (context menu)
        Button {
            event.isFavorite.toggle()
        } label: {
            Label(event.isFavorite ? "Unfavorite" : "Favorite",
                  systemImage: event.isFavorite ? "star.slash" : "star")
        }
        // BUTTON: rename (context menu) — parent presents the rename alert.
        if let onRename {
            Button {
                onRename()
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
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
/// Both platforms lead with the folder picker. On iOS a few USB / SD storage
/// providers don't surface an "Open" affordance in the folder picker, so the
/// menu keeps a multi-file fallback ("Select All" works on every provider).
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
                    Label("Import Folder…", systemImage: "folder")
                }
                Button {
                    showImportFilesView = true
                } label: {
                    Label("Select Files…", systemImage: "doc.on.doc")
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
