//
//  MetalView.swfit
//  YouTube360Player
//
//  Created by Mark Lim Pak Mun on 19/02/2023.
//  Copyright © 2023 Mark Lim Pak Mun. All rights reserved.
//


import AppKit

class MetalView: NSView {
    var metalLayer: CAMetalLayer?

    override var wantsUpdateLayer: Bool {
        return true
    }

    override func makeBackingLayer() -> CALayer {
        return CAMetalLayer()
    }

    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let scale = NSScreen.main()?.backingScaleFactor
        metalLayer?.drawableSize = CGSize(width: self.bounds.size.width * scale!,
                                          height: self.bounds.size.height * scale!)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        let scale = NSScreen.main()?.backingScaleFactor
        metalLayer?.drawableSize = CGSize(width: self.bounds.size.width * scale!,
                                          height: self.bounds.size.height * scale!)
    }

    // Never called
    override func updateLayer() {
        //Make changes to the layer here!
        Swift.print("updateLayer");
    }

    // Note: Uncheck MetalView's CALayer using IB `Video Effects`
    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)

        // The statement below should trigger a call to the func makeBackerLayer()
        self.wantsLayer = true
        // On return, the view's "layer" property is set to an instance of CAMetalLayer
        metalLayer = self.layer as? CAMetalLayer
        metalLayer?.pixelFormat = MTLPixelFormat.bgra8Unorm // default
        self.layerContentsRedrawPolicy = .duringViewResize
    }
}
