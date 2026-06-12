//
//  EventTripSection.swift
//  Argus
//
//  Small card on EventDetailView that shows the trip this event belongs to
//  and the sibling events in the same trip. Uses the \.openEvent
//  environment action to push siblings onto the events-tab nav stack.
//

import SwiftUI
import SwiftData

struct EventTripSection: View {
    let event: Event

    @Environment(\.openEvent) private var openEvent
    @Query(sort: [SortDescriptor(\Event.timestamp, order: .forward)])
    private var allEvents: [Event]

    private var siblings: [Event] {
        guard let tripID = event.tripID else { return [] }
        return allEvents.filter { $0.tripID == tripID }
    }

    private var meta: TripGrouper.TripMetadata? {
        guard let tripID = event.tripID else { return nil }
        return TripGrouper.metadata(forTrip: tripID, in: allEvents)
    }

    var body: some View {
        if event.tripID != nil, let meta {
            SectionCard(title: "Trip", symbol: "road.lanes") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline(meta: meta))
                        .font(.headline)
                    Text(subtitle(meta: meta))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if siblings.count > 1 {
                        Divider().padding(.vertical, 2)
                        ForEach(siblings) { sibling in
                            siblingRow(sibling, isCurrent: sibling.id == event.id)
                        }
                    }
                }
            }
        }
    }

    private func headline(meta: TripGrouper.TripMetadata) -> String {
        let day = meta.start.formatted(date: .abbreviated, time: .omitted)
        return "Drive on \(day)"
    }

    private func subtitle(meta: TripGrouper.TripMetadata) -> String {
        let start = meta.start.formatted(date: .omitted, time: .shortened)
        let end = meta.end.formatted(date: .omitted, time: .shortened)
        let km = meta.distanceMeters / 1000
        let dist = km >= 1 ? String(format: "%.1f km", km) : String(format: "%.0f m", meta.distanceMeters)
        return "\(start) – \(end) · \(meta.count) events · \(dist)"
    }

    @ViewBuilder
    private func siblingRow(_ sibling: Event, isCurrent: Bool) -> some View {
        Button {
            guard !isCurrent else { return }
            openEvent(sibling)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                Text(sibling.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.callout.monospacedDigit())
                Text(EventSummarizer.humanizeReason(sibling.reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }
}
