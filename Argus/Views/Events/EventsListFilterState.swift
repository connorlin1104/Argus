//
//  EventsListFilterState.swift
//  Argus
//
//  Owns the events-list filter/sort state extracted from EventsListView so
//  the view stays a thin shell. Smart filter chips + free-text search +
//  tag/sort/favorites/archive all live here.
//

import Foundation
import Observation
import SwiftData

/// Which prebuilt smart-filter chip is active, if any.
enum SmartFilter: String, CaseIterable, Identifiable {
    case all, starred, thisWeek, atHome, atWork, outsideZone
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:         return "All"
        case .starred:     return "Starred"
        case .thisWeek:    return "This Week"
        case .atHome:      return "At Home"
        case .atWork:      return "At Work"
        case .outsideZone: return "Outside Zone"
        }
    }

    var symbol: String {
        switch self {
        case .all:         return "tray.full"
        case .starred:     return "star.fill"
        case .thisWeek:    return "calendar"
        case .atHome:      return "house.fill"
        case .atWork:      return "briefcase.fill"
        case .outsideZone: return "map"
        }
    }
}

@Observable
@MainActor
final class EventsListFilterState {
    var searchText: String = ""
    var tagFilter: String = "all"
    var sortMode: SortMode = .newest
    var favoritesOnly: Bool = false
    var showArchived: Bool = false
    var smartFilter: SmartFilter = .all

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

    // === AI search (EventNLSearcher) ===
    // Set when the user presses Return in the search field; cleared on any
    // text edit. INVARIANT: these may be read only in EventsListRoot's BODY,
    // never in its init/descriptor — reading them there would re-create the
    // root (and its @Query) on every mutation, tearing the world out from
    // under the in-flight search task.

    /// Ranked result IDs. nil = keyword mode; [] = AI search ran, no matches.
    var aiResultIDs: [PersistentIdentifier]? = nil
    /// Query the current AI results belong to (shown in the banner).
    var aiQuery: String = ""
    var aiIsSearching: Bool = false
    /// Unavailability notice for the banner (Apple Intelligence off).
    var aiNotice: String? = nil

    func clearAISearch() {
        aiResultIDs = nil
        aiQuery = ""
        aiIsSearching = false
        aiNotice = nil
    }

    // Filtering and sorting are translated into the events list's @Query
    // (see EventsListRoot.descriptor(for:fences:)) so they run store-side;
    // this type only holds the state the chips/menus bind to.
}
