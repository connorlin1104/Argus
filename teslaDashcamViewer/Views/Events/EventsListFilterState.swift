//
//  EventsListFilterState.swift
//  teslaDashcamViewer
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

    /// Apply every filter and sort to the @Query results. `fences` powers
    /// the At Home / At Work chips — those match by the icon family of the
    /// matching fence, not the literal zone name, so "Dad's house" with
    /// the house icon still falls under "At Home".
    func apply(to events: [Event], fences: [Geofence] = []) -> [Event] {
        var result = events
        if !showArchived       { result = result.filter { !$0.isArchived } }
        if favoritesOnly       { result = result.filter { $0.isFavorite } }
        if tagFilter != "all"  { result = result.filter { $0.tag == tagFilter } }
        result = applySmartFilter(result, fences: fences)
        if !searchText.isEmpty {
            result = result.filter { EventSearchMatcher.matches(event: $0, query: searchText) }
        }
        switch sortMode {
        case .newest: result.sort { $0.timestamp > $1.timestamp }
        case .oldest: result.sort { $0.timestamp < $1.timestamp }
        case .score:  result.sort { $0.interestingnessScore > $1.interestingnessScore }
        }
        return result
    }

    private func applySmartFilter(_ events: [Event], fences: [Geofence]) -> [Event] {
        switch smartFilter {
        case .all:         return events
        case .starred:     return events.filter { $0.isFavorite }
        case .thisWeek:
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            return events.filter { $0.timestamp >= cutoff }
        case .atHome:
            let names = GeofenceCategory.homeZoneNames(in: fences)
            return events.filter { names.contains($0.zone) }
        case .atWork:
            let names = GeofenceCategory.workZoneNames(in: fences)
            return events.filter { names.contains($0.zone) }
        case .outsideZone: return events.filter { $0.zone.isEmpty }
        }
    }
}
