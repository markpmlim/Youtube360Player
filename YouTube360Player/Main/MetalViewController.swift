//
//  ViewController.swift
//  YouTube360Player
//
//  Created by Mark Lim Pak Mun on 19/02/2023.
//  Copyright © 2023 Mark Lim Pak Mun. All rights reserved.
//
// An instance of CVDisplayLink will drive the display.

import Cocoa
import MetalKit
import AVFoundation

class MetalViewController: NSViewController, NSWindowDelegate
{
    var metalView: MetalView {
        return self.view as! MetalView
    }

    // Edit the name of the video file
    let nameOfVideo = "JurassicPark360.mov"
    var displayLink: CVDisplayLink?
    var displaySource: DispatchSource!
    var lastHostTime: UInt64!

    private var avPlayer = AVPlayer()
    // Allows you to coordinate the output of content associated with a Core Video pixel buffer.
    var videoOutput: AVPlayerItemVideoOutput!
    var naturalSize: CGSize!                    // natural size of a video frame

    var metalRenderer: MetalRenderer?
    var currentMouseLocation: CGPoint!
    var previousMouseLocation: CGPoint!
    var rotateX: Float = 0.0
    var rotateY: Float = 0.0

    let timeRemainingFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.zeroFormattingBehavior = .pad
        formatter.allowedUnits = [.minute, .second]
        return formatter
    }()

    private var timeObserverToken: Any?

    private var playerContext = 0

    private var timer: Timer?

    static let pauseButtonImageName = "PauseButton"
    static let playButtonImageName = "PlayButton"

    // MARK: - IBOutlet properties
    @IBOutlet weak var timeSlider: NSSlider!
    @IBOutlet weak var startTimeLabel: NSTextField!
    @IBOutlet weak var durationLabel: NSTextField!
    @IBOutlet weak var rewindButton: NSButton!
    @IBOutlet weak var playPauseButton: NSButton!
    @IBOutlet weak var fastForwardButton: NSButton!
    

    override func viewDidLoad()
    {
        super.viewDidLoad()

        prepareView()
        // The video file must be copied to the application's resource bundle
        // first followed by a compilation of the source code.
        let pathComponents = nameOfVideo.components(separatedBy: ".")
        guard let movieURL = Bundle.main.url(forResource: pathComponents[0],
                                             withExtension: pathComponents[1]) else {
            Swift.print("Video file \(nameOfVideo) not found")
            return
        }

        // Create an asset instance to represent the media file.
        let assetOptions = [AVURLAssetPreferPreciseDurationAndTimingKey : NSNumber(value:true)]
        let asset = AVURLAsset(url: movieURL,
                               options: assetOptions)   // assetOptions
        
        let success = loadPropertyValues(forAsset: asset)
        if !success {
            fatalError("Can't load property values from the asset \(asset)")
        }

        // We need the `naturalSize` of the video to instantiate a cubemap with
        // the required resolution.
        metalRenderer = MetalRenderer(metalLayer: metalView.metalLayer!,
                                      frameSize: naturalSize,
                                      device: metalView.metalLayer!.device!)

        avPlayer.play()
    }

    @objc func windowWillClose(_ notification: Notification)
    {
        if (notification.object as? NSWindow == self.metalView.window) {
            CVDisplayLinkStop(displayLink!)
        }
    }

    @objc func windowDidMiniaturize(_ notification: Notification)
    {
        if (notification.object as? NSWindow == self.metalView.window) {
            CVDisplayLinkStop(displayLink!)
            avPlayer.pause()
        }
    }
    
    @objc func windowDidDeminiaturize(_ notification: Notification)
    {
        if (notification.object as? NSWindow == self.metalView.window) {
            CVDisplayLinkStart(displayLink!)
            avPlayer.play()
        }
    }
    deinit
    {
        CVDisplayLinkStop(displayLink!)
        NotificationCenter.default.removeObserver(self,
                                                  name: Notification.Name.NSWindowWillClose,
                                                  object: nil)
        NotificationCenter.default.removeObserver(self,
                                                  name: Notification.Name.NSWindowDidMiniaturize,
                                                  object: nil)
        NotificationCenter.default.removeObserver(self,
                                                  name: Notification.Name.NSWindowDidDeminiaturize,
                                                  object: nil)

        avPlayer.removeObserver(self,
                                forKeyPath: #keyPath(AVPlayer.timeControlStatus),
                                context: nil)
        avPlayer.removeObserver(self,
                                forKeyPath: #keyPath(AVPlayer.currentItem.canPlayFastForward),
                                context: nil)
        avPlayer.removeObserver(self,
                                forKeyPath: #keyPath(AVPlayer.currentItem.canPlayReverse),
                                context: nil)
        avPlayer.removeObserver(self,
                                forKeyPath: #keyPath(AVPlayer.currentItem.canPlayFastReverse),
                                context: nil)
        avPlayer.removeObserver(self,
                                forKeyPath: #keyPath(AVPlayer.currentItem.status),
                                context: nil)
    }

    override var representedObject: Any? {
        didSet {
        }
    }

    func prepareView()
    {
        // Make sure there is a supported Metal device
        let device = MTLCreateSystemDefaultDevice()
        metalView.metalLayer?.device = device
        guard metalView.metalLayer?.device != nil else {
            print("Metal is not supported on this device.");
            exit(1)
        }
        metalView.metalLayer?.framebufferOnly = false

        // Create a display link capable of being used with all active displays
        var cvReturn = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        // The CVDisplayLink callback never executes on the main thread.
        // To execute rendering on the main thread, create a dispatch source
        // using the main queue (the main thread).
        let queue = DispatchQueue.main
        displaySource = DispatchSource.makeUserDataAddSource(queue: queue) as? DispatchSource
        displaySource.setEventHandler {
            var currentTime = CVTimeStamp()
            // Get the current "now" time of the display link.
            CVDisplayLinkGetCurrentTime(self.displayLink!, &currentTime)
            //self.lastHostTime = currentTime.hostTime
            //let outputItemTime = self.videoOutput.itemTime(for: currentTime)
            // We should be getting 60 frames/s
            let fps = (currentTime.rateScalar * Double(currentTime.videoTimeScale) / Double(currentTime.videoRefreshPeriod))
            self.processFrame(fps)
        }
        displaySource.resume()

        cvReturn = CVDisplayLinkSetCurrentCGDisplay(displayLink!, CGMainDisplayID())
        cvReturn = CVDisplayLinkSetOutputCallback(displayLink!, {
            (timer: CVDisplayLink,
             inNow: UnsafePointer<CVTimeStamp>,
             inOutputTime: UnsafePointer<CVTimeStamp>,
             flagsIn: CVOptionFlags,
             flagsOut: UnsafeMutablePointer<CVOptionFlags>,
             displayLinkContext: UnsafeMutableRawPointer?) -> CVReturn in

            // CVDisplayLink callback merges the dispatch source in each call
            //  to execute rendering on the main thread.
            let sourceUnmanaged = Unmanaged<DispatchSourceUserDataAdd>.fromOpaque(displayLinkContext!)
            sourceUnmanaged.takeUnretainedValue().add(data: 1)
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(displaySource).toOpaque())

        CVDisplayLinkStart(displayLink!)
    }

    // This function is called on the main thread by the CVDisplayLink.
    // It processes a new CVPixelBuffer if that's available, creates
    // an Equi-Angular cubemap texture (EAC) and draw a skybox with the EAC.
    // It has 1/60-th of a second to perform its oper
    fileprivate func processFrame(_ frameRate: Double)
    {
        guard let pixelBufer = self.retrievePixelBuffer() else {
            return
        }
        self.metalRenderer?.updateTextures(pixelBufer)
        self.metalRenderer?.draw()
    }

    // This method is called whenever there is a window/view resize
    override func viewDidLayout()
    {
        let viewSizePoints = metalView.bounds.size
        let viewSizePixels = metalView.convertToBacking(viewSizePoints)

        metalRenderer?.resize(viewSizePixels)

        if CVDisplayLinkIsRunning(displayLink!) {
            CVDisplayLinkStart(displayLink!)
        }
    }

    override func viewWillDisappear()
    {
        CVDisplayLinkStop(displayLink!)
    }

    // This func is called when a window is maximised (after a minimised)
    override func viewDidAppear()
    {
        self.metalView.window!.makeFirstResponder(self)

        let width = naturalSize.width/3
        // Can't use the window's aspectRatio yet.
        // So use the "presentation size" of the video
        let aspectRatio = naturalSize.width/naturalSize.height
        let height = width / aspectRatio
        self.metalView.setFrameSize(CGSize(width: width, height: height))
        // Change the window's frame
        var frameRect = self.metalView.window!.frame
        frameRect = NSRect(origin: CGPoint(x: frameRect.origin.x, y: frameRect.origin.y),
                           size: CGSize(width: width, height: height))
        self.metalView.window!.setFrame(frameRect, display: true, animate: true)
        // Set window title here.
        self.metalView.window!.title = nameOfVideo
        resetTimer()
    }

    // MARK: - Response to user actions.
    @objc func hideControls(_ timer: Timer)
    {
        playPauseButton.isHidden   = true
        timeSlider.isHidden        = true
        startTimeLabel.isHidden    = true
        durationLabel.isHidden     = true
        fastForwardButton.isHidden = true
        rewindButton.isHidden      = true
    }

    func resetTimer()
    {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 10.0,
                                     target: self,
                                     selector: #selector(hideControls),
                                     userInfo: nil,
                                     repeats: false)
    }
    
    // MARK: - IBActions
    // Click on the play/pause button
    @IBAction func togglePlay(_ sender: NSButton)
    {
        // The AVPlayer property `timeControlStatus` requires macOS 10.12.2 or later
        switch avPlayer.timeControlStatus {
        case .playing:
            // If the player is currently playing, pause it.
            avPlayer.pause()
        case .paused:
            /*
             If the player item already played to its end time, seek back to
             the beginning.
             */
            let currentItem = avPlayer.currentItem
            if currentItem?.currentTime() == currentItem?.duration {
                currentItem?.seek(to: kCMTimeZero)
            }
            // The player is currently paused. Begin playback.
            avPlayer.play()
        default:
            avPlayer.pause()
        }
    }
    
    @IBAction func playBackwards(_ sender: NSButton)
    {
        /*
         If the player item current time equals its beginning time, seek to the
         end.
         */
        if avPlayer.currentItem?.currentTime() == kCMTimeZero {
            if let itemDuration = avPlayer.currentItem?.duration {
                avPlayer.currentItem?.seek(to: itemDuration)
            }
        }
        // Reverse no faster than -2.0.
        avPlayer.rate = max(avPlayer.rate - 2.0, -2.0)
    }
    
    @IBAction func playFastForward(_ sender: NSButton)
    {
        /*
         If the player item current time equals its end time, seek back to the
         beginning.
         */
        if avPlayer.currentItem?.currentTime() == avPlayer.currentItem?.duration {
            avPlayer.currentItem?.seek(to: kCMTimeZero)
        }
        
        // Play fast forward no faster than 2.0.
        avPlayer.rate = min(avPlayer.rate + 2.0, 2.0)
    }
    
    /*
     Problem - slider jumps backward/forward during a forward/backward drag
     before adjusting to a correct position.
     Solution:

     1  Check mark the `Continuous` box after clicking IB's Attributes Inspector
     2  Pause the player before seeking.
     3  Seek to the position and
     4  use the completion handler to resume playing.
    */
    @IBAction func timeSliderDidChange(_ sender: NSSlider)
    {
        let newTime = CMTime(seconds: Double(sender.floatValue),
                             preferredTimescale: 600)
        // In order to seek accurately, there will be a slight delay
        avPlayer.pause()
        avPlayer.seek(to: newTime,
                      toleranceBefore: kCMTimeZero,
                      toleranceAfter: kCMTimeZero,
                      completionHandler: {
            (isFinish) in
            self.perform(#selector(self.deferToPlay),
                         with: nil,
                         afterDelay: 0.05)
        })
    }

    @objc private func deferToPlay() {
        self.avPlayer.play()
    }


    // <space bar> to toggle controls
    func toggleControls()
    {
        playPauseButton.isHidden   = !playPauseButton.isHidden
        timeSlider.isHidden        = !timeSlider.isHidden
        startTimeLabel.isHidden    = !startTimeLabel.isHidden
        durationLabel.isHidden     = !durationLabel.isHidden
        fastForwardButton.isHidden = !fastForwardButton.isHidden
        rewindButton.isHidden      = !rewindButton.isHidden
        resetTimer()
    }

    override func keyDown(with event: NSEvent)
    {
        let chars = event.characters
        let index0 = chars?.startIndex
        if chars![index0!] == " "  {
            toggleControls()
        }
        
        // Besides <Ctrl><⌘>F, pressing <ESC> will toggle FullScreen mode
        // <ESC> to toggle into and out of full screen mode
        if chars![index0!] == Character(UnicodeScalar(27))  {
            // Takes the window into or out of fullscreen mode
            view.window?.toggleFullScreen(self.view)
        }
    }

    // KIV
    override func mouseDown(with event: NSEvent)
    {
        //toggleControls()
        let mouseLocation = self.view.convert(event.locationInWindow, from: nil)
        currentMouseLocation = mouseLocation
        previousMouseLocation = mouseLocation
    }

    // On minimising followed by maximum, 
    override func mouseDragged(with event: NSEvent)
    {
        let mouseLocation = self.view.convert(event.locationInWindow,
                                              from: nil)
        let radiansPerPoint: Float = 0.0001
        var diffX = Float(mouseLocation.x - previousMouseLocation.x)
        var diffY = Float(mouseLocation.y - previousMouseLocation.y)

        diffX *= -radiansPerPoint
        diffY *= -radiansPerPoint
        rotateX += diffY
        rotateY += diffX
        self.metalRenderer?.rotateX = self.rotateX
        self.metalRenderer?.rotateY = self.rotateY
    }

    override func mouseUp(with event: NSEvent)
    {
        let mouseLocation = self.view.convert(event.locationInWindow, from: nil)
        previousMouseLocation = mouseLocation
        currentMouseLocation = mouseLocation
    }

    // MARK: - Helper functions
    func loadPropertyValues(forAsset newAsset: AVURLAsset) -> Bool
    {
        var success = false

        let assetKeysRequiredToPlay = [
            /*
             You can initialize an instance of the player item with the asset
             if the `playable` property value equals `true`.
             
             If the `hasProtectedContent` property value equals `true`, the
             asset contains protected content and can't be played.
             */
            "playable",
            "hasProtectedContent"
        ]

        let avPlayerItem = AVPlayerItem(asset: newAsset,
                                        automaticallyLoadedAssetKeys: assetKeysRequiredToPlay)

        if self.validateValues(forKeys: assetKeysRequiredToPlay,
                               forAsset: newAsset) {

            self.setupPlayerObservers()
            let tracks = newAsset.tracks(withMediaType: AVMediaTypeVideo)

            // All frames are expected to have the same size.
            self.naturalSize = tracks[0].naturalSize
            var fps = Int(tracks[0].nominalFrameRate)
            if fps > 60 {
                fps = 60
            }
            self.avPlayer.replaceCurrentItem(with: avPlayerItem)
            self.configureVideoOutput(framesPerSecond: fps)
            success = true
        }
        return success
    }

    private func validateValues(forKeys keys: [String],
                                forAsset newAsset: AVAsset) -> Bool
    {
        for key in keys {
            var error: NSError?
            if newAsset.statusOfValue(forKey: key,
                                      error: &error) == .failed {
                let stringFormat = NSLocalizedString("The media failed to load the key \"%@\"",
                                                     comment: "You can't use this AVAsset because one of it's keys failed to load.")
                
                let message = String.localizedStringWithFormat(stringFormat, key)
                handleErrorWithMessage(message, error: error)

                return false
            }
        } // for
        
        if !newAsset.isPlayable || newAsset.hasProtectedContent {
            /*
             You can't play the asset. Either the asset can't initialize a
             player item, or it contains protected content.
             */
            let message = NSLocalizedString("The media isn't playable or it contains protected content.",
                                            comment: "You can't use this AVAsset because it isn't playable or it contains protected content.")
            handleErrorWithMessage(message)

            return false
        }

        return true
    }


    // This must be called afer the method AVPlayer `replaceCurrentItem`
    private func configureVideoOutput(framesPerSecond: Int)
    {
        guard let currentItem = avPlayer.currentItem else {
            fatalError("Can't Configure the Player's AVPlayerItemVideoOutput")
        }

        let pixelBufferAttrs = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferMetalCompatibilityKey as String : true
        ]
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttrs)
        videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: 1.0 / TimeInterval(framesPerSecond))
        currentItem.add(videoOutput)
    }

    // This func is called by the CVDisplayLink on the main thread
    private func retrievePixelBuffer() -> CVPixelBuffer?
    {
        // The call `copyPixelBuffer` might fail because there might not be a new CVPixelBuffer at
        // every display refresh especially when the screen refresh rate exceeds that of the video being played.
        // For instance, 60 frames/sec vs a nominalFrameRate of 30 frames/sec.
        if videoOutput.hasNewPixelBuffer(forItemTime: avPlayer.currentItem!.currentTime()) {
            let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: avPlayer.currentItem!.currentTime(),
                                                          itemTimeForDisplay: nil)
            return pixelBuffer
        }
        else {
            return nil
        }
    }

    // MARK: - Utilities
    private func createTimeString(time: Float) -> String
    {
        let components = NSDateComponents()
        components.second = Int(max(0.0, time))
        return timeRemainingFormatter.string(from: components as DateComponents)!
    }

    private func setupPlayerObservers()
    {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowWillClose),
                                               name: Notification.Name.NSWindowWillClose,
                                               object: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidMiniaturize),
                                               name: Notification.Name.NSWindowDidMiniaturize,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidDeminiaturize),
                                               name: Notification.Name.NSWindowDidDeminiaturize,
                                               object: nil)
        /*
         Create a periodic observer to update the movie player time slider
         during playback.
         */
        let interval = CMTime(value: 1, timescale: 2)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval,
                                                             queue: .main) {
            // block
            [unowned self]
            time in
            let timeElapsed = Float(time.seconds)
            self.timeSlider.floatValue = timeElapsed
            self.startTimeLabel.stringValue = self.createTimeString(time: timeElapsed)
        }
        
        /*
         Register a`AVPlayer` object as an observer; only notifications with
         the name `AVPlayer.timeControlStatus` are delivered to the
         `AVPlayer` object.
         */
        avPlayer.addObserver(self,
                             forKeyPath: #keyPath(AVPlayer.timeControlStatus),
                             options: [.old, .new],
                             context: &playerContext)
        
        /*
         Register a`AVPlayer` object as an observer; only notifications with
         the name `AVPlayer.currentItem.canPlayFastForward` are delivered to the
         `AVPlayer` object.
         */
        avPlayer.addObserver(self,
                             forKeyPath: #keyPath(AVPlayer.currentItem.canPlayFastForward),
                             options: [.old, .new],
                             context: &playerContext)
        
        /*
         Register a`AVPlayer` object as an observer; only notifications with
         the name `AVPlayer.currentItem.canPlayReverse` are delivered to the
         `AVPlayer` object.
         */
        avPlayer.addObserver(self,
                           forKeyPath: #keyPath(AVPlayer.currentItem.canPlayReverse),
                           options: [.old, .new],
                           context: &playerContext)
        
        /*
         Register a`AVPlayer` object as an observer; only notifications with
         the name `AVPlayer.currentItem.canPlayFastReverse` are delivered to the
         `AVPlayer` object.
         */
        avPlayer.addObserver(self,
                             forKeyPath: #keyPath(AVPlayer.currentItem.canPlayFastReverse),
                             options: [.old, .new],
                             context: &playerContext)
        /*
         Register a`AVPlayer` object on the player's currentItem `status` property
         to observe state changes as they occur. The `status` property indicates the
         playback readiness of the player item. Associating a player item with
         a player immediately begins enqueuing the item’s media and preparing it
         for playback, but you must wait until its status changes to
         `.readyToPlay` before it’s ready for use.
         */
        avPlayer.addObserver(self,
                             forKeyPath: #keyPath(AVPlayer.currentItem.status),
                             options: [.old, .new],
                             context: &playerContext)
    }

    func setPlayPauseButtonImage()
    {
        var buttonImage: NSImage?
        
        switch self.avPlayer.timeControlStatus {
        case .playing:
            //buttonImage = NSImage(named: NSImage.Name(rawValue: PlayerViewController.pauseButtonImageName))
            buttonImage = NSImage(named: MetalViewController.pauseButtonImageName)
        case .paused, .waitingToPlayAtSpecifiedRate:
            //buttonImage = NSImage(named: NSImage.Name(rawValue: PlayerViewController.playButtonImageName))
            buttonImage = NSImage(named: MetalViewController.playButtonImageName)
        default:
            //buttonImage = NSImage(named: NSImage.name(rawValue: PlayerViewController.pauseButtonImageName))
            buttonImage = NSImage(named: MetalViewController.pauseButtonImageName)
        }
        guard let image = buttonImage else {
            return
        }
        self.playPauseButton.image = image
    }

    func updateUIforPlayerItemStatus()
    {
        guard let currentItem = avPlayer.currentItem else {
            return
        }

        switch currentItem.status {
        case .failed:
            /*
             Display an error if the player item status property equals
             `.failed`.
             */
            playPauseButton.isEnabled = false
            timeSlider.isEnabled = false
            startTimeLabel.isEnabled = false
            durationLabel.isEnabled = false
            handleErrorWithMessage(currentItem.error?.localizedDescription ?? "",
                                   error: currentItem.error)
            
        case .readyToPlay:
            /*
             The player item status equals `readyToPlay`. Enable the play/pause
             button.
             */
            playPauseButton.isEnabled = true
            
            /*
             Update the time slider control, start time and duration labels for
             the player duration.
             */
            let newDurationSeconds = Float(currentItem.duration.seconds)
            
            // Get the current time of the current player item.
            let currentTime = Float(CMTimeGetSeconds(avPlayer.currentTime()))
            
            timeSlider.maxValue = Double(newDurationSeconds)
            timeSlider.floatValue = currentTime
            timeSlider.isEnabled = true
            startTimeLabel.isEnabled = true
            startTimeLabel.stringValue = createTimeString(time: currentTime)
            durationLabel.isEnabled = true
            durationLabel.stringValue = createTimeString(time: newDurationSeconds)
            
        default:
            playPauseButton.isEnabled = false
            timeSlider.isEnabled = false
            startTimeLabel.isEnabled = false
            durationLabel.isEnabled = false
        }
    }

    func handleErrorWithMessage(_ message: String,
                                error: Error? = nil)
    {
        if let err = error {
            print("Error occurred with message: \(message), error: \(err).")
        }

        let alertTitle = NSLocalizedString("Error",
                                           comment: "Alert title for errors")

        var alert: NSAlert
        if error == nil {
            alert = NSAlert()
            alert.alertStyle = .warning
        }
        else {
            alert = NSAlert(error: error!)
            alert.alertStyle = .critical
        }
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        let alertActionTitle = NSLocalizedString("OK",
                                                 comment: "OK on error alert")
        alert.beginSheetModal(for: self.view.window!, completionHandler: {
            (response) -> Void in
            switch response {
            case NSAlertFirstButtonReturn:
                break
            default: break
            }
        })
    }


    // Use Objective-C style so that demo is compatible with Swift 3.x
    @objc
    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?,
                               context: UnsafeMutableRawPointer?)
    {
        // Only handle observations for the playerContext
        guard context == &playerContext else {
            super.observeValue(forKeyPath: keyPath,
                               of: object,
                               change: change,
                               context: context)
            return
        }
        
        if keyPath == #keyPath(AVPlayer.timeControlStatus) {
            // This is called whenever there is a click on the play/play button
            setPlayPauseButtonImage()
        }
        if keyPath == #keyPath(AVPlayer.currentItem.canPlayFastForward) {
            fastForwardButton.isEnabled = avPlayer.currentItem?.canPlayFastForward ?? false
        }
        if keyPath == #keyPath(AVPlayer.currentItem.canPlayReverse) {
            rewindButton.isEnabled = avPlayer.currentItem?.canPlayReverse ?? false
        }
        if keyPath == #keyPath(AVPlayer.currentItem.canPlayFastReverse) {
            rewindButton.isEnabled = avPlayer.currentItem?.canPlayFastReverse ?? false
        }
        if keyPath == #keyPath(AVPlayer.currentItem.status) {
            updateUIforPlayerItemStatus()
        }
    }
}

