# Argus Roadmap

Prioritized outline for upcoming releases. Each tier gets expanded into a
concrete implementation plan (files to touch, data flow, tests) when we
start it — this document is the ordering, not the design.

Status: 1.1 uploaded to the App Store (Nov 2026). Bug fixes below ship in 1.2.

## Tier 0 — Ship-blockers (target: 1.2)

1. **Lock-mid-scan silent partial scans** — a mid-scan screen lock quietly
   produces half-analyzed videos. Check `reader.status` after the read loop
   and add an idle timer so a stalled scan surfaces as an error instead of
   a silent partial result.
2. **Frozen playback past 1:00** — playback freezes past the one-minute
   mark. No reliable repro yet; first task is capturing a console log of
   the freeze, then fix.

Exit criteria: both fixed and verified → 1.2 submission.

## Tier 1 — Evidence Package export (headline feature, target: 1.3)

A polished PDF per event, bundled alongside the existing clips zip:

- Mini-map snapshot, AI summary, key video stills (closest-approach frame,
  plate frames), timestamps/address/metadata, watchlist match callout.
- Builds almost entirely on existing pieces: `EventExporter`,
  `EventSummarizer`, detection data, `EventMiniMapSection`.
- The concrete "hand this to police/insurance" use case.

Open questions for the detailed plan:
- PDF generation approach (SwiftUI `ImageRenderer` vs. Core Graphics).
- How to auto-pick the stills worth including.
- Single-event vs. batch export.
- iOS share-sheet story.

## Tier 2 — Smarter detection (the moat)

3. **Behavior classification** — rule layer over existing bbox trajectories
   (approach → dwell → retreat) for more meaningful tags than
   touched/lingered/passing. No new ML needed initially.
4. **Person/vehicle re-identification** — "same person appeared 3× this
   week" via Vision feature prints: appearance clustering, explicitly not
   facial identification. Needs a feasibility spike before committing.

## Tier 3 — Proactivity & reach

5. **Notifications / weekly digest** — local notification on watchlist
   match or high-score event; LLM-generated weekly rollup of notable
   events.
6. **iOS gap closing** — multi-cam grid playback and clip export parity
   (both currently macOS-only).

## Tier 4 — Smaller wins (slot in anywhere)

- Natural-language search over AI summaries.
- Detected-path trajectory overlay on video playback.
- Harden `ImportFollowUpScheduler` / `IncompleteEventDetector`
  (stranded-event recovery is fragile per code comments).
- Manual event creation from arbitrary footage.
