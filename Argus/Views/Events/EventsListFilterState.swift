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

    // Filtering and sorting are translated into the events list's @Query
    // (see EventsListRoot.descriptor(for:fences:)) so they run store-side;
    // this type only holds the state the chips/menus bind to.
}
