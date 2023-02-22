//
//  VideoPlayer.swift
//  YouTube360
//
//  Created by Mark Lim Pak Mun on 03/01/2023.
//  Copyright © 2023 Mark Lim Pak Mun. All rights reserved.
//
// Apple Documentation: "Responding to Playback State Changes"

import Foundation
import CoreVideo
import AVFoundation

class VideoPlayer: NSObject
{

    var naturalSize: CGSize!                    // natural size of a video frame

    private var avPlayer: AVPlayer!
    private var avPlayerItem: AVPlayerItem!
    private var avAsset: AVAsset!
    private var output: AVPlayerItemVideoOutput!
    private var nominalFrameRate: Float!

    // Key-value observing context
    private var playerItemContext = 0
    
    
    let requiredAssetKeys = [
        "playable",
        "hasProtectedContent"
    ]

    init(url: URL, framesPerSecond: Int)
    {
        super.init()
        avAsset = AVAsset(url: url)
        let tracks = avAsset.tracks(withMediaType: AVMediaTypeVideo)
        // All frames are expected to have the same size.
        naturalSize = tracks[0].naturalSize
        Swift.print("naturalSize", naturalSize)
        // # of frames per second
        var fps = Int(tracks[0].nominalFrameRate)
        if fps > framesPerSecond {
            fps = framesPerSecond
        }
        // Create a new AVPlayerItem with the asset and an array of asset keys
        // to be automatically loaded
        avPlayerItem = AVPlayerItem(asset: avAsset,
                                    automaticallyLoadedAssetKeys: requiredAssetKeys)
        // Associate the player item with the player
        avPlayer = AVPlayer(playerItem: avPlayerItem)

        configureOutput(framesPerSecond: fps)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(playEnd),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: nil)

        // Register as an observer of the player item's status property
        avPlayerItem.addObserver(self,
                                 forKeyPath: #keyPath(AVPlayerItem.status),
                                 options: [.old, .new],
                                 context: &playerItemContext)
        
    }

    deinit
    {
        NotificationCenter.default.removeObserver(self,
                                                  name: .AVPlayerItemDidPlayToEndTime,
                                                  object: nil)
        avPlayerItem.removeObserver(self,
                                    forKeyPath: #keyPath(AVPlayerItem.status),
                                    context: nil)
    }

    func play() {
        avPlayer.play()
    }

    func retrievePixelBuffer() -> CVPixelBuffer?
    {
        // The call `copyPixelBuffer` might fail because there might not be a new CVPixelBuffer at
        // every display refresh especially when the screen refresh rate exceeds that of the video being played.
        // For instance, 60 frames/sec vs a nominalFrameRate of 30 frames/sec.
        if output.hasNewPixelBuffer(forItemTime: avPlayerItem.currentTime()) {
            let pixelBuffer = output.copyPixelBuffer(forItemTime: avPlayerItem.currentTime(),
                                                     itemTimeForDisplay: nil)
            return pixelBuffer
        }
        else {
            return nil
        }
    }

    private func configureOutput(framesPerSecond: Int)
    {
        let pixelBuffer = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferMetalCompatibilityKey as String : true
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBuffer)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 1.0 / TimeInterval(framesPerSecond))
        avPlayerItem.add(output)
    }

    @objc private func playEnd()
    {
        avPlayer.seek(to: kCMTimeZero)
        //avPlayer.play()
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?,
                               context: UnsafeMutableRawPointer?)
    {

        // Only handle observations for the playerItemContext
        guard context == &playerItemContext else {
            super.observeValue(forKeyPath: keyPath,
                               of: object,
                               change: change,
                               context: context)
            return
        }

        if keyPath == #keyPath(AVPlayerItem.status) {
            let status: AVPlayerItemStatus
            if let statusNumber = change?[.newKey] as? NSNumber {
                status = AVPlayerItemStatus(rawValue: statusNumber.intValue)!
            }
            else {
                status = .unknown
            }
            
            
            // Switch over status value
            switch status {
            case .readyToPlay:
                // Player item is ready to play.
                // The presentation size is only known when avPlayer starts playing.
                // We want to pass this size to the MetalRenderer to instantiate
                //  the output texture just once.
                print("presentation size:", (object as! AVPlayerItem).presentationSize)
                break
            case .failed:
                // Player item failed. See error.
                break
            case .unknown:
                // Player item is not yet ready.
                break
            }
        }
    }
}
