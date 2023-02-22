//
//  Shaders.metal
//  YouTube360
//
//  Created by Mark Lim Pak Mun on 03/01/2023.
//  Copyright © 2023 Mark Lim Pak Mun. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

// The model has all 3 vertex attributes viz. position, normal & texture coordinates.
struct VertexIn {
    float3 position  [[attribute(0)]];
    float3 normal    [[attribute(1)]];
    float2 texCoords [[attribute(2)]];      // unused
};

struct VertexOut {
    float4 position [[position]];       // clip space
    float4 texCoords;                   //
};

struct Uniforms {
    float4x4 modelViewProjectionMatrix;
};

#define SRGB_ALPHA 0.055

float linear_from_srgb(float x)
{
    if (x <= 0.04045)
        return x / 12.92;
    else
        return powr((x + SRGB_ALPHA) / (1.0 + SRGB_ALPHA), 2.4);
}

float3 linear_from_srgb(float3 rgb)
{
    return float3(linear_from_srgb(rgb.r),
                  linear_from_srgb(rgb.g),
                  linear_from_srgb(rgb.b));
}

float srgb_from_linear(float c)
{
    if (isnan(c))
        c = 0.0;
    if (c > 1.0)
        c = 1.0;
    else if (c < 0.0)
        c = 0.0;
    else if (c < 0.0031308)
        c = 12.92 * c;
    else
        //c = 1.055 * powr(c, 1.0/2.4) - 0.055;
        c = (1.0 + SRGB_ALPHA) * powr(c, 1.0/2.4) - SRGB_ALPHA;

    return c;
}

float3 srgb_from_linear(float3 rgb)
{
    return float3(srgb_from_linear(rgb.r),
                  srgb_from_linear(rgb.g),
                  srgb_from_linear(rgb.b));
}



// size=16 bytes
typedef struct
{
    float4x4 viewProjectionMatrix;
} InstanceParams;


struct MappingVertex {
    float4 position [[position]];       // clip space
    float4 worldPosition;
    uint whichLayer [[render_target_array_index]];
};

vertex MappingVertex
cubeMapVertexShader(VertexIn                vertexIn        [[stage_in]],
                    unsigned int            instanceId      [[instance_id]],
                    device InstanceParams *instanceParms    [[buffer(1)]])
{
    float4 position = float4(vertexIn.position, 1.0);
    
    MappingVertex outVert;
    outVert.whichLayer = instanceId;
    // Transform vertex's position into clip space.
    outVert.position = instanceParms[instanceId].viewProjectionMatrix * position;
    // Its position (in object/model space) will be used to access the equiRectangular map texture.
    // Since there is no model matrix, its vertex position is deemed to be in world space.
    // Another way of looking at things is we may consider that the model matrix is the identity matrix.
    outVert.worldPosition = position;
    return outVert;
}

#define RADIANS(x) x*M_PI_F/180.0

// Rotate an angle about z-axis thru its centre of rotation (0.0, 0.0)
// positive values ==> clockwise
float2 rotate2d(float2 uv, float angle)
{
    float s = sin(RADIANS(angle));
    float c = cos(RADIANS(angle));
    float2x2 mat2 = float2x2(float2(c, -s), float2(s, c));
    return mat2 * uv;
}

// These are the positions of the top left corner of each square making
//  up the 3x2 rectangular grid of 12 squares.
constant float2 topLeftCorners[] = {
    float2(2.0, 0.0),   // +X face
    float2(0.0, 0.0),   // -X face
    float2(2.0, 1.0),   // +Y face
    float2(0.0, 1.0),   // -Y face
    float2(1.0, 0.0),   // +Z face
    float2(1.0, 1.0),   // -Z face
};

float2 map2CompactGrid(float2 uv, uint faceIndex)
{
    // Translate the uv of the fragment to the correct square.
    float2 uv2 = uv + topLeftCorners[faceIndex];
    // Range of uv2.x: [0.0, 3.0]
    // Range of uv2.y: [0.0, 2.0]
    // Caller must do a scale down before accessing the compact map texture.
    return uv2;
}

// We already know the face index since we are applying layer rendering in Metal.
float2 directionToCubeFaceUV(float3 direction,
                             uint faceIndex)
{
    float absX = fabs(direction.x);
    float absY = fabs(direction.y);
    float absZ = fabs(direction.z);

    float maxAxis = 0.0;
    float2 uv = float2(0.0);

    switch(faceIndex)
    {
        case 0:
            maxAxis = absX;
            uv = float2(-direction.z, -direction.y);
            break;
        case 1:
            maxAxis = absX;
            uv = float2(direction.z, -direction.y);
            break;
        case 2:
            maxAxis = absY;
            uv = float2(direction.x, direction.z);
            uv = rotate2d(uv, 90.0);
            break;
        case 3:
            maxAxis = absY;
            uv = float2(direction.x, -direction.z);
            uv = rotate2d(uv, 90.0);
            break;
        case 4:
            maxAxis = absZ;
            uv = float2(direction.x, -direction.y);
            break;
        case 5:
            maxAxis = absZ;
            uv = float2(-direction.x, -direction.y);
            uv = rotate2d(uv, -90.0);
            break;
    }
    // Convert range from -1 to 1 to 0 to 1
    uv = 0.5 * (uv/maxAxis + 1.0);
    return uv;
}

float2 sampleCompactMap(float3 direction, uint faceIndex)
{
    float2 uv = directionToCubeFaceUV(direction, faceIndex);
    uv = map2CompactGrid(uv, faceIndex);
    uv /= float2(3.0, 2.0);
    return uv;
}


// Render to an offscreen texture object in this case a face of
// a cubemap texture.
fragment half4
outputCubeMapTexture(MappingVertex   mappingVertex  [[stage_in]],
                     texture2d<half> compactMap     [[texture(0)]])
{
    
    constexpr sampler mapSampler(s_address::clamp_to_edge,  // default
                                 t_address::clamp_to_edge,
                                 mip_filter::linear,
                                 mag_filter::linear,
                                 min_filter::linear);

    // Magnitude of direction is 1.0 upon normalization.
    float3 direction = normalize(mappingVertex.worldPosition.xyz);
    uint faceIndex = mappingVertex.whichLayer;
    float2 uv = sampleCompactMap(direction, faceIndex);
    half4 color = compactMap.sample(mapSampler, uv);
    return color;
}


// Draw the skybox
vertex VertexOut
SkyboxVertexShader(VertexIn vertexIn             [[stage_in]],
                   constant Uniforms &uniforms   [[buffer(1)]])
{
    float4 position = float4(vertexIn.position, 1.0);

    VertexOut outVert;
    // Transform vertex's position into clip space.
    outVert.position = uniforms.modelViewProjectionMatrix * position;
    // Its position (in object/model space) will be used to access the cube map texture.
    outVert.texCoords = position;
    return outVert;
}

// The Uniforms are not used but to be declared.
fragment float4
CubeLookupShader(VertexOut fragmentIn               [[stage_in]],
                 texturecube<float> cubemapTexture  [[texture(0)]],
                 constant Uniforms & uniforms       [[buffer(1)]])
{
    constexpr sampler cubeSampler(mip_filter::linear,
                                  mag_filter::linear,
                                  min_filter::linear);
    // Don't have to flip horizontally anymore.
    float3 texCoords = float3(fragmentIn.texCoords.x, fragmentIn.texCoords.y, fragmentIn.texCoords.z);
    return cubemapTexture.sample(cubeSampler, texCoords);
}

/// Based on code from http://mczonk.de/video-texture-streaming-with-metal/
kernel void
YCbCrColorConversion(texture2d<float, access::read>   yTexture  [[texture(0)]],
                     texture2d<float, access::read> cbcrTexture [[texture(1)]],
                     texture2d<float, access::write> outTexture [[texture(2)]],
                     uint2                              gid     [[thread_position_in_grid]])
{
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();
    uint column = gid.x;
    uint row = gid.y;
    if ((column >= width) || (row >= height)) {
        // In case the size of the texture does not match the size of the grid.
        // Return early if the pixel is out of bounds
        return;
    }
    float3 colorOffset = float3(-(16.0/255.0), -0.5, -0.5);

    // BT.601, which is the standard for SDTV.
    float3x3 colorMatrix = float3x3(
        float3(1.164,  1.164, 1.164),
        float3(0.000, -0.392, 2.017),
        float3(1.596, -0.813, 0.000)
    );

    // BT.709, which is the standard for HDTV.
    float3x3 kColorConversion709 = float3x3(
        float3(1.164,  1.164, 1.164),
        float3(0.000, -0.213, 2.112),
        float3(1.793, -0.533, 0.000)
    );

    uint2 cbcrCoordinates = uint2(gid.x / 2, gid.y / 2); // half the size because we are using a 4:2:0 chroma subsampling

    float y = yTexture.read(gid).r;
    float2 cbcr = cbcrTexture.read(cbcrCoordinates).rg;

    float3 ycbcr = float3(y, cbcr);

    float3 rgb = kColorConversion709 * (ycbcr + colorOffset);

    outTexture.write(float4(float3(rgb), 1.0), gid);
}

