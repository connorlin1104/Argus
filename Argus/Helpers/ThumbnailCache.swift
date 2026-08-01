//
//  ThumbnailCache.swift
//  Argus
//
//  Two-level cache for clip thumbnails: NSCache in memory, JPEGs in the
//  Caches directory on disk. Rows used to re-run AVAssetImageGenerator on
//  every appearance, which meant repeated slow reads from the source drive
//  (often external USB) while scrolling. Now a clip's frame is extracted
//  once, persisted, and served from cache on every later scroll or launch.
//
//  Dashcam clips are immutable, so the cache key is just the source path —
//  no mtime/size invalidation needed. The OS may purge the Caches directory
//  under disk pressure; we simply regenerate on the next request.
//

import Foundation
import AVFoundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum ThumbnailCache {

    /// TUNING: max thumb size — bigger = sharper but more memory/disk.
    /// Matches the old VideoRow generator setting (2x the 96×54 pt row).
    private static let maxSize = CGSize(width: 384, height: 216)

    private static let memory = NSCache<NSString, CGImage>()

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VideoThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Return the thumbnail for a clip, checking memory → disk → generating
    /// from the video file (and persisting) on a full miss. Runs off the main
    /// actor; returns nil if the bookmark can't be resolved or the frame
    /// can't be read.
    static func thumbnail(forPath path: String, bookmark: Data) async -> CGImage? {
        let key = cacheKey(for: path)
        if let hit = memory.object(forKey: key as NSString) {
            return hit
        }
        let fileURL = directory.appendingPathComponent(key + ".jpg")
        if let disk = readJPEG(at: fileURL) {
            memory.setObject(disk, forKey: key as NSString)
            return disk
        }
        guard let generated = await generate(bookmark: bookmark) else { return nil }
        memory.setObject(generated, forKey: key as NSString)
        writeJPEG(generated, to: fileURL)
        return generated
    }

    // MARK: - Generation

    /// Extract the 1-second frame from the clip, same as the old inline
    /// VideoRow logic. Refreshed bookmarks are dropped here (no model in
    /// reach) — the playback/analysis paths persist them.
    private static func generate(bookmark: Data) async -> CGImage? {
        guard let url = BookmarkResolver.resolve(bookmark)?.url else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maxSize
        let image = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        return image
    }

    // MARK: - Disk I/O

    /// SHA-256 of the source path — stable across launches (unlike Hasher).
    private static func cacheKey(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func readJPEG(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
