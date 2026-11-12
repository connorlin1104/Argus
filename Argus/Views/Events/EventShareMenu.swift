//
//  EventShareMenu.swift
//  Argus
//
//  Resolves the matched VideoRecording bookmarks into temp file URLs (via
//  EventFileVendor) so ShareLink and Quick Look can vend the clips to other
//  apps. The temp files persist for the rest of the session (so an in-flight
//  share is never broken) and are swept on the next app launch.
//
//  Lifetime gotcha: this view is rendered inside menus (row context menu,
//  detail toolbar), and menu content is torn down the moment the menu
//  dismisses — which is BEFORE any button's Task runs. @State written after
//  dismissal is lost, so every action passes its results forward directly,
//  and Quick Look presentation is owned by the host view via a binding.
//

import SwiftUI
import SwiftData
import QuickLook
import UniformTypeIdentifiers

struct EventShareMenu: View {
    let event: Event

    /// Owned by the hosting view (which outlives the menu) — it attaches
    /// `.quickLookPreview` to itself. Presenting from inside dismissed menu
    /// content silently does nothing.
    @Binding var quickLookURL: URL?

    /// Matched videos by timestamp overlap (same predicate EventDetailView uses).
    @Query private var matchedVideos: [VideoRecording]
    /// Whole watchlist — the evidence report's watchlist callout matches
    /// against it.
    @Query private var watchlist: [Watchlist]

    init(event: Event, quickLookURL: Binding<URL?>) {
        self.event = event
        _quickLookURL = quickLookURL
        let t = event.timestamp
        let cutoff = EventClipMatcher.earliestClipEnd(for: t)
        _matchedVideos = Query(
            filter: #Predicate<VideoRecording> { v in
                v.startTime <= t && v.endTime >= cutoff
            }
        )
    }

    var body: some View {
        Menu {
            // BUTTON: stage clips, then open the system share sheet
            Button {
                Task { presentShare(urls: await stageClips()) }
            } label: {
                Label("Share clips…", systemImage: "square.and.arrow.up")
            }
            .disabled(matchedVideos.isEmpty)

            // BUTTON: generate the Evidence Package PDF and share just it.
            // Not gated on matched clips — a report with map + metadata and
            // no stills is still useful.
            Button {
                Task { await shareReport() }
            } label: {
                Label("Share report…", systemImage: "doc.richtext")
            }

            #if os(macOS)
            // The macOS share sheet has no save-to-disk service (unlike iOS's
            // Save to Files), so without these the only way to get files out
            // locally was a Messages round-trip to yourself.
            Divider()

            // BUTTON: copy the event's clip files into a user-chosen folder.
            Button {
                Task { await saveClips() }
            } label: {
                Label("Save clips to folder…", systemImage: "folder")
            }
            .disabled(matchedVideos.isEmpty)

            // BUTTON: write the Evidence Package PDF straight to disk via a
            // save panel.
            Button {
                Task { await saveReport() }
            } label: {
                Label("Save report as PDF…", systemImage: "square.and.arrow.down")
            }

            Divider()
            #endif

            // BUTTON: open the first matched clip in Quick Look
            Button {
                Task { quickLookURL = await stageClips().first }
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .disabled(matchedVideos.isEmpty)
        } label: {
            // TEXT: menu title. Shows as text + chevron inside context menus,
            // collapses to the icon in toolbars.
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    /// Stages the matched clips into session-lifetime temp files and returns
    /// their URLs directly (no @State round-trip — see lifetime gotcha above).
    @MainActor
    private func stageClips() async -> [URL] {
        let staging = EventFileVendor.makeStagingRoot(prefix: "event-share")
        var urls: [URL] = []
        for video in matchedVideos {
            do {
                urls.append(try EventFileVendor.vend(video: video, stagingRoot: staging))
            } catch {
                print("EventShareMenu: couldn't stage \(video.url.lastPathComponent): \(error)")
            }
        }
        return urls
    }

    /// Generate the Evidence Package PDF into session-lifetime staging
    /// (swept on next launch, like shared clips) and hand it to the share
    /// sheet. Regenerated per share so edits to name/notes/summary between
    /// shares are reflected.
    @MainActor
    private func shareReport() async {
        let staging = EventFileVendor.makeStagingRoot(prefix: "event-share")
        let dest = staging.appendingPathComponent(
            EvidencePackageRenderer.pdfFileName(for: event))
        do {
            try await EvidencePackageRenderer.writePDF(
                event: event,
                videos: matchedVideos,
                watchlist: watchlist,
                to: dest
            )
            presentShare(urls: [dest])
        } catch {
            print("EventShareMenu: evidence report failed: \(error)")
        }
    }

    #if os(macOS)
    /// Copy the matched clip files into a folder the user picks. The open
    /// panel's grant covers the chosen directory, so vend can write there.
    @MainActor
    private func saveClips() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Clips"
        panel.message = "Choose a folder for this event's clips."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for video in matchedVideos {
            do {
                _ = try EventFileVendor.vend(video: video, stagingRoot: dir)
            } catch {
                print("EventShareMenu: couldn't save \(video.url.lastPathComponent): \(error)")
            }
        }
    }

    /// Generate the Evidence Package PDF directly at a user-chosen location.
    @MainActor
    private func saveReport() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = EvidencePackageRenderer.pdfFileName(for: event)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        do {
            try await EvidencePackageRenderer.writePDF(
                event: event,
                videos: matchedVideos,
                watchlist: watchlist,
                to: dest
            )
        } catch {
            print("EventShareMenu: evidence report save failed: \(error)")
        }
    }
    #endif

    /// Programmatic ShareLink presentation — wraps the URLs in an
    /// AnyTransferable list so the system share sheet handles them.
    private func presentShare(urls: [URL]) {
        guard !urls.isEmpty else { return }
        #if canImport(AppKit)
        let picker = NSSharingServicePicker(items: urls as [Any])
        if let win = NSApp.keyWindow,
           let view = win.contentView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
        #else
        // On iOS the in-menu ShareLink is the conventional path; for the
        // programmatic flow we hand off to UIActivityViewController.
        let av = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .keyWindow?
            .rootViewController?
            .present(av, animated: true)
        #endif
    }
}
