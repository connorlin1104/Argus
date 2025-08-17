//
//  Anaylzer.swift
//  teslaDashcamViewer
//
//  Created by Connor Lin on 8/17/25.
//

import AVFoundation
import Vision
import Cocoa
import Observation

@Observable
class VideoAnalyzer {
    
    
    func analyzeVideo(url: URL, completion: @escaping (Int?) -> Void) {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return }
        
        let reader = try? AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader?.add(output)
        reader?.startReading()
        
        var result: Int? = nil
        var frameCount = 0
        
        while let sample = output.copyNextSampleBuffer() {  // Process every 5th frame
            if frameCount % 5 == 0 {
                if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                    
                    let request = VNDetectHumanRectanglesRequest { vnRequest, error in
                        guard let observations = vnRequest.results as? [VNDetectedObjectObservation] else { return }
                        for obs in observations {
                            let bbox = obs.boundingBox
                            if bbox.height > 0.3 {  // Threshold for "too close" (calibrate as needed)
                                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                                result = Int(time * 1000)
                            }
                        }
                    }
                    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
                    try? handler.perform([request])
                }
            }
            if result != nil { break }
            frameCount += 1
        }
        completion(result)
    }
}
