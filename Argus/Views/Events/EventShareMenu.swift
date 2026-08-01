//
//  EventShareMenu.swift
//  Argus
//
//  Resolves the matched VideoRecording bookmarks into temp file URLs (via
//  EventFileVendor) so ShareLink and Quick Look can vend the clips to other
//  apps. The temp files persist for the rest of the session (so an in-flight
//  share is never broken) and are swept on the next app launch.
//

import SwiftUI
import SwiftData
import QuickLook

struct EventShareMenu: View {
    let event: Event

    /// Matched videos by timestamp overlap (same predicate EventDetailView uses).
    @Query private var matchedVideos: [VideoRecording]

    @State private var sharedURLs: [URL] = []
    @State private var quickLookURL: URL? = nil
    @State private var isResolving: Bool = false

    init(event: Event) {
        self.event = event
        let t = event.timestamp
        _matchedVideos = Query(
            filter: #Predicate<VideoRecording> { v in
                v.startTime <= t && v.endTime >= t
            }
        )
    }

    var body: some View {
        Menu {
            // BUTTON: stage clips, then open ShareLink-style share sheet
            Button {
                Task { await stage(); presentShare() }
            } label: {
                Label("Share clips…", systemImage: "square.and.arrow.up")
            }
            .disabled(matchedVideos.isEmpty || isResolving)

            // BUTTON: open the first matched clip in Quick Look
            Button {
                Task { await stage(); quickLookURL = sharedURLs.first }
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .disabled(matchedVideos.isEmpty || isResolving)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .quickLookPreview($quickLookURL)
    }

    @MainActor
    private func stage() async {
        guard sharedURLs.isEmpty else { return }
        isResolving = true
        defer { isResolving = false }
        let staging = EventFileVendor.makeStagingRoot(prefix: "event-share")
        var urls: [URL] = []
        for video in matchedVideos {
            if let url = try? EventFileVendor.vend(video: video, stagingRoot: staging) {
                urls.append(url)
            }
        }
        sharedURLs = urls
    }

    /// Programmatic ShareLink presentation — wraps the URLs in an
    /// AnyTransferable list so the system share sheet handles them.
    private func presentShare() {
        guard !sharedURLs.isEmpty else { return }
        #if canImport(AppKit)
        let picker = NSSharingServicePicker(items: sharedURLs as [Any])
        if let win = NSApp.keyWindow,
           let view = win.contentView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
        #else
        // On iOS the in-menu ShareLink is the conventional path; for the
        // programmatic flow we hand off to UIActivityViewController.
        let av = UIActivityViewController(activityItems: sharedURLs, applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .keyWindow?
            .rootViewController?
            .present(av, animated: true)
        #endif
    }
}
