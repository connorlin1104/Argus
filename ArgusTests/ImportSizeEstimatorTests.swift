//
//  ImportSizeEstimatorTests.swift
//  ArgusTests
//
//  The scope sheet's disk estimate must mirror the import's own date filter:
//  everything sums it all, ranges include only dated directories inside them,
//  and undated directories count toward EVERY option (the filter fails open,
//  so those folders always import).
//

import Foundation
import Testing
@testable import Argus

struct ImportSizeEstimatorTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func dir(daysAgo: Double?, bytes: Int64) -> ImportSizeEstimator.DirectorySize {
        ImportSizeEstimator.DirectorySize(
            date: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            bytes: bytes
        )
    }

    @Test func everythingSumsAllDirectories() {
        let sizes = [dir(daysAgo: 1, bytes: 100), dir(daysAgo: 40, bytes: 200),
                     dir(daysAgo: nil, bytes: 7)]
        #expect(ImportSizeEstimator.bytes(for: .everything, sizes: sizes, now: now) == 307)
    }

    @Test func lastDaysCountsOnlyTheWindow() {
        let sizes = [dir(daysAgo: 2, bytes: 100), dir(daysAgo: 6, bytes: 50),
                     dir(daysAgo: 40, bytes: 200)]
        #expect(ImportSizeEstimator.bytes(for: .lastDays(7), sizes: sizes, now: now) == 150)
        #expect(ImportSizeEstimator.bytes(for: .lastDays(30), sizes: sizes, now: now) == 150)
        #expect(ImportSizeEstimator.bytes(for: .lastDays(60), sizes: sizes, now: now) == 350)
    }

    @Test func undatedDirectoriesCountTowardEveryScope() {
        // Fail-open parity: a folder the filter can't date gets imported no
        // matter the scope, so the estimate must include it everywhere.
        let sizes = [dir(daysAgo: nil, bytes: 500), dir(daysAgo: 40, bytes: 200)]
        #expect(ImportSizeEstimator.bytes(for: .lastDays(7), sizes: sizes, now: now) == 500)
        #expect(ImportSizeEstimator.bytes(for: .everything, sizes: sizes, now: now) == 700)
    }

    @Test func customRangeMatchesTheDateFilterWindow() {
        let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-10 * 86_400))
        let scope = ImportScope.custom(start: day, end: day)
        let inside = ImportSizeEstimator.DirectorySize(
            date: day.addingTimeInterval(13 * 3600), bytes: 100)
        let outside = ImportSizeEstimator.DirectorySize(
            date: day.addingTimeInterval(-3600), bytes: 999)
        #expect(ImportSizeEstimator.bytes(for: scope, sizes: [inside, outside], now: now) == 100)
    }

    @Test func emptyFolderIsZero() {
        #expect(ImportSizeEstimator.bytes(for: .everything, sizes: [], now: now) == 0)
    }
}
