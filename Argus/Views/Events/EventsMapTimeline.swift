//
//  EventsMapTimeline.swift
//  Argus
//
//  The Timeline toggle's bottom card on the Map tab: an activity histogram
//  spanning the whole library plus a two-thumb range slider. The map shows
//  only pins inside the selected window, so dragging the right thumb forward
//  replays how events accumulated over time.
//  Search keywords: UI:map-timeline, TEXT:map-timeline, TUNING:map-timeline
//

import SwiftUI

// MARK: - Window

/// The date range the map is narrowed to. Inclusive on both ends.
struct TimelineWindow: Equatable {
    var start: Date
    var end: Date

    func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }
}

// MARK: - Histogram

enum TimelineHistogram {
    /// Buckets `dates` into `count` equal slices of `span`. Dates on the
    /// span's edges land in the first/last bucket; anything outside the span
    /// is clamped in rather than dropped, so the total always matches.
    static func buckets(dates: [Date], span: ClosedRange<Date>, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var buckets = [Int](repeating: 0, count: count)
        let total = span.upperBound.timeIntervalSince(span.lowerBound)
        for date in dates {
            let index: Int
            if total <= 0 {
                index = 0
            } else {
                let fraction = date.timeIntervalSince(span.lowerBound) / total
                index = min(max(Int(fraction * Double(count)), 0), count - 1)
            }
            buckets[index] += 1
        }
        return buckets
    }
}

// MARK: - Card

/// UI: glass card shown in the map's bottom safe-area inset while the
/// Timeline toggle is on.
struct EventsMapTimelineCard: View {
    /// Every located event, unfiltered — the histogram always shows the whole
    /// library so activity clusters stay visible while scrubbing.
    let events: [Event]
    /// How many events the current window lets through (drives the label).
    let visibleCount: Int
    @Binding var window: TimelineWindow

    /// TUNING: histogram resolution — more buckets = finer activity detail.
    private static let bucketCount = 60

    private var span: ClosedRange<Date> {
        let stamps = events.map(\.timestamp)
        let lower = stamps.min() ?? window.start
        let upper = max(stamps.max() ?? window.end, lower)
        return lower...upper
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                // TEXT: selected range, e.g. "Sep 3 – Sep 12"
                Text(rangeLabel)
                    .font(.subheadline.weight(.medium))
                Spacer()
                // TEXT: live count — never blank, even with zero events (2.1a)
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            histogram
            TimelineRangeSlider(window: $window, span: span)
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 14)
    }

    private var rangeLabel: String {
        let calendar = Calendar.current
        // Show years only when the span crosses one — "Sep 3 – Sep 12" reads
        // better than "Sep 3, 2026 – Sep 12, 2026" for the common case.
        var style = Date.FormatStyle().month(.abbreviated).day()
        if calendar.component(.year, from: span.lowerBound)
            != calendar.component(.year, from: span.upperBound) {
            style = style.year()
        }
        return "\(window.start.formatted(style)) – \(window.end.formatted(style))"
    }

    private var countLabel: String {
        if visibleCount == 0 { return "No events in this range" }
        return visibleCount == 1 ? "1 event" : "\(visibleCount) events"
    }

    private var histogram: some View {
        let counts = TimelineHistogram.buckets(
            dates: events.map(\.timestamp),
            span: span,
            count: Self.bucketCount
        )
        let peak = max(counts.max() ?? 1, 1)
        let total = span.upperBound.timeIntervalSince(span.lowerBound)
        return HStack(alignment: .bottom, spacing: 1) {
            ForEach(counts.indices, id: \.self) { index in
                let bucketMid = span.lowerBound.addingTimeInterval(
                    total * (Double(index) + 0.5) / Double(Self.bucketCount)
                )
                RoundedRectangle(cornerRadius: 1)
                    // COLOR: buckets inside the window highlight in accent.
                    .fill(window.contains(bucketMid)
                          ? AnyShapeStyle(Color.accentColor)
                          : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    // LAYOUT: 2pt floor keeps empty buckets visible as a baseline.
                    .frame(height: 2 + 26 * Double(counts[index]) / Double(peak))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 28, alignment: .bottom)
    }
}

// MARK: - Range slider

/// Two-thumb slider over `span`. SwiftUI has no native range slider, so this
/// is a track + two drag-gesture thumbs. Thumbs snap to day boundaries when
/// the library spans more than a few days.
private struct TimelineRangeSlider: View {
    @Binding var window: TimelineWindow
    let span: ClosedRange<Date>

    private var total: TimeInterval {
        span.upperBound.timeIntervalSince(span.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: max(x(of: window.end, width: width) - x(of: window.start, width: width), 4),
                        height: 4
                    )
                    .offset(x: x(of: window.start, width: width))
                thumb
                    .position(x: x(of: window.start, width: width), y: geo.size.height / 2)
                    .gesture(dragGesture(width: width, movesEnd: false))
                thumb
                    .position(x: x(of: window.end, width: width), y: geo.size.height / 2)
                    .gesture(dragGesture(width: width, movesEnd: true))
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
        }
        // LAYOUT: slider row height — also the thumbs' touch target height.
        .frame(height: 36)
    }

    private var thumb: some View {
        Circle()
            .fill(.white)
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
            .shadow(radius: 2)
            // Touch target padded past the visible circle.
            .frame(width: 40, height: 40)
            .contentShape(Circle())
    }

    private func x(of date: Date, width: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let fraction = date.timeIntervalSince(span.lowerBound) / total
        return CGFloat(min(max(fraction, 0), 1)) * width
    }

    private func date(atX x: CGFloat, width: CGFloat) -> Date {
        guard total > 0, width > 0 else { return span.lowerBound }
        let fraction = min(max(Double(x / width), 0), 1)
        return span.lowerBound.addingTimeInterval(fraction * total)
    }

    private func dragGesture(width: CGFloat, movesEnd: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let raw = date(atX: value.location.x, width: width)
                let snapped = snap(raw, isEnd: movesEnd)
                if movesEnd {
                    window.end = max(snapped, window.start)
                } else {
                    window.start = min(snapped, window.end)
                }
            }
    }

    /// Left thumb snaps to the start of a day, right thumb to the end of one,
    /// so a window naturally covers whole days.
    private func snap(_ date: Date, isEnd: Bool) -> Date {
        // TUNING: below this span, day-snapping would make the thumbs jumpy —
        // scrub continuously instead.
        guard total > 3 * 86_400 else { return date }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let snapped: Date
        if isEnd {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
            snapped = nextDay.addingTimeInterval(-1)
        } else {
            snapped = dayStart
        }
        return min(max(snapped, span.lowerBound), span.upperBound)
    }
}
