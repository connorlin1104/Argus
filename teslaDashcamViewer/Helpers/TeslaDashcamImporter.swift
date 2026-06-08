//
//  TeslaDashcamImporter.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import Foundation
import AVFoundation

//["0"] = "Front", ["3"] = "Left", ["4"] = "Right", ["5"] = "Rear"

enum FilenameParseError: Error, LocalizedError {
    case invalidFormat
    case invalidDate(String)
    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Filename doesn't match expected pattern: YYYY-MM-DD_HH-mm-ss_label.ext"
        case .invalidDate(let s): return "Unable to parse date from '\(s)'"
        }
    }
}


struct ImportResult {
    var events: [Event] = []
    var videos: [VideoRecording] = []
}

func importEvents(url: URL) async -> ImportResult {
    var result = ImportResult()
    let fileManager = FileManager.default

    do {
        let eventDirectories = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )

        for eventDirectory in eventDirectories {
            let values = try eventDirectory.resourceValues(forKeys: [.isDirectoryKey])

            if values.isDirectory == false {
                //Skip files in events directory.
                continue
            }

            let eventURL = eventDirectory.appendingPathComponent("event.json")
            if !fileManager.fileExists(atPath: eventURL.path) {
                //Skip directories that don't have event.json file in them
                continue
            }

            if let (event, videos) = await importEvent(eventURL: eventURL, eventDirectory: eventDirectory) {
                result.events.append(event)
                result.videos.append(contentsOf: videos)
            }
        }
    } catch {
        print("error \(error)")
    }
    return result
}

func importEvent(eventURL: URL, eventDirectory: URL) async -> (event: Event, videos: [VideoRecording])? {
    do {
        let fileManager = FileManager.default
        let data = try Data(contentsOf: eventURL)
        guard let jsonDict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }

        guard let camera = jsonDict["camera"] as? String,
              let city = jsonDict["city"] as? String,
              let estLatitude = jsonDict["est_lat"] as? String,
              let estLongitude = jsonDict["est_lon"] as? String,
              let reason = jsonDict["reason"] as? String,
              let timestampString = jsonDict["timestamp"] as? String else {
            return nil
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let timestamp = df.date(from: timestampString) else {
            return nil
        }

        let sentryEvent = Event(source: "Tesla",
                                camera: camera,
                                city: city,
                                estLatitude: estLatitude,
                                estLongitude: estLongitude,
                                reason: reason,
                                timestamp: timestamp)

        let videoURLs = try fileManager.contentsOfDirectory(
            at: eventDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        var videos: [VideoRecording] = []
        for file in videoURLs {
            if file.pathExtension != "mp4" {
                //Skip files that are not mp4
                continue
            }

            let (parsedStart, cameraName) = parseFilename(file.lastPathComponent)
            guard let startTime = parsedStart else {
                continue
            }

            // Read real duration from the asset instead of assuming 60s.
            let durationSeconds = await videoDurationSeconds(url: file) ?? 60
            let endTime = startTime.addingTimeInterval(durationSeconds)

            let bookmarkData: Data
            do {
                #if os(iOS)
                    bookmarkData = try file.bookmarkData()
                #else
                    bookmarkData = try file.bookmarkData(options: .withSecurityScope)
                #endif
            } catch {
                print("Bookmark creation failed for \(file.lastPathComponent): \(error)")
                continue
            }

            videos.append(VideoRecording(url: file, bookmark: bookmarkData, camera: cameraName, startTime: startTime, endTime: endTime))
        }
        return (sentryEvent, videos)
    } catch {
        print("importEvent error: \(error)")
        return nil
    }
}

private func videoDurationSeconds(url: URL) async -> TimeInterval? {
    let asset = AVURLAsset(url: url)
    do {
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    } catch {
        return nil
    }
}

func parseFilename(_ filename: String, timeZone: TimeZone = .current) -> (date: Date?, cameraID: String) {
    // Get just the file name without extension
    let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    
    // First 19 chars = timestamp
    let timestampPart = String(base.prefix(19))
    // Rest after underscore or dash = camera ID
    let cameraID = String(base.dropFirst(20)) // skip 19 chars + 1 separator

    // Parse date
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = timeZone
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let date = df.date(from: timestampPart)

    return (date, cameraID)
}

