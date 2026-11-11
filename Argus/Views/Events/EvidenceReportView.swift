//
//  EvidenceReportView.swift
//  Argus
//
//  Print-styled SwiftUI blocks for the Evidence Package PDF. Each block is
//  rendered separately by EvidencePackageRenderer so pagination can break
//  between blocks (never inside one).
//
//  STYLE: these views are for paper, not the app — white background, black
//  and gray text, hairline rules. Never use materials (SectionCard /
//  liquidGlass*) or live Map views here: both rasterize wrong inside
//  ImageRenderer.
//

import SwiftUI

// MARK: - Report data

/// Everything the report shows, resolved up front by the renderer so the
/// views stay dumb: no model access, no async, no platform conditionals.
struct EvidenceReportData {
    let title: String
    let timestamp: Date
    let cameraName: String
    let trigger: String
    /// Nil → map block omitted (no/invalid coords, or snapshot failed).
    let mapImage: CGImage?
    let summary: String
    let notes: String
    let stills: [(image: CGImage, caption: String)]
    /// Label/value rows mirroring EventMetadataSection.
    let metadata: [(label: String, value: String)]
    let watchlistMatches: [(plate: String, note: String, isExact: Bool, colorHex: String)]
    let plateReads: [String]
    /// True when the event had footage clips; false adds a notice line.
    let hadClips: Bool
    let footer: String
}

// MARK: - Blocks

/// The report, as an ordered list of discrete pagination units. Stills go
/// two per row so a page break can fall between rows.
enum EvidenceReportBlock {
    case header
    case map
    case summary
    case notes
    case stillsRow([Int])
    case noFootageNotice
    case metadata
    case watchlist
    case plates
    case footer

    /// The blocks this report actually needs, in print order. Empty
    /// sections are dropped here, not hidden in the views, so pagination
    /// never measures a zero-height block.
    static func blocks(for data: EvidenceReportData) -> [EvidenceReportBlock] {
        var blocks: [EvidenceReportBlock] = [.header]
        if data.mapImage != nil { blocks.append(.map) }
        blocks.append(.summary)
        if !data.notes.isEmpty { blocks.append(.notes) }
        if data.stills.isEmpty {
            if !data.hadClips { blocks.append(.noFootageNotice) }
        } else {
            for rowStart in stride(from: 0, to: data.stills.count, by: 2) {
                let row = Array(rowStart..<min(rowStart + 2, data.stills.count))
                blocks.append(.stillsRow(row))
            }
        }
        blocks.append(.metadata)
        if !data.watchlistMatches.isEmpty { blocks.append(.watchlist) }
        if !data.plateReads.isEmpty { blocks.append(.plates) }
        blocks.append(.footer)
        return blocks
    }

    /// The SwiftUI view for one block at the given content width.
    @MainActor @ViewBuilder
    static func view(_ block: EvidenceReportBlock, data: EvidenceReportData) -> some View {
        Group {
            switch block {
            case .header: EvidenceHeaderBlock(data: data)
            case .map: EvidenceMapBlock(data: data)
            case .summary: EvidenceTextBlock(
                title: "Summary",
                text: data.summary.isEmpty ? "No summary available." : data.summary,
                placeholder: data.summary.isEmpty)
            case .notes: EvidenceTextBlock(title: "Notes", text: data.notes, placeholder: false)
            case .stillsRow(let indices): EvidenceStillsRowBlock(data: data, indices: indices)
            case .noFootageNotice: EvidenceTextBlock(
                title: "Footage",
                text: "No footage clips were available for this event.",
                placeholder: true)
            case .metadata: EvidenceMetadataBlock(data: data)
            case .watchlist: EvidenceWatchlistBlock(data: data)
            case .plates: EvidenceTextBlock(
                title: "Detected plates",
                text: data.plateReads.joined(separator: "   "),
                placeholder: false)
            case .footer: EvidenceFooterBlock(data: data)
            }
        }
        .padding(.bottom, 14)
        .background(.white)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Block views

private struct EvidenceHeaderBlock: View {
    let data: EvidenceReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Evidence Report")
                .font(.caption.smallCaps())
                .foregroundStyle(.gray)
            Text(data.title)
                .font(.title2.bold())
                .foregroundStyle(.black)
            Text(data.timestamp.formatted(date: .long, time: .standard))
                .font(.subheadline)
                .foregroundStyle(.black)
            HStack(spacing: 12) {
                if !data.cameraName.isEmpty {
                    Text("\(data.cameraName) camera")
                }
                if !data.trigger.isEmpty {
                    Text(data.trigger)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.gray)
            Rectangle().fill(.black).frame(height: 1).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EvidenceMapBlock: View {
    let data: EvidenceReportData

    var body: some View {
        if let map = data.mapImage {
            Image(decorative: map, scale: 2)
                .resizable()
                .scaledToFit()
                .border(.gray.opacity(0.4), width: 0.5)
        }
    }
}

private struct EvidenceTextBlock: View {
    let title: String
    let text: String
    let placeholder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EvidenceSectionTitle(title)
            Text(text)
                .font(.body)
                .foregroundStyle(placeholder ? .gray : .black)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EvidenceStillsRowBlock: View {
    let data: EvidenceReportData
    let indices: [Int]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(indices, id: \.self) { index in
                let still = data.stills[index]
                VStack(alignment: .leading, spacing: 3) {
                    Image(decorative: still.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .border(.gray.opacity(0.4), width: 0.5)
                    Text(still.caption)
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity)
            }
            // A lone still in a row keeps single-column width instead of
            // blowing up to double size.
            if indices.count == 1 {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
    }
}

private struct EvidenceMetadataBlock: View {
    let data: EvidenceReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EvidenceSectionTitle("Details")
            ForEach(Array(data.metadata.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label)
                        .foregroundStyle(.gray)
                    Spacer()
                    Text(row.value)
                        .foregroundStyle(.black)
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.gray.opacity(0.3)).frame(height: 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EvidenceWatchlistBlock: View {
    let data: EvidenceReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EvidenceSectionTitle("Watchlist matches")
            ForEach(Array(data.watchlistMatches.enumerated()), id: \.offset) { _, match in
                let tint = GeofenceStyle.color(hex: match.colorHex) ?? .red
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill").font(.caption2)
                        Text(match.isExact
                             ? match.plate.uppercased()
                             : "Possibly \(match.plate.uppercased())")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(tint))
                    if !match.note.isEmpty {
                        Text(match.note)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EvidenceFooterBlock: View {
    let data: EvidenceReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(.gray.opacity(0.4)).frame(height: 0.5)
            Text(data.footer)
                .font(.caption2)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EvidenceSectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.smallCaps().bold())
            .foregroundStyle(.gray)
            .padding(.bottom, 2)
    }
}
