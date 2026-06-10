//
//  SyncedMultiCamPlayerView+Tiles.swift
//  teslaDashcamViewer
//
//  Tile + grid + sidebar UI for the synced multi-cam player.
//  Search keywords: UI:cam-tile, LAYOUT:cam-grid, BUTTON:cam-select
//

import SwiftUI
import AVKit

extension SyncedMultiCamPlayerView {

    // MARK: - 2x2 grid

    /// UI: the default 2x2 grid layout shown when no tile is focused.
    /// LAYOUT: change `spacing: 4` here to widen/tighten gaps between tiles.
    @ViewBuilder
    var grid: some View {
        let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(orderedCameras, id: \.self) { camID in
                tile(camID: camID, showsExitButton: false)
                    .onTapGesture {
                        // UI: tap a tile to enter focus mode for that camera
                        withAnimation(.easeInOut(duration: 0.25)) {
                            focusedCamera = camID
                        }
                    }
            }
        }
    }

    // MARK: - Single tile

    /// One camera tile. When `showsExitButton` is true, overlays a button
    /// that returns to the 2x2 grid.
    /// UI: each tile shows the video, a small label badge in the top-left, and
    /// optionally an "exit focus mode" button in the top-right.
    func tile(camID: String, showsExitButton: Bool) -> some View {
        let name = TeslaCamera.displayName(for: camID)
        let label = name.isEmpty ? "Camera" : name
        return ZStack(alignment: .topLeading) {
            // Video surface (or black placeholder if we couldn't open the file)
            if let player = players[camID] {
                PlayerLayerView(player: player)
                    // LAYOUT: 4:3 is the Tesla dashcam aspect ratio
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .allowsHitTesting(false)
            } else {
                Color.black
                    .aspectRatio(4.0/3.0, contentMode: .fit)
                    .overlay(
                        // TEXT: shown when a camera feed is missing
                        Text("No \(label) feed")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    )
            }

            // UI: small camera label badge in the corner
            Text(label)
                .font(.caption.bold())   // FONT: tile label
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(6)

            // BUTTON: return to grid (only when explicitly requested)
            if showsExitButton {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        focusedCamera = nil
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x2.fill") // ICON: grid
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .help("Back to grid")
            }
        }
        // COLOR: tile background behind the video
        .background(Color.black)
        // LAYOUT: tile corner radius
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
