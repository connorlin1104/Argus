//
//  PlayerSheet.swift
//  Argus
//
//  Modal sheet that plays a single clip with a header bar. The video surface
//  uses the clip's native aspect ratio (4:3 on HW3 cars, ~3:2 on HW4) so
//  there are no black side-bars. A "Transfer to Events" button creates a new Event at the
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

    /// LAYOUT: iPhone landscape collapses verticalSizeClass to .compact.
    /// We use it to drop the header row and float a close button over the
    /// video so the card can be just the video surface (no empty band beneath).
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }
    #else
    private var isLandscape: Bool { false }
    #endif

    @State private var player: AVPlayer?
    /// Footage ratio measured from the clip's video track (4:3 on HW3 cars,
    /// ~3:2 on HW4). Starts at the fallback until the track loads.
    @State private var aspectRatio: CGFloat = VideoAspect.fallbackRatio
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
            if !isLandscape {
                header
            }
            playerSurface
                #if os(iOS)
                .overlay(alignment: .topTrailing) {
                    if isLandscape {
                        floatingCloseButton
                    }
                }
                #endif
        }
        #if os(macOS)
        // LAYOUT: wider sheet so the video has room to breathe on desktop.
        .frame(minWidth: 960, minHeight: 760)
        // UI: tap-to-dismiss covers any empty area around the video. Lives on
        // the VStack's background so the playerSurface gets all the vertical
        // slack (otherwise a sibling Color.clear would split the height and
        // shrink the video to ~half its potential size).
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
        )
        #endif
        .onAppear { setupPlayer() }
        .onDisappear { teardownPlayer() }
    }

    #if os(iOS)
    /// BUTTON: floating close button shown over the video when the header is
    /// hidden (iPhone landscape). Mirrors the header's close affordance but
    /// reads as a fullscreen-style chrome overlay rather than a UI strip.
    private var floatingCloseButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(.white, .black.opacity(0.45))
        }
        .buttonStyle(.plain)
        .padding(10)
    }
    #endif

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

    /// UI: video player at the clip's native ratio so no black side-bars.
    /// Uses a `Color.clear` sizer with `aspectRatio(.fit)` so the surface
    /// actually grows to fill the proposed space — `VideoPlayer` has no
    /// intrinsic size, so applying `aspectRatio` directly to it leaves the
    /// view tiny inside large containers.
    @ViewBuilder
    private var playerSurface: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ZStack {
                        Color.black
                        ProgressView().controlSize(.regular)
                    }
                }
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
        // Size the surface to the clip's real footage ratio (varies by
        // camera hardware generation).
        Task {
            if let ratio = await VideoAspect.ratio(of: url) {
                aspectRatio = ratio
            }
        }
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
