//
//  EventsListView.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import SwiftUI
import SwiftData

struct EventsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        sort: [
            SortDescriptor(\Event.timestamp, order: .reverse)
        ]
    ) private var events: [Event]
    @State private var showImportView: Bool = false
    @State private var searchText: String = ""
    @State private var tagFilter: String = "all"
    @State private var sortMode: SortMode = .newest
    @State private var favoritesOnly: Bool = false
    @State private var showArchived: Bool = false

    enum SortMode: String, CaseIterable, Identifiable {
        case newest, oldest, score
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            case .score:  return "Highest score"
            }
        }
    }

    var filteredEvents: [Event] {
        var result = events
        if !showArchived {
            result = result.filter { !$0.isArchived }
        }
        if favoritesOnly {
            result = result.filter { $0.isFavorite }
        }
        if tagFilter != "all" {
            result = result.filter { $0.tag == tagFilter }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { e in
                e.city.lowercased().contains(q) ||
                e.reason.lowercased().contains(q) ||
                e.zone.lowercased().contains(q) ||
                e.summary.lowercased().contains(q) ||
                e.address.lowercased().contains(q) ||
                e.tag.lowercased().contains(q) ||
                e.camera.lowercased().contains(q) ||
                e.notes.lowercased().contains(q)
            }
        }
        switch sortMode {
        case .newest: result.sort { $0.timestamp > $1.timestamp }
        case .oldest: result.sort { $0.timestamp < $1.timestamp }
        case .score:  result.sort { $0.interestingnessScore > $1.interestingnessScore }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Events")
                #if os(macOS)
                .navigationSubtitle("\(filteredEvents.count) of \(events.count)")
                #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if events.isEmpty {
            emptyState
        } else if filteredEvents.isEmpty {
            ContentUnavailableView.search
                .toolbar { importToolbar }
                .searchable(text: $searchText, prompt: "Search events")
        } else {
            eventList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No events yet", systemImage: "tray")
        } description: {
            Text("Import a folder of Tesla Sentry event exports to get started.")
        } actions: {
            Button("Import…") { showImportView = true }
                .buttonStyle(.borderedProminent)
        }
        .toolbar { importToolbar }
        .fileImporter(isPresented: $showImportView, allowedContentTypes: [.directory]) { result in
            handleImport(result: result)
        }
    }

    private var eventList: some View {
        List {
            ForEach(filteredEvents) { event in
                NavigationLink {
                    EventDetailView(event: event)
                } label: {
                    EventRow(event: event)
                }
                .contextMenu {
                    Button {
                        event.isFavorite.toggle()
                    } label: {
                        Label(event.isFavorite ? "Unfavorite" : "Favorite",
                              systemImage: event.isFavorite ? "star.slash" : "star")
                    }
                    Button {
                        event.isArchived.toggle()
                    } label: {
                        Label(event.isArchived ? "Unarchive" : "Archive",
                              systemImage: event.isArchived ? "tray.and.arrow.up" : "archivebox")
                    }
                    Button(role: .destructive) {
                        modelContext.delete(event)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $searchText, prompt: "Search city, reason, plate, summary…")
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
#endif
            ToolbarItem {
                Menu {
                    Toggle("Favorites only", isOn: $favoritesOnly)
                    Toggle("Show archived", isOn: $showArchived)
                    Picker("Tag", selection: $tagFilter) {
                        Text("All").tag("all")
                        ForEach(["touched", "lingered", "approached", "passing", "vehicle", "noise", "unknown"], id: \.self) { t in
                            Text(t.capitalized).tag(t)
                        }
                    }
                    Picker("Sort by", selection: $sortMode) {
                        ForEach(SortMode.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            importToolbar
        }
        .fileImporter(isPresented: $showImportView, allowedContentTypes: [.directory]) { result in
            handleImport(result: result)
        }
    }

    @ToolbarContentBuilder
    private var importToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                showImportView = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
        }
    }

    private func handleImport(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task { @MainActor in
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

                let imported = await importEvents(url: url)

                // Build dedupe sets from current store contents.
                let existingVideoPaths: Set<String> = {
                    let descriptor = FetchDescriptor<VideoRecording>()
                    let existing = (try? modelContext.fetch(descriptor)) ?? []
                    return Set(existing.map { $0.url.path })
                }()
                let existingEventKeys: Set<String> = {
                    let descriptor = FetchDescriptor<Event>()
                    let existing = (try? modelContext.fetch(descriptor)) ?? []
                    return Set(existing.map(eventKey))
                }()

                var insertedEvents = 0
                var insertedVideos = 0
                var skippedEvents = 0
                var skippedVideos = 0

                for event in imported.events {
                    if existingEventKeys.contains(eventKey(event)) {
                        skippedEvents += 1
                        continue
                    }
                    modelContext.insert(event)
                    insertedEvents += 1
                }
                for video in imported.videos {
                    if existingVideoPaths.contains(video.url.path) {
                        skippedVideos += 1
                        continue
                    }
                    modelContext.insert(video)
                    insertedVideos += 1
                }

                do {
                    try modelContext.save()
                } catch {
                    print("modelContext.save failed: \(error)")
                }
                print("Import: events +\(insertedEvents)/-\(skippedEvents), videos +\(insertedVideos)/-\(skippedVideos)")
            }
        case .failure:
            print("nothing was selected")
        }
    }

    private func eventKey(_ event: Event) -> String {
        "\(event.source)|\(event.camera)|\(Int(event.timestamp.timeIntervalSince1970))"
    }
}

struct EventRow: View {
    let event: Event

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            cameraIcon
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if event.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                }
                HStack(spacing: 6) {
                    Label(TeslaCamera.displayName(for: event.camera), systemImage: cameraSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !event.city.isEmpty {
                        Text("· \(event.city)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    if !event.zone.isEmpty { ZoneChip(zone: event.zone) }
                    if event.tag != "unknown" { TagChip(tag: event.tag) }
                }
            }
            Spacer(minLength: 8)
            if event.interestingnessScore > 0 {
                ScoreBadge(score: event.interestingnessScore)
            }
        }
        .padding(.vertical, 4)
    }

    private var cameraSymbol: String {
        switch event.camera {
        case "0": return "arrow.up.circle"
        case "3": return "arrow.left.circle"
        case "4": return "arrow.right.circle"
        case "5": return "arrow.down.circle"
        default:  return "camera"
        }
    }

    private var cameraIcon: some View {
        Image(systemName: cameraSymbol)
            .font(.title2)
            .foregroundStyle(.tint)
            .frame(width: 28, height: 28)
    }
}

struct ZoneChip: View {
    let zone: String
    var body: some View {
        Text(zone)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.green)
            .liquidGlassChip(tint: .green)
    }
}

struct TagChip: View {
    let tag: String
    var body: some View {
        let (label, color): (String, Color) = {
            switch tag {
            case "touched":    return ("Touched", .red)
            case "lingered":   return ("Lingered", .orange)
            case "approached": return ("Approached", .yellow)
            case "passing":    return ("Passing", .blue)
            case "vehicle":    return ("Vehicle", .purple)
            case "noise":      return ("Noise", .gray)
            default:           return (tag.capitalized, .secondary)
            }
        }()
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .liquidGlassChip(tint: color)
    }
}

struct ScoreBadge: View {
    let score: Double
    var body: some View {
        let pct = max(0, min(1, score))
        let color: Color = pct > 0.66 ? .red : (pct > 0.33 ? .orange : .yellow)
        Text(String(format: "%.0f", pct * 100))
            .font(.caption2.monospacedDigit().bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .liquidGlassChip(tint: color)
    }
}

extension View {
    /// Liquid Glass on supported OSes, falling back to a tinted material capsule.
    @ViewBuilder
    func liquidGlassChip(tint: Color) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint.opacity(0.25)), in: .capsule)
        } else {
            self.background(tint.opacity(0.2), in: Capsule())
        }
    }

    /// Liquid Glass card background, falling back to .thinMaterial.
    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

#Preview {
    EventsListView()
}
