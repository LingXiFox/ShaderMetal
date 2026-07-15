#pragma once

#import <Metal/Metal.h>

#include <simd/simd.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <span>
#include <string>
#include <string_view>

namespace shadermetal {

using BottomLevelAccelerationStructure = id<MTLAccelerationStructure>;

struct alignas(16) RTLocalLight final {
    // Two packed float4 lanes: positionRadius and colorIntensity.
    std::array<float, 3> position{};
    float radius = 0.0F;
    std::array<float, 3> color{};
    float intensity = 0.0F;
};

static_assert(sizeof(RTLocalLight) == 32, "RTLocalLight must match the Metal ABI");
static_assert(offsetof(RTLocalLight, radius) == 12);
static_assert(offsetof(RTLocalLight, color) == 16);
static_assert(offsetof(RTLocalLight, intensity) == 28);

struct RayTraceLightingInput final {
    id<MTLCommandBuffer> commandBuffer = nil;
    id<MTLAccelerationStructure> topLevelAccelerationStructure = nil;
    id<MTLBuffer> canonicalVertices = nil;
    std::size_t canonicalVertexCount = 0;
    id<MTLBuffer> dynamicCanonicalVertices = nil;
    std::size_t dynamicCanonicalVertexCount = 0;
    id<MTLBuffer> instanceMetadata = nil;
    std::size_t instanceCount = 0;
    // Active BLAS entries must be non-nil and belong to the same Metal device.
    // They are made resident explicitly because the TLAS references them indirectly.
    std::span<const BottomLevelAccelerationStructure> activeBottomLevelStructures;

    // projection reconstructs the view ray. viewToScene then moves its origin
    // and direction into the anchored scene space used by the TLAS.
    simd_float4x4 projection = matrix_identity_float4x4;
    simd_float4x4 viewToScene = matrix_identity_float4x4;
    simd_float3 cameraOrigin = simd_make_float3(0.0F, 0.0F, 0.0F);
    // sunDirection is already expressed in anchored scene space.
    simd_float3 sunDirection = simd_make_float3(0.0F, 1.0F, 0.0F);
    simd_float3 sunRadiance = simd_make_float3(1.0F, 0.96F, 0.86F);
    simd_float3 moonDirection = simd_make_float3(0.0F, -1.0F, 0.0F);
    simd_float3 moonRadiance = simd_make_float3(0.0F, 0.0F, 0.0F);
    simd_float3 skyRadiance = simd_make_float3(0.30F, 0.38F, 0.52F);
    float weatherStrength = 0.0F;
    simd_float3 sceneUpDirection = simd_make_float3(0.0F, 1.0F, 0.0F);
    simd_float3 sceneEast = simd_make_float3(1.0F, 0.0F, 0.0F);
    simd_float3 sceneNorth = simd_make_float3(0.0F, 0.0F, 1.0F);
    simd_float3 worldCameraPosition = simd_make_float3(0.0F, 0.0F, 0.0F);
    bool cameraSubmergedInWater = false;
    bool historyReset = false;
    std::span<const RTLocalLight> localLights;

    id<MTLTexture> worldColor = nil;
    id<MTLTexture> worldDepth = nil;
    NSUInteger outputWidth = 0;
    NSUInteger outputHeight = 0;
    std::uint32_t frameIndex = 0;
    float ambientOcclusionRadius = 1.5F;
    float minimumRayDistance = 0.002F;
    float primaryRayDistance = 4096.0F;
    float indirectRayDistance = 32.0F;
};

class RayTracePass final {
public:
    static constexpr std::size_t kCanonicalVertexStride = 32;
    static constexpr std::size_t kInstanceMetadataStride = 64;
    static constexpr NSUInteger kTextureTableSize = 4096;
    static constexpr NSUInteger kMaxLocalLights = 128;

    // Metadata ABI: three float4 normal-to-scene columns at byte offsets
    // 0/16/32, then uint vertexOffset, uint vertexCount, int textureId, and
    // uint flags at 48/52/56/60. instance_id indexes this compact array.

    static RayTracePass &shared();

    // Loads the single-source RayTrace.metal from the app bundle or source tree,
    // then compiles it as MSL 3.0.
    bool initialize(id<MTLDevice> device, std::string &error);
    // Allows tests or packaged-resource loaders to provide the same source directly.
    bool initialize(id<MTLDevice> device, std::string_view source,
                    std::string &error);

    bool encodeLighting(const RayTraceLightingInput &input, std::string &error);
    bool encodeComposite(id<MTLCommandBuffer> commandBuffer,
                         id<MTLTexture> worldColor,
                         id<MTLTexture> bgra8Drawable,
                         std::string &error);

    id<MTLTexture> lightingTexture() const;
    void invalidateHistory();
    void close();

    RayTracePass(const RayTracePass &) = delete;
    RayTracePass &operator=(const RayTracePass &) = delete;

private:
    RayTracePass() = default;
    ~RayTracePass() = default;

    bool initializeLocked(id<MTLDevice> device, std::string_view source,
                          std::string &error);
    bool ensureLightingTexturesLocked(NSUInteger inputWidth,
                                      NSUInteger inputHeight,
                                      NSUInteger outputWidth,
                                      NSUInteger outputHeight,
                                      std::string &error);
    bool ensureMetalFXResourcesLocked(NSUInteger inputWidth,
                                      NSUInteger inputHeight,
                                      NSUInteger outputWidth,
                                      NSUInteger outputHeight,
                                      std::string &diagnostic);
    void disableMetalFXLocked(std::string_view diagnostic);

    mutable std::mutex mutex_;
    id<MTLDevice> device_ = nil;
    id<MTLLibrary> library_ = nil;
    id<MTLComputePipelineState> lightingPipeline_ = nil;
    id<MTLComputePipelineState> temporalPipeline_ = nil;
    id<MTLComputePipelineState> spatialPipeline_ = nil;
    id<MTLRenderPipelineState> compositePipeline_ = nil;
    std::array<id<MTLIntersectionFunctionTable>, 3> intersectionFunctionTables_{};
    id<MTLBuffer> intersectionSceneCountsBuffer_ = nil;
    id<MTLArgumentEncoder> materialArgumentEncoder_ = nil;
    id<MTLBuffer> materialArgumentBuffer_ = nil;
    id<MTLBuffer> materialAvailabilityBuffer_ = nil;
    std::uint64_t materialBindingRevision_ = 0;
    id<MTLBuffer> localLightBuffer_ = nil;
    id<MTLTexture> rawLightingTexture_ = nil;
    id<MTLTexture> currentGeometryTexture_ = nil;
    std::array<id<MTLTexture>, 2> historyRadianceTextures_{};
    std::array<id<MTLTexture>, 2> historyGeometryTextures_{};
    id<MTLTexture> filterScratchTexture_ = nil;
    id<MTLTexture> lightingTexture_ = nil;
    id metalFXDenoisedScaler_ = nil;
    id<MTLTexture> metalFXDepthTexture_ = nil;
    id<MTLTexture> metalFXMotionTexture_ = nil;
    id<MTLTexture> metalFXNormalTexture_ = nil;
    id<MTLTexture> metalFXDiffuseAlbedoTexture_ = nil;
    id<MTLTexture> metalFXSpecularAlbedoTexture_ = nil;
    id<MTLTexture> metalFXRoughnessTexture_ = nil;
    id<MTLTexture> metalFXReactiveMaskTexture_ = nil;
    id<MTLTexture> metalFXExposureTexture_ = nil;
    id<MTLTexture> metalFXOutputTexture_ = nil;
    bool metalFXSupported_ = false;
    bool metalFXRuntimeDisabled_ = false;
    bool metalFXReactiveMaskEnabled_ = false;
    bool usingMetalFXThisFrame_ = false;
    bool metalFXSuccessLogged_ = false;
    bool metalFXFallbackLogged_ = false;
    std::size_t historyReadIndex_ = 0;
    bool historyValid_ = false;
    bool hasPreviousFrame_ = false;
    std::uint32_t previousFrameIndex_ = 0;
    bool hasPreviousFrameIndex_ = false;
    simd_float4x4 previousProjection_ = matrix_identity_float4x4;
    simd_float4x4 previousViewToScene_ = matrix_identity_float4x4;
    simd_float3 previousSceneCamera_ = simd_make_float3(0.0F, 0.0F, 0.0F);
    simd_float3 previousWorldCamera_ = simd_make_float3(0.0F, 0.0F, 0.0F);
    simd_float3 previousViewForward_ = simd_make_float3(0.0F, 0.0F, -1.0F);
    bool previousCameraSubmergedInWater_ = false;
    simd_float4 displayParameters_ = simd_make_float4(1.05F, 0.06F, 1.0F, 0.0F);
};

} // namespace shadermetal
