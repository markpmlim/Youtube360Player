//
//  MetalRenderer.swift
//  YouTube360Player
//
//  Created by Mark Lim Pak Mun on 19/02/2023.
//  Copyright © 2023 Mark Lim Pak Mun. All rights reserved.
//

import AppKit
import MetalKit

// size=64 bytes, stride=64 bytes, alignment=16 bytes.
struct Uniforms {
    let modelViewProjectionMatrix: matrix_float4x4
}

// size=64 bytes, stride=64 bytes, alignment=16 bytes.
struct InstanceParams {
    var viewProjectionMatrix = matrix_identity_float4x4
}

// Global constants
let kMaxInFlightFrameCount = 3
let kAlignedUniformsSize = (MemoryLayout<Uniforms>.stride & ~0xFF) + 0x100

class MetalRenderer: NSObject
{
    var device: MTLDevice!
    var metalLayer: CAMetalLayer!
    var commandQueue: MTLCommandQueue!

    var depthTexture: MTLTexture!
    var computePipelineState: MTLComputePipelineState!
    var threadsPerThreadgroup: MTLSize!
    var threadgroupsPerGrid: MTLSize!

    var viewSize: CGSize!
    var degree: Float = 0
    var rotateX: Float = 0.0
    var rotateY: Float = 0.0
    var modelViewProjectionMatrix = matrix_identity_float4x4
    var projectionMatrix = matrix_identity_float4x4
    var uniformsBuffers = [MTLBuffer]()
    let frameSemaphore = DispatchSemaphore(value: kMaxInFlightFrameCount)
    var currentFrameIndex = 0

    var lumaTexture: MTLTexture?
    var chromaTexture: MTLTexture?
    var lumaTextureRef: CVMetalTexture?
    var chromaTextureRef: CVMetalTexture?
    var videoTextureCache: CVMetalTextureCache?
    var compactMapTexture: MTLTexture!
    var frameSize: CGSize!                          // Assume all frames of the video are the same.
    var cubemapResolution = 512

    // Render a cubemap
    var skyboxMesh: BoxMesh!
    var cubeMesh: BoxMesh!
    var instanceParmsBuffer: MTLBuffer!
    var cubeMapTexture: MTLTexture!
    var cubeMapDepthTexture: MTLTexture!
    var renderToTexturePassDescriptor: MTLRenderPassDescriptor!
    var skyboxRenderPipelineState: MTLRenderPipelineState!
    var renderToTextureRenderPipelineState: MTLRenderPipelineState!

    init(metalLayer: CAMetalLayer,
         frameSize: CGSize,
         device: MTLDevice)
    {
        self.metalLayer = metalLayer
        self.device = device
        self.frameSize = frameSize

        commandQueue = device.makeCommandQueue()
        super.init()
        buildResources(self.device)
        buildPipelineStates()
    }

    deinit
    {
        for _ in 0..<kMaxInFlightFrameCount {
            self.frameSemaphore.signal()
        }
    }

    func buildResources(_ device: MTLDevice)
    {
        // The cubeMesh is used to render the cubemap texture to an
        //  offscreen frame buffer
        // We only need the position of each vertex. The parameter "inwordNormals"
        //  is irrelevant.
        cubeMesh = BoxMesh(withSize: 2,
                           inwardNormals: true,
                           device: device)
        
        // The skyboxMesh is used to render the skybox to the main display
        // We only need the position and normal of each vertex.
        skyboxMesh = BoxMesh(withSize: 2,
                             inwardNormals: true,
                             device: device)

        // Allocate memory for 3 inflight blocks of Uniforms.
        for _ in 0..<kMaxInFlightFrameCount {
            let buffer = self.device.makeBuffer(length: kAlignedUniformsSize,
                                                options: .cpuCacheModeWriteCombined)
            uniformsBuffers.append(buffer)
        }

        // Allocate memory for an InstanceParams object.
        instanceParmsBuffer = self.device.makeBuffer(length: MemoryLayout<InstanceParams>.stride * 6,
                                                     options: .cpuCacheModeWriteCombined)
        // Demo works even if the cubemapResolution is not a power of 2 e.g. 853
        // It works even if the natural size of each video frame is not in the ratio 16:9
        // which seemed to be the recommended size of youtube 360 videos.
        cubemapResolution = Int(self.frameSize.width/3)
        //print(cubemapResolution)
        /// Set up a cubemap texture for copy to
        let cubeMapDesc = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: metalLayer.pixelFormat,
                                                                     size: Int(cubemapResolution),
                                                                     mipmapped: false)
        cubeMapDesc.storageMode = MTLStorageMode.managed
        cubeMapDesc.usage = [MTLTextureUsage.renderTarget, MTLTextureUsage.shaderRead]
        cubeMapTexture = device.makeTexture(descriptor: cubeMapDesc)

        let cubeMapDepthDesc = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: MTLPixelFormat.depth32Float,
                                                                          size: Int(cubemapResolution),
                                                                          mipmapped: false)
        cubeMapDepthDesc.storageMode = MTLStorageMode.private
        cubeMapDepthDesc.usage = MTLTextureUsage.renderTarget
        cubeMapDepthTexture = device.makeTexture(descriptor: cubeMapDepthDesc)

        // Set up a render pass descriptor for the offscreen render pass to render into a cubemap texture.
        renderToTexturePassDescriptor = MTLRenderPassDescriptor()
        renderToTexturePassDescriptor.colorAttachments[0].clearColor  = MTLClearColorMake(1, 1, 1, 1)
        renderToTexturePassDescriptor.colorAttachments[0].loadAction  = MTLLoadAction.clear
        renderToTexturePassDescriptor.colorAttachments[0].storeAction = MTLStoreAction.store
        renderToTexturePassDescriptor.depthAttachment.clearDepth      = 1.0
        renderToTexturePassDescriptor.depthAttachment.loadAction      = MTLLoadAction.clear
        renderToTexturePassDescriptor.colorAttachments[0].texture     = cubeMapTexture
        renderToTexturePassDescriptor.depthAttachment.texture         = cubeMapDepthTexture
        renderToTexturePassDescriptor.renderTargetArrayLength         = 6
     }

    func buildPipelineStates()
    {
        // Load all the shader files with a metal file extension in the project
        guard let library = device.newDefaultLibrary() else {
                fatalError("Could not load default library from main bundle")
        }
        
        // Use a compute shader function to convert yuv colours to rgb colours.
        let kernelFunction = library.makeFunction(name: "YCbCrColorConversion")
        do {
            computePipelineState = try device.makeComputePipelineState(function: kernelFunction!)
        }
        catch {
            fatalError("Unable to create compute pipeline state")
        }
        
        // Instantiate a new instance of MTLTexture to capture the output of kernel function.
        // We assume all video frames have the same natural size.
        let mtlTextureDesc = MTLTextureDescriptor()
        mtlTextureDesc.textureType = .type2D
        mtlTextureDesc.pixelFormat = metalLayer.pixelFormat
        mtlTextureDesc.width = Int(self.frameSize.width)
        mtlTextureDesc.height = Int(self.frameSize.height)
        mtlTextureDesc.usage = [.shaderRead, .shaderWrite]
        compactMapTexture = device.makeTexture(descriptor: mtlTextureDesc)
        
        // To speed up the colour conversion of a video frame, utilise all available threads
        let w = computePipelineState.threadExecutionWidth
        let h = computePipelineState.maxTotalThreadsPerThreadgroup / w
        threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        threadgroupsPerGrid = MTLSizeMake((mtlTextureDesc.width+threadsPerThreadgroup.width-1) / threadsPerThreadgroup.width,
                                          (mtlTextureDesc.height+threadsPerThreadgroup.height-1) / threadsPerThreadgroup.height,
                                          1)

        /// Create the render pipeline for the drawable render pass.
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        
        pipelineDescriptor.sampleCount = 1
        pipelineDescriptor.label = "Render Skybox Pipeline"
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = cubeMapDepthTexture.pixelFormat
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "SkyboxVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "CubeLookupShader")
        var mdlVertexDescriptor = skyboxMesh.metalKitMesh.vertexDescriptor
        var mtlVertexDescriptor = MTKMetalVertexDescriptorFromModelIO(mdlVertexDescriptor)
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        do {
            skyboxRenderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        catch {
            fatalError("Could not create skybox render pipeline state object: \(error)")
        }

        // Set up pipeline for rendering to the offscreen texture.
        // Reuse the above descriptor object and change properties that differ.
        pipelineDescriptor.label = "Offscreen Render Pipeline"
        pipelineDescriptor.sampleCount = 1
        pipelineDescriptor.colorAttachments[0].pixelFormat = cubeMapTexture.pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat =  cubeMapDepthTexture.pixelFormat
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "cubeMapVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "outputCubeMapTexture")
        mdlVertexDescriptor = cubeMesh.metalKitMesh.vertexDescriptor
        mtlVertexDescriptor = MTKMetalVertexDescriptorFromModelIO(mdlVertexDescriptor)
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        pipelineDescriptor.inputPrimitiveTopology = MTLPrimitiveTopologyClass.triangle
        do {
            renderToTextureRenderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        catch {
            fatalError("Could not create offscreen render pipeline state object: \(error)")
        }
    }

    func buildDepthBuffer()
    {
        let drawableSize = metalLayer.drawableSize
        let depthTexDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                    width: Int(drawableSize.width),
                                                                    height: Int(drawableSize.height),
                                                                    mipmapped: false)
        depthTexDesc.resourceOptions = .storageModePrivate
        depthTexDesc.usage = [.renderTarget, .shaderRead]
        self.depthTexture = self.device.makeTexture(descriptor: depthTexDesc)
    }

    func resize(_ size: CGSize)
    {
        viewSize = size
        buildDepthBuffer()
        let aspect = Float(viewSize.width/viewSize.height)
        projectionMatrix = matrix_perspective_left_hand(radians_from_degrees(60),
                                                        aspect,
                                                        0.1, 10.0)
    }

    private func cleanTextures()
    {
        if lumaTextureRef != nil {
            lumaTextureRef = nil
        }

        if chromaTextureRef != nil {
            chromaTextureRef = nil
        }

        if let videoTextureCache = videoTextureCache {
            CVMetalTextureCacheFlush(videoTextureCache, 0)
        }
    }

    // Called by the view controller's `processFrame` method on the main thread.
    func updateTextures(_ pixelBuffer: CVPixelBuffer)
    {
        if videoTextureCache == nil {
            let result = CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                                   nil,                 // cacheAttributes
                                                   device,
                                                   nil,                 // textureAttributes
                                                   &videoTextureCache)
            if result != kCVReturnSuccess {
                print("create CVMetalTextureCacheCreate failure")
                return
            }
        }

        let textureWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let textureHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)

        CVPixelBufferLockBaseAddress(pixelBuffer,
                                     .readOnly)

        cleanTextures()

        var result: CVReturn
        result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                           videoTextureCache!,
                                                           pixelBuffer,
                                                           nil,
                                                           .r8Unorm,
                                                           textureWidth, textureHeight,
                                                           0,
                                                           &lumaTextureRef)
        if result != kCVReturnSuccess {
            print("Failed to create lumaTextureRef: %d", result)
            return
        }
 
        let cbcrWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
        let cbcrHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
        result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                           videoTextureCache!,
                                                           pixelBuffer,
                                                           nil,
                                                           .rg8Unorm,
                                                           cbcrWidth, cbcrHeight,
                                                           1,
                                                           &chromaTextureRef)

        if result != kCVReturnSuccess {
            print("Failed to create chromaTextureRef %d", result)
            return
        }

        // Pass these 2 MTLTextures to the kernel function
        lumaTexture = CVMetalTextureGetTexture(lumaTextureRef!)
        chromaTexture = CVMetalTextureGetTexture(chromaTextureRef!)

        CVPixelBufferUnlockBaseAddress(pixelBuffer,
                                       CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
    /*
         Use the color attachment of the pixel buffer to determine the appropriate color conversion matrix.

         CFTypeRef CVBufferGetAttachment(CVBufferRef buffer, CFStringRef key, CVAttachmentMode *attachmentMode);
         // use the following because CVBufferGetAttachment is deprecated.
         CFTypeRef CVBufferCopyAttachment(CVBufferRef buffer, CFStringRef key, CVAttachmentMode *attachmentMode);
 
        let colorAttachments = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue() as? NSString
        
        if colorAttachments == kCVImageBufferYCbCrMatrix_ITU_R_601_4 {
            print(kCVImageBufferYCbCrMatrix_ITU_R_601_4)
            //_preferredConversion = kColorConversion601
        }
        else {
            //_preferredConversion = kColorConversion709
            print(kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }
    */
    }
 
    func updateModelViewProjectionMatrix()
    {
        var modelViewMatrix = matrix4x4_rotation(rotateX, float3(1, 0, 0))
        let rotationMatrix = matrix4x4_rotation(rotateY, float3(0, 1, 0))
        modelViewMatrix = matrix_multiply(modelViewMatrix, rotationMatrix)
        modelViewProjectionMatrix = matrix_multiply(projectionMatrix, modelViewMatrix)
    }

    // Create a cubemap the traditional way.
    // Note: the texture is an Equi-Angular Cubemap Texture (EAC)
    func createCubemapTexture()
    {
        let captureProjectionMatrix = matrix_perspective_left_hand(radians_from_degrees(90),
                                                                   1.0,
                                                                   0.1, 10.0)
        var captureViewMatrices = [matrix_float4x4]()
        // The camera is rotated +90 degrees about the y-axis.
        var viewMatrix = matrix_look_at_left_hand(float3(0, 0, 0),  // eye is at the origin of the cube.
                                                  float3(1, 0, 0),  // centre of +X face
                                                  float3(0, 1, 0))  // Up
        captureViewMatrices.append(viewMatrix)

        // The camera is rotated -90 degrees about the y-axis.
        viewMatrix = matrix_look_at_left_hand(float3( 0, 0, 0),
                                              float3(-1, 0, 0),     // centre of -X face
                                              float3( 0, 1, 0))

        captureViewMatrices.append(viewMatrix)

        // The camera is rotated -90 degrees about the x-axis.
        viewMatrix = matrix_look_at_left_hand(float3(0, 0,  0),
                                              float3(0, 1,  0),     // centre of +Y face
                                              float3(0, 0, -1))
        captureViewMatrices.append(viewMatrix)

        // We rotate the camera  is rotated +90 degrees about the x-axis.
        viewMatrix = matrix_look_at_left_hand(float3(0,  0,  0),
                                              float3(0, -1,  0),    // centre of -Y face
                                              float3(0,  0,  1))
        captureViewMatrices.append(viewMatrix)
        
        // The camera is at its initial position pointing in the +z direction.
        // The up vector of the camera is pointing in the +y direction.
        viewMatrix = matrix_look_at_left_hand(float3(0, 0, 0),
                                              float3(0, 0, 1),
                                              float3(0, 1, 0))
        captureViewMatrices.append(viewMatrix)

        // The camera is rotated +180 (-180) degrees about the y-axis.
        viewMatrix = matrix_look_at_left_hand(float3(0, 0,  0),
                                              float3(0, 0, -1),     // centre of -Z face
                                              float3(0, 1,  0))
        captureViewMatrices.append(viewMatrix)

        let bufferPointer = instanceParmsBuffer.contents()
        var viewProjectionMatrix = matrix_float4x4()
        for i in 0..<captureViewMatrices.count {
            viewProjectionMatrix = matrix_multiply(captureProjectionMatrix,
                                                   captureViewMatrices[i])
            memcpy(bufferPointer + MemoryLayout<InstanceParams>.stride * i,
                   &viewProjectionMatrix,
                   MemoryLayout<InstanceParams>.stride)
        }

        let commandBuffer = commandQueue.makeCommandBuffer()
        commandBuffer.label = "Capture Cubemap"
        commandBuffer.addCompletedHandler {
            cb in
            if commandBuffer.status == .completed {
                //print("The textures of each face of the Cube Map were created successfully.")
            }
            else {
                if commandBuffer.status == .error {
                    print("The textures of each face of the Cube Map could be not created")
                    print("Command Buffer Status Error")
                }
                else {
                    print("Command Buffer Status Code: ", commandBuffer.status)
                }
            }
        }
        // Create a new render command encoder to render the 6 faces of the cube texture.
        let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderToTexturePassDescriptor)
        commandEncoder.label = "Offscreen Render Pass"
        commandEncoder.setRenderPipelineState(renderToTextureRenderPipelineState)
        commandEncoder.setFrontFacing(.clockwise)
        commandEncoder.setCullMode(.back)
        let viewPort = MTLViewport(originX: 0, originY: 0,
                                   width: Double(cubemapResolution), height: Double(cubemapResolution),
                                   znear: 0, zfar: 1)
        commandEncoder.setViewport(viewPort)

        // Write the output of the fragment function "cubeMapVertexShader"
        // to the correct slice of the cubemap texture object.
        commandEncoder.setVertexBuffer(instanceParmsBuffer,
                                       offset: 0,
                                       at: 1)
        commandEncoder.setFragmentTexture(compactMapTexture,
                                          at: 0)

        // Draw the cube.
        let vertexBuffer = cubeMesh.metalKitMesh.vertexBuffers[0]
        commandEncoder.setVertexBuffer(vertexBuffer.buffer,
                                       offset: vertexBuffer.offset,
                                       at: 0)
        for (_, submesh) in cubeMesh.metalKitMesh.submeshes.enumerated() {
            let indexBuffer = submesh.indexBuffer
            commandEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                 indexCount: submesh.indexCount,
                                                 indexType: submesh.indexType,
                                                 indexBuffer: indexBuffer.buffer,
                                                 indexBufferOffset: indexBuffer.offset,
                                                 instanceCount: 6,
                                                 baseVertex: 0,
                                                 baseInstance: 0)
        }
        // End encoding commands for this render pass.
        commandEncoder.endEncoding()
        commandBuffer.commit()
    }

    // This method will be called per frame update.
    // CAMetalLayer has a function nextDrawable.
    func draw()
    {
        // `autoreleasepool` ensures metal drawables are released promptly.
        // Otherwise Core Animation might run out of drawables to vend and
        // future calls to nextDrawable will return nil.
        autoreleasepool {
            guard let drawable = metalLayer.nextDrawable() else {
                return
            }
            _ = frameSemaphore.wait(timeout: DispatchTime.distantFuture)

            let commandBuffer = commandQueue.makeCommandBuffer()
            // Step 1: Combine the luminance and chromium textures in an RGBA texture.
            let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder()
            computeCommandEncoder.label = "Compute Encoder"
            computeCommandEncoder.setComputePipelineState(computePipelineState)
            computeCommandEncoder.setTexture(lumaTexture, at: 0)
            computeCommandEncoder.setTexture(chromaTexture, at: 1)
            computeCommandEncoder.setTexture(compactMapTexture, at: 2) // output texture
            computeCommandEncoder.dispatchThreadgroups(threadgroupsPerGrid,
                                                       threadsPerThreadgroup: threadsPerThreadgroup)
            computeCommandEncoder.endEncoding()

            // Step 2: Generate an EAC which is used to texture a skybox
            createCubemapTexture()

            // Step 3: Prepare to draw a skybox
            let drawableSize = drawable.layer.drawableSize
            if (drawableSize.width != CGFloat(depthTexture.width) ||
                drawableSize.height != CGFloat(depthTexture.height)) {
                buildDepthBuffer()
            }
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)

            renderPassDescriptor.depthAttachment.texture = self.depthTexture
            renderPassDescriptor.depthAttachment.loadAction = .clear
            renderPassDescriptor.depthAttachment.storeAction = .dontCare
            renderPassDescriptor.depthAttachment.clearDepth = 1

            updateModelViewProjectionMatrix()
            var uniform = Uniforms(modelViewProjectionMatrix: modelViewProjectionMatrix)
            let bufferPointer = uniformsBuffers[currentFrameIndex].contents()
            memcpy(bufferPointer,
                   &uniform,
                   kAlignedUniformsSize)
            let currentBuffer = uniformsBuffers[currentFrameIndex]

            let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
            renderEncoder.label = "Render Encoder"
            renderEncoder.setRenderPipelineState(skyboxRenderPipelineState)
            let viewPort = MTLViewport(originX: 0.0, originY: 0.0,
                                       width: Double(viewSize.width), height: Double(viewSize.height),
                                       znear: -1.0, zfar: 1.0)
            renderEncoder.setViewport(viewPort)

            renderEncoder.setVertexBuffer(currentBuffer,
                                          offset: 0,
                                          at: 1)
            renderEncoder.setFragmentTexture(cubeMapTexture,
                                             at: 0)

            let meshBuffer = skyboxMesh.metalKitMesh.vertexBuffers[0]
            renderEncoder.setVertexBuffer(meshBuffer.buffer,
                                          offset: meshBuffer.offset,
                                          at: 0)

            // Render the skybox
            // Issue the draw call to draw the indexed geometry of the mesh
            for (_, submesh) in skyboxMesh.metalKitMesh.submeshes.enumerated() {
                let indexBuffer = submesh.indexBuffer
                renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                    indexCount: submesh.indexCount,
                                                    indexType: submesh.indexType,
                                                    indexBuffer: indexBuffer.buffer,
                                                    indexBufferOffset: indexBuffer.offset)
            }
            commandBuffer.addCompletedHandler {
                [weak self] commandBuffer in
                if let strongSelf = self {
                    strongSelf.frameSemaphore.signal()
                    /*
                     value of status    name
                     0               notEnqueued
                     1               enqueued
                     2               committed
                     3               scheduled
                     4               completed
                     5               error
                     */
                    if commandBuffer.status == .error {
                        print("Command Buffer Status Error")
                    }
                }
                return
            }
            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            currentFrameIndex = (currentFrameIndex + 1) % kMaxInFlightFrameCount
        }
    }
}
