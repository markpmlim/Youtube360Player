//
//  SkyboxMesh.swift
//  MetalCubemapping
//
//  Created by Mark Lim Pak Mun on 09/09/2020.
//  Copyright © 2020 Mark Lim Pak Mun. All rights reserved.
//

import Foundation
import Metal
import MetalKit
import SceneKit.ModelIO

class BoxMesh {
    var metalKitMesh: MTKMesh

    init?(withSize size: Float,
          inwardNormals: Bool,
          device: MTLDevice) {
 
        let mdlVertexDescriptor = MDLVertexDescriptor()
        mdlVertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                                               format: MDLVertexFormat.float3,
                                                               offset: 0,
                                                               bufferIndex: 0)
        mdlVertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal,
                                                               format: MDLVertexFormat.float3,
                                                               offset: MemoryLayout<Float>.stride * 3,
                                                               bufferIndex: 0)
        mdlVertexDescriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate,
                                                               format: MDLVertexFormat.float2,
                                                               offset: MemoryLayout<Float>.stride * 6,
                                                               bufferIndex: 0)
        
        mdlVertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.stride * 8)

        let allocator = MTKMeshBufferAllocator(device: device)

        let boxMDLMesh = MDLMesh.newBox(withDimensions: [size,size,size],
                                        segments: [1,1,1],
                                        geometryType: .triangles,
                                        inwardNormals: inwardNormals,
                                        allocator: allocator)
        boxMDLMesh.vertexDescriptor = mdlVertexDescriptor
        do {
            metalKitMesh = try MTKMesh(mesh: boxMDLMesh,
                                       device:device)
        }
        catch let err as NSError {
            print("Can't create box mesh:", err)
            return nil
        }
    }
}
