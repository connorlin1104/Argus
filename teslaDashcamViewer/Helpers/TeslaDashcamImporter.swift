//
//  TeslaDashcamImporter.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import Foundation

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


func importEvents(url: URL) -> [Event] {
    var events: [Event] = []
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

            if let event = importEvent(eventURL: eventURL, eventDirectory: eventDirectory) {
                events.append(event)
            }

        }
    } catch {
        print("error \(error)")
    }
    return events
}

func importEvent(eventURL: URL, eventDirectory: URL) -> Event? {
    do {
        let fileManager = FileManager.default
        let data = try Data(contentsOf: eventURL)
        if let jsonDict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            
            let camera = jsonDict["camera"] as? String
            let city = jsonDict["city"] as? String
            let estLatitude = jsonDict["est_lat"] as? String
            let estLongitude = jsonDict["est_lon"] as? String
            let reason = jsonDict["reason"] as? String
            let timestampString = jsonDict["timestamp"] as? String
            
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            //df.timeZone = timeZone
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let timestamp = df.date(from: timestampString!)

            let sentryEvent = Event(source: "Tesla",
                                    camera: camera!,
                                    city: city!,
                                    estLatitude: estLatitude!,
                                    estLongitude: estLongitude!,
                                    reason: reason!,
                                    timestamp: timestamp!)
            
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
                
                let (startTime, cameraName) = parseFilename(file.lastPathComponent)
                if startTime == nil {
                    continue
                }
                let endTime = Date(timeIntervalSince1970: TimeInterval(startTime!.timeIntervalSince1970) + 60)
                
                let bookmarkData = try! file.bookmarkData(options: .withSecurityScope)
                videos.append(VideoRecording(url: file, bookmark: bookmarkData, camera: cameraName, startTime: startTime!, endTime: endTime))
            }
            sentryEvent.videos = videos
            return sentryEvent

        }
    } catch {
    }
    return nil

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

