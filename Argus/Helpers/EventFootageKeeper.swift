//
//  EventFootageKeeper.swift
//  Argus
//
//  "Keep on device" per event. Import only references clips on the source
//  drive; this helper copies an event's covering clips into ClipStore when
//  the user (or an auto-keep rule: watchlist match, favoriting) decides the
//  footage matters, and deletes local copies again on Remove — but only
//  files no OTHER kept event's window still covers, because Tesla writes one
//  physical clip into every overlapping event folder.
//
//  See also: ClipStore.swift (storage), BookmarkResolver.swift (source
//  resolution incl. root fallback), EventClipMatcher.swift (window rule).
//

import Foundation
import SwiftData

enum EventFootageKeeper {

    enum KeepError: LocalizedError {
        /// No covering clip could be read from its source.
        case driveNotConnected
        case notEnoughSpace
        /// The event has no clip records at all — nothing to keep.
        case noFootage

        var errorDescription: String? {
            switch self {
            case .driveNotConnected:
                // TEXT: keep-failed alert (drive unplugged)
                return "The drive this event was imported from isn't connected. Plug it back in, then tap Keep on Device again."
            case .notEnoughSpace:
                // TEXT: keep-failed alert (disk full)
                return "There isn't enough free space on this device to save this event's footage. Free up some space and try again."
            case .noFootage:
                // TEXT: keep-failed alert (no clips)
                return "No imported clips cover this event, so there's nothing to save. Re-import the folder it came from first."
            }
        }
    }

    // MARK: - Keep

    /// Copy every clip covering the event into app storage and mark the
    /// event kept. Clips already copied are reused; the file copies run off
    /// the main actor (an event's footage can be gigabytes over USB). Throws
    /// when any clip can't be saved — copies that succeeded stay, so a retry
    /// after replugging finishes the remainder.
    @MainActor
    static func keep(event: Event, modelContext: ModelContext) async throws {
        let clips = coveringClips(for: event, modelContext: modelContext)
        guard !clips.isEmpty else { throw KeepError.noFootage }

        struct CopyJob: Sendable {
            let id: PersistentIdentifier
            let source: URL
        }
        var jobs: [CopyJob] = []
        var unresolvable = 0
        var pendingBytes: Int64 = 0
        for clip in clips where BookmarkResolver.localURL(fileName: clip.localFileName) == nil {
            guard let source = BookmarkResolver.resolveURL(for: clip) else {
                unresolvable += 1
                continue
            }
            jobs.append(CopyJob(id: clip.persistentModelID, source: source))
            pendingBytes += Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }

        if !jobs.isEmpty {
            guard ClipStore.hasSpace(for: pendingBytes) else { throw KeepError.notEnoughSpace }
            let copied: [(id: PersistentIdentifier, fileName: String)] =
                await Task.detached(priority: .userInitiated) {
                    var out: [(PersistentIdentifier, String)] = []
                    for job in jobs {
                        let didAccess = job.source.startAccessingSecurityScopedResource()
                        defer { if didAccess { job.source.stopAccessingSecurityScopedResource() } }
                        if let fileName = try? ClipStore.importCopy(from: job.source) {
                            out.append((job.id, fileName))
                        }
                    }
                    return out
                }.value
            for entry in copied {
                if let clip = modelContext.model(for: entry.id) as? VideoRecording {
                    clip.localFileName = entry.fileName
                }
            }
            unresolvable += jobs.count - copied.count
        }

        // Kept means kept: only flip the flag when every covering clip has a
        // local copy. Partial copies stay for the retry.
        if unresolvable > 0 {
            try? modelContext.save()
            throw KeepError.driveNotConnected
        }
        event.keptOnDevice = true
        try? modelContext.save()
    }

    // MARK: - Remove

    /// Unmark the event and delete local copies its clips no longer need.
    /// A clip's file survives when any OTHER kept event's window still covers
    /// it, or when another record shares the same stored file.
    @MainActor
    static func remove(event: Event, modelContext: ModelContext) {
        event.keptOnDevice = false
        try? modelContext.save()

        let keptTimestamps = keptEventTimestamps(modelContext: modelContext)
        for clip in coveringClips(for: event, modelContext: modelContext)
        where !clip.localFileName.isEmpty {
            guard !clipIsNeeded(clipStart: clip.startTime, clipEnd: clip.endTime,
                                keptTimestamps: keptTimestamps) else { continue }
            deleteLocalCopy(of: clip, modelContext: modelContext)
        }
        try? modelContext.save()
    }

    /// Pure delete-safety rule, extracted for tests: a local copy is still
    /// needed while any kept event's timestamp falls inside the clip's
    /// (tolerance-extended) window.
    static func clipIsNeeded(clipStart: Date, clipEnd: Date,
                             keptTimestamps: [Date]) -> Bool {
        keptTimestamps.contains {
            EventClipMatcher.covers(start: clipStart, end: clipEnd, timestamp: $0)
        }
    }

    /// Delete a clip's stored file and clear localFileName on every record
    /// sharing it (legacy path-deduped libraries can hold two rows for one
    /// physical clip). The rows themselves stay — they still reference the
    /// drive through their bookmarks.
    @MainActor
    private static func deleteLocalCopy(of clip: VideoRecording, modelContext: ModelContext) {
        let name = clip.localFileName
        guard !name.isEmpty else { return }
        let descriptor = FetchDescriptor<VideoRecording>(
            predicate: #Predicate<VideoRecording> { $0.localFileName == name }
        )
        for sharer in (try? modelContext.fetch(descriptor)) ?? [] {
            sharer.localFileName = ""
        }
        ClipStore.delete(fileName: name)
    }

    // MARK: - Cleanup (Settings)

    /// Local copies of clips no kept event needs — the reclaim candidates
    /// behind Settings' "Remove footage for unkept events".
    @MainActor
    static func unkeptLocalClips(modelContext: ModelContext) -> [VideoRecording] {
        let descriptor = FetchDescriptor<VideoRecording>(
            predicate: #Predicate<VideoRecording> { $0.localFileName != "" }
        )
        let localClips = (try? modelContext.fetch(descriptor)) ?? []
        guard !localClips.isEmpty else { return [] }
        let keptTimestamps = keptEventTimestamps(modelContext: modelContext)
        return localClips.filter {
            !clipIsNeeded(clipStart: $0.startTime, clipEnd: $0.endTime,
                          keptTimestamps: keptTimestamps)
        }
    }

    /// Delete every reclaim candidate's stored file. Returns how many files
    /// were removed.
    @MainActor
    @discardableResult
    static func removeUnkeptFootage(modelContext: ModelContext) -> Int {
        var removed = 0
        for clip in unkeptLocalClips(modelContext: modelContext)
        where !clip.localFileName.isEmpty {
            deleteLocalCopy(of: clip, modelContext: modelContext)
            removed += 1
        }
        try? modelContext.save()
        return removed
    }

    // MARK: - Backfill

    /// One-shot at launch (guarded by an AppStorage flag at the call site):
    /// libraries imported before reference-only shipped have every clip
    /// copied already — mark those events kept so Remove/cleanup semantics
    /// see them correctly. Nothing is ever deleted here.
    @MainActor
    static func backfillKeptFlags(modelContext: ModelContext) {
        let events = (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
        guard !events.isEmpty else { return }
        var descriptor = FetchDescriptor<VideoRecording>()
        descriptor.propertiesToFetch = [\.startTime, \.endTime, \.localFileName]
        let clips = (try? modelContext.fetch(descriptor)) ?? []
        let windows = clips.map { (start: $0.startTime, end: $0.endTime,
                                   hasLocalCopy: !$0.localFileName.isEmpty) }
        for event in events where shouldBackfillAsKept(
            eventTimestamp: event.timestamp, clipWindows: windows
        ) {
            event.keptOnDevice = true
        }
        try? modelContext.save()
    }

    /// Pure backfill rule, extracted for tests: kept when at least one clip
    /// covers the event and every covering clip has a local copy.
    static func shouldBackfillAsKept(
        eventTimestamp: Date,
        clipWindows: [(start: Date, end: Date, hasLocalCopy: Bool)]
    ) -> Bool {
        let covering = clipWindows.filter {
            EventClipMatcher.covers(start: $0.start, end: $0.end, timestamp: eventTimestamp)
        }
        return !covering.isEmpty && covering.allSatisfy(\.hasLocalCopy)
    }

    // MARK: - Sizing

    /// Bytes the event's footage occupies (kept) or would occupy (not kept),
    /// for the Keep button's caption. Unreadable sources (drive unplugged)
    /// contribute zero — the label shows what's knowable right now.
    @MainActor
    static func footageBytes(for event: Event, modelContext: ModelContext) -> Int64 {
        coveringClips(for: event, modelContext: modelContext).reduce(Int64(0)) { sum, clip in
            let url = BookmarkResolver.localURL(fileName: clip.localFileName)
                ?? BookmarkResolver.resolveURL(for: clip)
            guard let url else { return sum }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            return sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    // MARK: - Shared lookups

    /// Clips whose recording window covers the event's timestamp — the same
    /// rule the detail view, exporter, and deleter use.
    @MainActor
    static func coveringClips(for event: Event, modelContext: ModelContext) -> [VideoRecording] {
        let t = event.timestamp
        let cutoff = EventClipMatcher.earliestClipEnd(for: t)
        let descriptor = FetchDescriptor<VideoRecording>(
            predicate: #Predicate<VideoRecording> { v in
                v.startTime <= t && v.endTime >= cutoff
            }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    @MainActor
    private static func keptEventTimestamps(modelContext: ModelContext) -> [Date] {
        let descriptor = FetchDescriptor<Event>(
            predicate: #Predicate<Event> { $0.keptOnDevice == true }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.timestamp)
    }
}
