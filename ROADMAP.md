# Argus Roadmap

Prioritized outline for upcoming releases. Each tier gets expanded into a
concrete implementation plan (files to touch, data flow, tests) when we
start it — this document is the ordering, not the design.

Status: 1.1 approved and released (Nov 2026). 1.2 (Tier 0 fixes + Evidence
Package) reached TestFlight and passed its phone verification round on
Nov 17, 2026. That round produced a small UX fix batch (Quick Look clip
choice, export progress/confirmation, player loading overlay, plates
wording) that goes into the next build — then 1.2 is ready for App Store
review. Only known untested path: the detached-drive export warning.

## Tier 0 — Bug fixes (shipped in 1.2)

1. **Lock-mid-scan silent partial scans** — DONE, verified on device
   Nov 17. Interrupted decodes are flagged via `reader.status`, never
   persisted, retried once at batch end; idle timer disabled while
   scanning.
2. **Frozen playback past 1:00** — DONE, verified on device Nov 17. The
   stitcher sets `item.videoComposition` on cross-file compositions
   (FigFilePlayer -12860 workaround) and logs creation failures loudly.

## Tier 1 — Evidence Package export (shipped in 1.2)

DONE, verified on macOS and iPhone. Every exported event folder includes
`evidence-report.pdf` beside `event.json`: print-styled report with map
snapshot, AI summary, marker-picked video stills with captions, metadata
table, watchlist callout, and possible plate reads grouped by similarity.
Per-event share menu offers Share clips / Share report / Quick Look, plus
macOS save-to-disk actions. Rendered via SwiftUI `ImageRenderer` into a
vector CGContext PDF; stills picked from persisted detection markers
(`EventStillPicker`, unit-tested); PDF failures never fail the export.

Next up (decided Nov 2026): natural-language search over AI summaries
(Tier 4) before starting Tier 2.

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
