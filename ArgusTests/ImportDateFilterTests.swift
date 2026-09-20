//
//  ImportDateFilterTests.swift
//  ArgusTests
//
//  The date-range wizard must be fast-path (folder names only), inclusive on
//  custom-range edges, and above all FAIL-OPEN: a filter that silently drops
//  real events because a folder is named oddly would look like data loss.
//

import Foundation
import Testing
@testable import Argus

struct ImportDateFilterTests {

    /// Fixed "now" so lastDays windows don't drift with wall-clock time.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Directory URL with a Tesla-style name derived from a date, matching
    /// the formatter the filter parses with (avoids time-zone surprises).
    private func directory(daysAgo: Double) -> URL {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = df.string(from: now.addingTimeInterval(-daysAgo * 86_400))
        return URL(fileURLWithPath: "/tmp/does-not-exist/\(name)")
    }

    // MARK: - Folder-name parsing

    @Test func parsesTeslaFolderNames() {
        let date = ImportDateFilter.folderDate("2026-09-13_17-02-10")
        #expect(date != nil)
        // Suffixes after the timestamp (Tesla never adds one, but be safe).
        #expect(ImportDateFilter.folderDate("2026-09-13_17-02-10_extra") != nil)
    }

    @Test func rejectsMalformedNames() {
        #expect(ImportDateFilter.folderDate("SentryClips") == nil)
        #expect(ImportDateFilter.folderDate("") == nil)
        #expect(ImportDateFilter.folderDate("2026-13-45_99-99-99") == nil)
        #expect(ImportDateFilter.folderDate("2026-09-13") == nil) // too short
    }

    // MARK: - Scope filtering

    @Test func everythingImportsEverything() {
        #expect(ImportDateFilter.shouldImport(
            directory: directory(daysAgo: 400), scope: .everything, now: now))
        #expect(ImportDateFilter.shouldImport(
            directory: URL(fileURLWithPath: "/tmp/does-not-exist/junk"),
            scope: .everything, now: now))
    }

    @Test func lastDaysKeepsRecentDropsOld() {
        let scope = ImportScope.lastDays(7)
        #expect(ImportDateFilter.shouldImport(
            directory: directory(daysAgo: 2), scope: scope, now: now))
        #expect(!ImportDateFilter.shouldImport(
            directory: directory(daysAgo: 40), scope: scope, now: now))
    }

    @Test func customRangeIsInclusiveByWholeDays() {
        // Range = the single day 10 days ago; an event that evening counts.
        let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-10 * 86_400))
        let scope = ImportScope.custom(start: day, end: day)
        let range = ImportDateFilter.dateRange(for: scope, now: now)
        #expect(range != nil)
        #expect(range!.contains(day.addingTimeInterval(23 * 3600)))
        #expect(!range!.contains(day.addingTimeInterval(-1)))
        #expect(!range!.contains(day.addingTimeInterval(25 * 3600)))
    }

    // MARK: - Fail-open

    @Test func unparseableDirectoryFailsOpen() {
        // No date in the name, no event.json on disk → must import anyway.
        let dir = URL(fileURLWithPath: "/tmp/does-not-exist/USB-DRIVE")
        #expect(ImportDateFilter.shouldImport(
            directory: dir, scope: .lastDays(7), now: now))
    }

    // MARK: - Finish-banner wording

    @MainActor
    @Test func cancelledImportKeepsPartialsInTheMessage() {
        let feedback = ImportFeedback()
        var tally = ImportTally()
        tally.insertedEvents = 12
        feedback.finish(tally: tally, cancelled: true)
        #expect(feedback.isImporting == false)
        #expect(feedback.message?.contains("kept 12 events") == true)
    }

    @MainActor
    @Test func dateFilteredEmptyFolderExplainsTheRange() {
        let feedback = ImportFeedback()
        feedback.finish(tally: ImportTally(), skippedByDateFilter: 30)
        #expect(feedback.message?.contains("date range") == true)
    }
}
