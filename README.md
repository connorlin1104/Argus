# Argus

A native macOS / iOS app for browsing Tesla Sentry & dashcam exports. Imports a USB drive's `SavedClips`/`SentryClips` folders, plays all four cameras in sync, runs on-device computer-vision analysis to surface noteworthy events, and writes plain-language summaries using Apple's on-device foundation model.

Built with SwiftUI, SwiftData, AVFoundation, Vision, MapKit, and (where available) the FoundationModels framework.

## Features

- **Multi-cam synchronized playback** — Front / Left / Right / Rear in a 2×2 grid driven by a single scrubber. Tap a tile to focus, scrub with `←` / `→` / `J` / `K` / `L`.
- **On-device event detection** — Vision is used to find humans, vehicles, and license-plate-shaped text on every 5th frame, with monocular distance estimates from the camera's known FOV.
- **Behavior tagging** — Each event is auto-tagged as Touched / Lingered / Approached / Passing / Vehicle / Noise based on how close someone came and how long they stayed.
- **AI summaries** — Short natural-language descriptions of each event using Apple Intelligence (`FoundationModels`) when available, with a deterministic fallback when not.
- **Geofenced zones** — Drop pins on a map to define Home / Work / etc. Events inside those zones are labeled automatically.
- **Map view** — All geo-tagged events plotted with color-coded markers per behavior.
- **Clip export (macOS)** — Save a ±5 s clip around the current scrubber position straight to disk.
- **Optional iCloud sync** — Events and geofences sync via CloudKit; videos stay local because security-scoped bookmarks aren't portable.

## Requirements

- Xcode 16 or newer
- macOS 14+ or iOS 17+
- AI summaries require macOS 26 / iOS 26 with Apple Intelligence enabled. Older OSes fall back to a deterministic summary string.

## Getting started

1. Clone the repo and open `Argus.xcodeproj` in Xcode.
2. Select the `Argus` scheme and a Mac / iOS destination.
3. Build & run.
4. On first launch, plug in your Tesla USB drive (or mount the export folder), tap **Import**, and pick the `SavedClips` or `SentryClips` directory.
5. Tap **Analyze all** in the Videos tab to run the Vision pipeline over every imported clip.

## Project layout

The codebase is intentionally broken into small files (every file ≤ 200 lines) so any single screen, control, or helper can be tweaked without scrolling through unrelated code.

```
Argus/
├── Helpers/
│   ├── Analyzer.swift                 # Observable VideoAnalyzer (progress state)
│   ├── DetectionEngine.swift          # Vision pipeline (humans / plates / vehicles)
│   ├── EventSummarizer.swift          # FoundationModels-backed text summaries
│   ├── Geocoder.swift                 # CLGeocoder reverse-geocode
│   ├── TeslaCamera.swift              # Camera ID normalization + FOV table
│   └── TeslaDashcamImporter.swift     # event.json + .mp4 importer
├── Models/
│   ├── Detection.swift                # Detection + DetectionSummary value types
│   ├── Event.swift                    # SwiftData @Model
│   ├── EventTag.swift                 # behavioral tag + classifier
│   ├── Geofence.swift                 # SwiftData @Model
│   └── VideoRecording.swift           # SwiftData @Model + detection markers
└── Views/
    ├── MainView.swift                 # root TabView
    ├── SettingsView.swift             # geofences, bulk ops, iCloud toggle
    ├── Events/
    │   ├── EventsListView.swift       # primary list (search/filter/sort)
    │   ├── EventsListToolbar.swift    # filter menu + import toolbar
    │   ├── EventsImport.swift         # file-importer plumbing
    │   ├── EventRow.swift             # one row in the list
    │   ├── EventChips.swift           # ZoneChip / TagChip / ScoreBadge
    │   ├── EventDetailView.swift      # detail screen composition
    │   ├── EventDetailSections.swift  # summary / metadata / notes sections
    │   └── EventsMapView.swift        # map of geo-tagged events
    ├── Videos/
    │   ├── VideoListView.swift        # grouped clip list + analyze button
    │   ├── VideoRow.swift             # clip row with thumbnail
    │   ├── VideoAnalysisRunner.swift  # batch detection loop
    │   ├── PlayerLayerView.swift      # raw AVPlayerLayer wrapper
    │   ├── PlayerSheet.swift          # single-clip modal player
    │   ├── VideoPlayerView.swift      # AVKit VideoPlayer wrapper
    │   ├── SyncedMultiCamPlayerView.swift              # multi-cam coordinator
    │   ├── SyncedMultiCamPlayerView+Tiles.swift        # grid + tiles UI
    │   ├── SyncedMultiCamPlayerView+Controls.swift     # scrubber + wall clock
    │   ├── SyncedMultiCamPlayerView+Playback.swift     # AVPlayer lifecycle
    │   └── SyncedMultiCamPlayerView+Export.swift       # ±5s clip export
    ├── Settings/
    │   ├── GeofencePickerSheet.swift  # add-zone modal
    │   └── SettingsBulkActions.swift  # recompute zones / dedupe helpers
    └── Style/
        ├── LiquidGlassStyle.swift     # liquidGlassChip / liquidGlassCard
        └── SectionCard.swift          # reusable titled card
```

## Searchable comment tags

Every view file uses short uppercase keyword comments so you can jump straight to whatever you want to tweak. Search the project for any of these:

| Keyword       | What it marks                                                                |
| ------------- | ---------------------------------------------------------------------------- |
| `UI:`         | A visible component (row, card, chip, badge, tile, etc.)                     |
| `LAYOUT:`     | Padding, spacing, frames, sizes — anything controlling position / dimensions |
| `COLOR:`      | A color choice — fills, tints, borders, foreground styles                    |
| `FONT:`       | Font size, weight, or family                                                 |
| `TEXT:`       | User-visible strings — change these to relabel things                        |
| `ICON:`       | SF Symbol choices                                                            |
| `BUTTON:`     | Tap targets and their actions                                                |
| `TUNING:`     | Adjustable thresholds, magic numbers, detection knobs                        |
| `PLAYBACK:`   | AVPlayer lifecycle / seek / play / pause                                     |

Examples:

- Want to rename the "Events" tab? Search `TEXT: change labels here`.
- Want to widen the multi-cam grid? Search `LAYOUT: Max width of the 2x2 grid`.
- Want a different badge color? Search `COLOR: marker tint per tag` or `COLOR:chip`.
- Want to tweak how sensitive the proximity detector is? Search `TUNING: lower = more sensitive`.

## Architecture notes

- **SwiftData stores split in two:** `MetadataStore` (Events + Geofences) is CloudKit-syncable, `VideosStore` is local-only because video URLs depend on security-scoped bookmarks. See `ArgusApp.swift`.
- **Multi-cam sync** uses one earliest-start *anchor* time + per-camera offsets. A periodic time observer on a "primary" camera (preferring Front) drives the shared scrubber position; seek translates the global position back to each camera's local time, clamping or pausing at boundaries.
- **Detection runs off-main** via `Task.detached(priority: .userInitiated)`, with the `VideoAnalyzer` `@Observable` class only holding the progress state on the main actor.
- **AI summaries** use `FoundationModels.SystemLanguageModel.default` when `.available`; otherwise they fall back to a deterministic concatenation of the facts that would have been sent to the model. No data leaves the device.
- **License plate filter** is intentionally conservative — 4–8 chars, uppercase alphanumeric, must contain both a digit and a letter. False positives from random text in scenes are common otherwise.

## Keyboard shortcuts (multi-cam player)

| Key       | Action            |
| --------- | ----------------- |
| Space / K | Play / Pause      |
| ←         | Back 5 s          |
| →         | Forward 5 s       |
| J         | Back 10 s         |
| L         | Forward 10 s      |

## Privacy

Everything — Vision detection, license-plate text recognition, and AI summaries — runs on-device. No frames, summaries, or coordinates ever leave the machine. Reverse geocoding goes through Apple's `CLGeocoder`, which is the only network call the app makes.

## License

This is a personal project. No license is currently provided. All rights are reserved unless specified otherwise in the future.
