//
//  EventsListSelection.swift
//  teslaDashcamViewer
//
//  Tiny holder for the multi-select state used by the events list.
//  Extracted so EventsListView doesn't grow another @State property.
//

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class EventsListSelection {
    /// PersistentIdentifier so the set survives the @Query refreshing models.
    var selectedIDs: Set<PersistentIdentifier> = []

    /// True when the list is in multi-select mode (iOS EditMode equivalent).
    var isSelecting: Bool = false

    func clear() {
        selectedIDs.removeAll()
        isSelecting = false
    }

    /// Resolve the selected ids to live Event objects, preserving order.
    func resolveSelected(from events: [Event]) -> [Event] {
        events.filter { selectedIDs.contains($0.persistentModelID) }
    }
}
