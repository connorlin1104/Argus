//
//  SyncedMultiCamPlayerView+Controls.swift
//  Argus
//
//  Transport bar (play/pause/scrubber/time/export), wall-clock badge,
//  invisible keyboard shortcut layer, and detection-marker rendering.
//  Search keywords: UI:transport, UI:scrubber, UI:wall-clock, BUTTON:play
//

import SwiftUI
import AVFoundation

extension SyncedMultiCamPlayerView {

    // MARK: - Wall clock badge

    /// UI: floating wall-clock badge that shows the real-world capture time
    /// (anchor date + current playback position).
    /// TEXT: change formatters here to relabel the badge.
    var wallClockBadge: some View {
        let now = anchor.addingTimeInterval(positionSeconds)
        let dateString = now.formatted(date: .abbreviated, time: .omitted)
        let timeStringValue = now.formatted(date: .omitted, time: .standard)
        return VStack(spacing: 0) {
            // FONT: monospaced HH:MM:SS, change size/weight here
            Text(timeStringValue)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
            Text(dateString)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // COLOR: thin material capsule background
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
        .allowsHitTesting(false)
    }

    // MARK: - Transport bar

    /// UI: bottom transport bar with play/pause, scrubber, time readout, and export.
    /// LAYOUT: padding + glass card defined at the end of the body block here.
    @ViewBuilder
    var controlBar: some View {
        HStack(spacing: 12) {
            // BUTTON: play/pause toggle
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])

            // UI: scrubber + marker overlay
            ZStack(alignment: .top) {
                Slider(
                    value: $positionSeconds,
                    in: 0...max(totalDuration, 0.1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            // PLAYBACK: snap each player to the current thumb
                            // position right away so the very first drag tick
                            // shows the right frame.
                            scrubSeekAll(to: positionSeconds)
                        } else {
                            // PLAYBACK: precise final seek + resume playback
                            // if we were playing before the drag started.
                            seekAll(to: positionSeconds)
                        }
                    }
                )
                // PLAYBACK: drive frame updates in real time while the user
                // drags. The slider's `onEditingChanged` only fires at the
                // start/end of the gesture; this onChange fires for every
                // intermediate value so the video tracks the thumb.
                .onChange(of: positionSeconds) { _, newValue in
                    if isScrubbing { scrubSeekAll(to: newValue) }
                }
                GeometryReader { geo in
                    ForEach(allMarkers, id: \.self) { marker in
                        let fraction = totalDuration > 0 ? marker.eventSeconds / totalDuration : 0
                        Rectangle()
                            // COLOR: marker tick color depends on kind
                            .fill(markerColor(marker.kind))
                            // LAYOUT: marker tick width/height
                            .frame(width: 2, height: 8)
                            .offset(x: CGFloat(fraction) * geo.size.width, y: -2)
                    }
                }
                .frame(height: 8)
                .allowsHitTesting(false)
            }

            // TEXT: "current / total" time readout, e.g. "0:42 / 1:00"
            Text(timeString(positionSeconds) + " / " + timeString(totalDuration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            #if os(macOS)
            // BUTTON: ±5s export (macOS only)
            Button {
                Task { await exportCurrentClip() }
            } label: {
                Label("Export ±5s", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .help("Export a 10-second clip around the current position")
            .disabled(isExporting)
            #endif
        }
        // LAYOUT: transport bar inner padding. No outer horizontal padding —
        // the parent constrains width so this card matches the video feed above.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlassCard(cornerRadius: 14)
    }

    // MARK: - Keyboard shortcuts

    /// Invisible buttons that wire keyboard shortcuts to playback actions.
    /// J/K/L mirror video-editor conventions; ←/→ scrub by 5 s.
    var keyboardShortcutLayer: some View {
        ZStack {
            Button("") { seekRelative(-5) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { seekRelative(5) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { seekRelative(-10) }.keyboardShortcut("j", modifiers: [])
            Button("") { togglePlay() }.keyboardShortcut("k", modifiers: [])
            Button("") { seekRelative(10) }.keyboardShortcut("l", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    func seekRelative(_ delta: Double) {
        let target = min(max(0, positionSeconds + delta), totalDuration)
        positionSeconds = target
        seekAll(to: target)
    }

    /// Formats seconds as `M:SS` for the time readout.
    func timeString(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Detection markers

    /// One detection marker (one tick on the scrubber).
    struct EventMarker: Hashable {
        let kind: String
        let eventSeconds: Double
    }

    /// All detection markers across all camera tracks, mapped to global timeline seconds.
    var allMarkers: [EventMarker] {
        var out: [EventMarker] = []
        for video in videos {
            let offset = offsets[video.camera] ?? video.startTime.timeIntervalSince(anchor)
            for m in video.markers {
                out.append(EventMarker(
                    kind: m.kind,
                    eventSeconds: offset + Double(m.timestampMs) / 1000.0
                ))
            }
        }
        return out
    }

    /// COLOR: marker tick color per detection kind.
    func markerColor(_ kind: String) -> Color {
        switch kind {
        case "human": return .red
        case "vehicle": return .purple
        case "licensePlate": return .blue
        default: return .yellow
        }
    }
}
