//
//  GeofenceStyle.swift
//  Argus
//
//  Resolves a zone name → display color + SF Symbol. Single source of
//  truth for hex-string decoding so the chip / row / map all agree.
//

import SwiftUI

enum GeofenceStyle {

    /// Returns the color the user assigned to the named zone, or nil if no
    /// matching geofence exists (callers fall back to their own default).
    static func color(forZone zone: String, in fences: [Geofence]) -> Color? {
        guard !zone.isEmpty, let fence = fences.first(where: { $0.name == zone }) else {
            return nil
        }
        return color(hex: fence.colorHex)
    }

    /// SF Symbol the user picked for the named zone, or nil if no match.
    static func symbol(forZone zone: String, in fences: [Geofence]) -> String? {
        guard !zone.isEmpty, let fence = fences.first(where: { $0.name == zone }) else {
            return nil
        }
        return fence.iconSymbol.isEmpty ? nil : fence.iconSymbol
    }

    /// Decode `#RRGGBB` or `#RRGGBBAA` strings into SwiftUI Color.
    static func color(hex: String) -> Color? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6 || raw.count == 8, let int = UInt64(raw, radix: 16) else {
            return nil
        }
        let r, g, b, a: Double
        if raw.count == 8 {
            r = Double((int >> 24) & 0xFF) / 255.0
            g = Double((int >> 16) & 0xFF) / 255.0
            b = Double((int >> 8)  & 0xFF) / 255.0
            a = Double(int & 0xFF) / 255.0
        } else {
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8)  & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            a = 1.0
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Encode a SwiftUI Color into `#RRGGBB`. Falls back to "#34C759" if the
    /// platform refuses to give us sRGB components.
    static func hex(from color: Color) -> String {
        #if canImport(AppKit)
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemGreen
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
        #elseif canImport(UIKit)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        #else
        return "#34C759"
        #endif
    }

    /// Small static SF Symbol palette the picker uses.
    static let symbolPalette: [String] = [
        "house.fill", "briefcase.fill", "cart.fill", "fork.knife", "graduationcap.fill",
        "heart.fill", "star.fill", "mappin.and.ellipse", "building.2.fill", "figure.run"
    ]

    /// Friendly display name shown for each palette symbol. Hides the raw
    /// SF Symbol id (e.g. "house.fill") from users in pickers.
    static func displayName(for symbol: String) -> String {
        switch symbol {
        case "house.fill":         return "House"
        case "briefcase.fill":     return "Briefcase"
        case "cart.fill":          return "Shopping"
        case "fork.knife":         return "Restaurant"
        case "graduationcap.fill": return "School"
        case "heart.fill":         return "Heart"
        case "star.fill":          return "Star"
        case "mappin.and.ellipse": return "Pin"
        case "building.2.fill":    return "Building"
        case "figure.run":         return "Running"
        default:                   return symbol.capitalized
        }
    }
}

/// Maps each geofence's chosen SF Symbol into a semantic category. Used by
/// the smart-filter chip bar so "At Home" / "At Work" can match a user's
/// zones by intent (the icon they picked) rather than by literal name.
enum GeofenceCategory {
    /// Icons the user picks for residence-like zones.
    static let homeSymbols: Set<String> = ["house.fill", "heart.fill"]

    /// Icons the user picks for workplace / school / office zones.
    static let workSymbols: Set<String> = [
        "briefcase.fill", "graduationcap.fill", "building.2.fill"
    ]

    static func isHomeLike(_ fence: Geofence) -> Bool {
        homeSymbols.contains(fence.iconSymbol)
    }

    static func isWorkLike(_ fence: Geofence) -> Bool {
        workSymbols.contains(fence.iconSymbol)
    }

    /// Names of every fence whose icon belongs to the home-like group.
    static func homeZoneNames(in fences: [Geofence]) -> Set<String> {
        Set(fences.filter(isHomeLike).map(\.name))
    }

    /// Names of every fence whose icon belongs to the work-like group.
    static func workZoneNames(in fences: [Geofence]) -> Set<String> {
        Set(fences.filter(isWorkLike).map(\.name))
    }
}
