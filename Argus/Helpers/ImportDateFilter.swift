//
//  ImportDateFilter.swift
//  Argus
//
//  Decides which event directories an import should read, based on the date
//  range the user picked in ImportScopeSheet. Cheap by design: the folder
//  name (`2026-09-13_17-02-10`) is checked first, then the tiny event.json —
//  clips in skipped directories are never probed or copied, which is the
//  entire point on a months-deep SSD.
//
//  Search keywords: IMPORT:date-filter, TUNING:import-scope
//

import Foundation

/// Import window chosen in ImportScopeSheet before a folder import starts.
enum ImportScope: Equatable {
    case everything
    case lastDays(Int)
    case custom(start: Date, end: Date)
}

enum ImportDateFilter {

    /// Whether this event directory falls inside the scope. Folder-name date
    /// first, event.json timestamp as fallback — and FAIL-OPEN when neither
    /// parses: a date filter must never silently drop real events just
    /// because a folder is named unexpectedly.
    static func shouldImport(directory: URL, scope: ImportScope, now: Date = Date()) -> Bool {
        guard let range = dateRange(for: scope, now: now) else { return true }
        guard let date = folderDate(directory.lastPathComponent)
                ?? eventJSONDate(in: directory) else {
            return true
        }
        return range.contains(date)
    }

    /// Concrete date window for a scope; nil means "no filtering".
    static func dateRange(for scope: ImportScope, now: Date = Date()) -> ClosedRange<Date>? {
        switch scope {
        case .everything:
            return nil
        case .lastDays(let days):
            return now.addingTimeInterval(-Double(days) * 86_400) ... .distantFuture
        case .custom(let start, let end):
            // Whole-day inclusive on both ends: picking Sep 13 – Sep 13
            // means "everything that day", not an empty instant.
            let calendar = Calendar.current
            let dayStart = calendar.startOfDay(for: start)
            let dayEnd = calendar.date(byAdding: .day, value: 1,
                                       to: calendar.startOfDay(for: end)) ?? end
            return dayStart ... max(dayStart, dayEnd)
        }
    }

    /// Parse the `yyyy-MM-dd_HH-mm-ss` prefix Tesla uses for event folder
    /// names (same shape as clip filenames, see parseFilename).
    static func folderDate(_ name: String, timeZone: TimeZone = .current) -> Date? {
        guard name.count >= 19 else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return df.date(from: String(name.prefix(19)))
    }

    /// Fallback: read the timestamp out of the directory's event.json.
    /// Same size guard as the importer — never load an absurd file.
    private static func eventJSONDate(in directory: URL) -> Date? {
        let url = directory.appendingPathComponent("event.json")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 1_000_000 {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = dict["timestamp"] as? String else {
            return nil
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df.date(from: timestamp)
    }
}
