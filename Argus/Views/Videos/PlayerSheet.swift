//
//  PlayerSheet.swift
//  Argus
//
//  Modal sheet that plays a single clip with a header bar. The video surface
//  uses the Tesla dashcam's native 4:3 aspect ratio so there are no black
//  side-bars. A "Transfer to Events" button creates a new Event at the
//  current playback time — for cases where the user finds something the
//  automatic Sentry trigger missed.
//
//  Used by VideoListView when the user taps a row.
//  Search keywords: UI:player-sheet, BUTTON:close-sheet, BUTTON:transfer-event, LAYOUT:sheet
//

import SwiftUI
import SwiftData
import AVKit

/// Sheet that plays a single clip. Header shows the filename, a transfer-to-events
/// button, and a close button.
struct PlayerSheet: View {
    let video: VideoRecording
    let onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var player: AVPlayer?
    @State private var resolvedURL: URL?
    @State private var didAccess: Bool = false
    @State private var transferState: TransferState = .idle

    private enum TransferState: Equatable {
        case idle
        case success
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            playerSurface
            Spacer(minLength: 0)
        }
        #if os(macOS)
        // LAYOUT: wider sheet so the 4:3 video has room to breathe on desktop.
        .frame(minWidth: 960, minHeight: 760)
        #endif
        .onAppear { setupPlayer() }
        .onDisappear { teardownPlayer() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // TEXT: filename in monospaced caption
            Text(video.url.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            transferButton

            // BUTTON: close sheet
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill") // ICON: close
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        // LAYOUT: header padding
        .padding(12)
    }

    /// BUTTON: copy the current playback moment into the Events tab as a new event.
    @ViewBuilder
    private var transferButton: some View {
        Button {
            transferToEvents()
        } label: {
            switch transferState {
            case .idle:
                Label("Transfer to Events", systemImage: "tray.and.arrow.down.fill")
            case .success:
                Label("Added to Events", systemImage: "checkmark.circle.fill")
            case .failed:
                Label("Transfer failed", systemImage: "exclamationmark.triangle.fill")
            }
        }
        .controlSize(.regular)
        .disabled(player == nil || transferState == .success)
        .help("Create a new event at the current playback time")
    }

    // MARK: - Player surface

    /// UI: video player at Tesla's native 4:3 ratio so no black side-bars.
    @ViewBuilder
    private var playerSurface: some View {
        if let player {
            VideoPlayer(player: player)
                // LAYOUT: 4:3 matches the Tesla dashcam recording.
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
        } else {
            ZStack {
                Color.black
                ProgressView().controlSize(.regular)
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
        }
    }

    // MARK: - Playback setup / teardown

    private func setupPlayer() {
        guard player == nil, let url = resolveBookmark() else { return }
        didAccess = url.startAccessingSecurityScopedResource()
        guard didAccess else {
            print("Failed to access security-scoped resource for URL: \(url)")
            return
        }
        resolvedURL = url
        let p = AVPlayer(url: url)
        player = p
        // PLAYBACK: auto-play on appearance
        p.play()
    }

    private func teardownPlayer() {
        player?.pause()
        player = nil
        if didAccess, let resolvedURL {
            resolvedURL.stopAccessingSecurityScopedResource()
        }
        didAccess = false
        resolvedURL = nil
    }

    // MARK: - Transfer to events

    /// Create a new Event timestamped at the current playback position and
    /// insert it into the SwiftData store. The Events tab's `@Query` will
    /// pick it up automatically.
    ///
    /// VideoRecording doesn't carry GPS, so we borrow city / lat / lon /
    /// address from the nearest already-imported Tesla event within an hour
    /// of this video — that's almost always the same drive, and it lets the
    /// "Look up" button in the details card actually resolve to a street.
    private func transferToEvents() {
        guard let player else {
            transferState = .failed
            return
        }
        let elapsed = player.currentTime().seconds
        let safeElapsed = (elapsed.isFinite && elapsed >= 0) ? elapsed : 0
        let eventTime = video.startTime.addingTimeInterval(safeElapsed)

        let neighbor = nearestEventWithGPS(to: eventTime)

        let event = Event(
            source: "Manual",
            camera: video.camera,
            city: neighbor?.city ?? "",
            estLatitude: neighbor?.estLatitude ?? "",
            estLongitude: neighbor?.estLongitude ?? "",
            reason: "manual_transfer",
            timestamp: eventTime
        )
        // Address isn't an init parameter — copy it after construction.
        if let addr = neighbor?.address, !addr.isEmpty {
            event.address = addr
        }
        modelContext.insert(event)
        do {
            try modelContext.save()
            transferState = .success
        } catch {
            print("PlayerSheet: failed to save manual event — \(error)")
            transferState = .failed
        }
    }

    /// Find the closest already-imported event (by timestamp) that has a real
    /// GPS fix. Returns nil if no neighbor exists within the time window.
    /// TUNING: the 1-hour window keeps us on the same drive without pulling
    /// location from an unrelated trip earlier in the day.
    private func nearestEventWithGPS(
        to date: Date,
        within seconds: TimeInterval = 3600
    ) -> Event? {
        let descriptor = FetchDescriptor<Event>(
            predicate: #Predicate<Event> { event in
                event.estLatitude != "" &&
                event.estLongitude != "" &&
                event.estLatitude != "0" &&
                event.estLongitude != "0"
            }
        )
        guard let candidates = try? modelContext.fetch(descriptor) else { return nil }
        return candidates
            .filter { abs($0.timestamp.timeIntervalSince(date)) <= seconds }
            .min {
                abs($0.timestamp.timeIntervalSince(date)) <
                abs($1.timestamp.timeIntervalSince(date))
            }
    }

    // MARK: - Bookmark resolution

    private func resolveBookmark() -> URL? {
        do {
            var isStale = false
            #if os(iOS)
            return try URL(resolvingBookmarkData: video.bookmark, bookmarkDataIsStale: &isStale)
            #else
            return try URL(resolvingBookmarkData: video.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            #endif
        } catch {
            print("PlayerSheet: bookmark resolution error — \(error)")
            return nil
        }
    }
}
