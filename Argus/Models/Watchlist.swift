//
//  Watchlist.swift
//  Argus
//
//  Plates the user wants flagged when they recur across events. Matched
//  against the plate reads stored on each event (Event.plateText) via
//  WatchlistMatcher.
//

import Foundation
import SwiftData

@Model
final class Watchlist {
    /// Raw plate text the user typed (case + punctuation preserved).
    var plateText: String = ""

    /// Free-form note shown in tooltip / settings list.
    var note: String = ""

    /// Hex color for the chip shown on matching events.
    var colorHex: String = "#FF3B30"

    init(plateText: String = "", note: String = "", colorHex: String = "#FF3B30") {
        self.plateText = plateText
        self.note = note
        self.colorHex = colorHex
    }
}
