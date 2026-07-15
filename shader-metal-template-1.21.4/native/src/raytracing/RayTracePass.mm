#include "raytracing/RayTracePass.hpp"

#import <MetalFX/MetalFX.h>

#include "resource/SamplerCache.hpp"
#include "resource/TextureManager.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

namespace shadermetal {
namespace {

#include "RayTraceMetal.inc"

constexpr NSUInteger kLocalLightFramesInFlight = 3;
constexpr NSUInteger kLocalLightFrameStride =
    RayTracePass::kMaxLocalLights * sizeof(RTLocalLight);
constexpr NSUInteger kIntersectionSceneCountFrameStride = 256;
constexpr float kProjectionChangeEpsilon = 2.0e-2F;
constexpr float kCameraCutDistance = 8.0F;
constexpr float kCameraCutDistanceSquared =
    kCameraCutDistance * kCameraCutDistance;
constexpr float kCameraCutCosine = 0.8660254037844386F;

struct alignas(16) RayTraceUniforms final {
    simd_float4x4 inverseProjection;
    simd_float4x4 viewToScene;
    simd_float4x4 sceneToCurrentClip;
    simd_float4x4 sceneToPreviousClip;
    simd_float4 cameraAndMinimumDistance;
    simd_float4 previousSceneCameraAndHistory;
    simd_float4 sunDirectionAndAORadius;
    simd_float4 sunRadiance;
    simd_float4 moonDirection;
    simd_float4 moonRadiance;
    simd_float4 skyRadiance;
    simd_float4 sceneUpAndTime;
    simd_float4 sceneEast;
    simd_float4 sceneNorth;
    simd_float4 worldCamera;
    simd_float4 traceParameters;
    simd_uint4 geometryCounts;
    simd_uint4 frameData;
};

static_assert(sizeof(RayTraceUniforms) == 480);
static_assert(offsetof(RayTraceUniforms, sceneToCurrentClip) == 128);
static_assert(offsetof(RayTraceUniforms, sceneToPreviousClip) == 192);
static_assert(offsetof(RayTraceUniforms, cameraAndMinimumDistance) == 256);
static_assert(offsetof(RayTraceUniforms, traceParameters) == 432);
static_assert(offsetof(RayTraceUniforms, geometryCounts) == 448);
static_assert(offsetof(RayTraceUniforms, frameData) == 464);

std::string metalErrorMessage(NSError *error, std::string_view fallback) {
    if (error != nil && error.localizedDescription != nil) {
        return std::string(error.localizedDescription.UTF8String);
    }
    return std::string(fallback);
}

bool hasShaderReadUsage(id<MTLTexture> texture) {
    return (texture.usage & MTLTextureUsageShaderRead) != 0;
}

bool finitePositive(float value) {
    return std::isfinite(value) && value > 0.0F;
}

bool finiteVector(simd_float3 value) {
    return std::isfinite(value.x) && std::isfinite(value.y) &&
        std::isfinite(value.z);
}

bool finiteNonNegativeVector(simd_float3 value) {
    return finiteVector(value) && value.x >= 0.0F && value.y >= 0.0F &&
        value.z >= 0.0F;
}

bool finiteMatrix(simd_float4x4 value) {
    for (std::size_t column = 0; column < 4; ++column) {
        for (std::size_t row = 0; row < 4; ++row) {
            if (!std::isfinite(value.columns[column][row])) {
                return false;
            }
        }
    }
    return true;
}

bool finiteTextureDimensions(NSUInteger width, NSUInteger height) {
    return width != 0 && height != 0 &&
        width <= std::numeric_limits<std::uint32_t>::max() &&
        height <= std::numeric_limits<std::uint32_t>::max();
}

bool textureMatches(id<MTLTexture> texture, id<MTLDevice> device,
                    NSUInteger width, NSUInteger height) {
    constexpr MTLTextureUsage requiredUsage =
        MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return texture != nil && texture.device == device &&
        texture.textureType == MTLTextureType2D &&
        texture.pixelFormat == MTLPixelFormatRGBA16Float &&
        texture.width == width && texture.height == height &&
        (texture.usage & requiredUsage) == requiredUsage;
}

bool textureMatches(id<MTLTexture> texture, id<MTLDevice> device,
                    MTLPixelFormat format, NSUInteger width, NSUInteger height,
                    MTLTextureUsage requiredUsage) {
    return texture != nil && texture.device == device &&
        texture.textureType == MTLTextureType2D &&
        texture.pixelFormat == format && texture.width == width &&
        texture.height == height &&
        (texture.usage & requiredUsage) == requiredUsage;
}

id<MTLTexture> makeLightingTexture(id<MTLDevice> device, NSUInteger width,
                                   NSUInteger height, NSString *label) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    texture.label = label;
    return texture;
}

id<MTLTexture> makePrivateTexture(id<MTLDevice> device,
                                  MTLPixelFormat format,
                                  NSUInteger width,
                                  NSUInteger height,
                                  MTLTextureUsage usage,
                                  NSString *label) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:format
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = usage;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    texture.label = label;
    return texture;
}

float radicalInverse(std::uint32_t index, std::uint32_t base) {
    float result = 0.0F;
    float inversePower = 1.0F / static_cast<float>(base);
    while (index != 0U) {
        result += static_cast<float>(index % base) * inversePower;
        index /= base;
        inversePower /= static_cast<float>(base);
    }
    return result;
}

simd_float2 metalFXJitter(std::uint32_t frameIndex) {
    const std::uint32_t sample = frameIndex % 32U + 1U;
    return simd_make_float2(radicalInverse(sample, 2U) - 0.5F,
                            radicalInverse(sample, 3U) - 0.5F);
}

bool transformedPoint(simd_float4x4 matrix, simd_float3 point,
                      simd_float3 &result) {
    const simd_float4 transformed = simd_mul(
        matrix, simd_make_float4(point.x, point.y, point.z, 1.0F));
    if (!std::isfinite(transformed.x) || !std::isfinite(transformed.y) ||
        !std::isfinite(transformed.z) || !std::isfinite(transformed.w) ||
        std::abs(transformed.w) < 1.0e-8F) {
        return false;
    }
    result = simd_make_float3(transformed.x, transformed.y, transformed.z) /
        transformed.w;
    return finiteVector(result);
}

bool viewForward(simd_float4x4 viewToScene, simd_float3 &result) {
    const simd_float4 transformed = simd_mul(
        viewToScene, simd_make_float4(0.0F, 0.0F, -1.0F, 0.0F));
    result = simd_make_float3(transformed.x, transformed.y, transformed.z);
    const float lengthSquared = simd_length_squared(result);
    if (!finiteVector(result) || !std::isfinite(lengthSquared) ||
        lengthSquared < 1.0e-8F) {
        return false;
    }
    result *= 1.0F / std::sqrt(lengthSquared);
    return true;
}

bool matrixMateriallyDifferent(simd_float4x4 left, simd_float4x4 right) {
    for (std::size_t column = 0; column < 4; ++column) {
        for (std::size_t row = 0; row < 4; ++row) {
            const float leftValue = left.columns[column][row];
            const float rightValue = right.columns[column][row];
            const float scale = std::max(
                1.0F, std::max(std::abs(leftValue), std::abs(rightValue)));
            if (std::abs(leftValue - rightValue) >
                kProjectionChangeEpsilon * scale) {
                return true;
            }
        }
    }
    return false;
}

float smoothstep(float edge0, float edge1, float value) {
    const float t = std::clamp((value - edge0) / (edge1 - edge0), 0.0F, 1.0F);
    return t * t * (3.0F - 2.0F * t);
}

void dispatch2D(id<MTLComputeCommandEncoder> encoder,
                id<MTLComputePipelineState> pipeline,
                NSUInteger width, NSUInteger height) {
    constexpr NSUInteger kPreferredWidth = 8;
    constexpr NSUInteger kPreferredHeight = 8;
    const NSUInteger maxThreads = std::max<NSUInteger>(
        1, pipeline.maxTotalThreadsPerThreadgroup);
    const NSUInteger threadWidth = std::min(kPreferredWidth, maxThreads);
    const NSUInteger threadHeight = std::min(
        kPreferredHeight,
        std::max<NSUInteger>(1, maxThreads / threadWidth));
    [encoder dispatchThreads:MTLSizeMake(width, height, 1)
         threadsPerThreadgroup:MTLSizeMake(threadWidth, threadHeight, 1)];
}

bool loadDefaultMetalSource(std::string &source, std::string &error) {
    error.clear();
    source.assign(
        reinterpret_cast<const char *>(shadermetal_raytrace_metal),
        static_cast<std::size_t>(shadermetal_raytrace_metal_len));
    if (source.empty()) {
        error = "embedded RayTrace.metal source is empty";
        return false;
    }
    return true;
}

} // namespace

RayTracePass &RayTracePass::shared() {
    static RayTracePass pass;
    return pass;
}

bool RayTracePass::initialize(id<MTLDevice> device, std::string &error) {
    std::string source;
    if (!loadDefaultMetalSource(source, error)) {
        return false;
    }
    return initialize(device, source, error);
}

bool RayTracePass::initialize(id<MTLDevice> device, std::string_view source,
                              std::string &error) {
    std::lock_guard lock(mutex_);
    return initializeLocked(device, source, error);
}

bool RayTracePass::initializeLocked(id<MTLDevice> device, std::string_view source,
                                    std::string &error) {
    error.clear();
    if (device == nil) {
        error = "cannot initialize ray tracing without a Metal device";
        return false;
    }
    if (!device.supportsRaytracing) {
        error = "the selected Metal device does not support hardware ray tracing";
        return false;
    }
    if (source.empty()) {
        error = "ray-tracing Metal source is empty";
        return false;
    }
    if (device_ == device && library_ != nil && lightingPipeline_ != nil &&
        temporalPipeline_ != nil && spatialPipeline_ != nil &&
        compositePipeline_ != nil && intersectionFunctionTables_[0] != nil &&
        intersectionFunctionTables_[1] != nil &&
        intersectionFunctionTables_[2] != nil &&
        intersectionSceneCountsBuffer_ != nil &&
        materialArgumentEncoder_ != nil && localLightBuffer_ != nil) {
        return true;
    }

    NSString *metalSource = [[NSString alloc] initWithBytes:source.data()
                                                     length:source.size()
                                                   encoding:NSUTF8StringEncoding];
    if (metalSource == nil) {
        error = "ray-tracing Metal source is not valid UTF-8";
        return false;
    }

    MTLCompileOptions *compileOptions = [[MTLCompileOptions alloc] init];
    compileOptions.languageVersion = MTLLanguageVersion3_0;
    NSError *libraryError = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:metalSource
                                                  options:compileOptions
                                                    error:&libraryError];
    if (library == nil) {
        error = "ray-tracing MSL 3.0 compilation failed: " +
            metalErrorMessage(libraryError, "Metal returned no library");
        return false;
    }

    id<MTLFunction> lightingFunction = [library newFunctionWithName:@"rayTraceGI"];
    id<MTLFunction> temporalFunction =
        [library newFunctionWithName:@"temporalResolve"];
    id<MTLFunction> spatialFunction =
        [library newFunctionWithName:@"spatialFilter"];
    id<MTLFunction> alphaIntersectionFunction =
        [library newFunctionWithName:@"alphaTestIntersection"];
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"fullscreenTriangle"];
    id<MTLFunction> fragmentFunction =
        [library newFunctionWithName:@"compositeRayTracedLighting"];
    if (lightingFunction == nil || temporalFunction == nil ||
        spatialFunction == nil || alphaIntersectionFunction == nil ||
        vertexFunction == nil || fragmentFunction == nil) {
        error = "ray-tracing Metal library is missing one or more required entry points";
        return false;
    }

    id<MTLArgumentEncoder> materialArgumentEncoder =
        [lightingFunction newArgumentEncoderWithBufferIndex:4];
    if (materialArgumentEncoder == nil || materialArgumentEncoder.encodedLength == 0) {
        error = "ray-tracing GI shader has no usable material argument encoder";
        return false;
    }

    MTLLinkedFunctions *linkedFunctions = [MTLLinkedFunctions linkedFunctions];
    linkedFunctions.functions = @[alphaIntersectionFunction];
    MTLComputePipelineDescriptor *computeDescriptor =
        [[MTLComputePipelineDescriptor alloc] init];
    computeDescriptor.label = @"ShaderMetal Hardware Ray-Traced GI";
    computeDescriptor.computeFunction = lightingFunction;
    computeDescriptor.linkedFunctions = linkedFunctions;

    NSError *computeError = nil;
    id<MTLComputePipelineState> lightingPipeline =
        [device newComputePipelineStateWithDescriptor:computeDescriptor
                                              options:MTLPipelineOptionNone
                                           reflection:nil
                                                error:&computeError];
    if (lightingPipeline == nil) {
        error = "ray-tracing compute pipeline creation failed: " +
            metalErrorMessage(computeError, "Metal returned no compute pipeline");
        return false;
    }

    NSError *temporalError = nil;
    id<MTLComputePipelineState> temporalPipeline =
        [device newComputePipelineStateWithFunction:temporalFunction
                                               error:&temporalError];
    if (temporalPipeline == nil) {
        error = "ray-tracing temporal pipeline creation failed: " +
            metalErrorMessage(temporalError, "Metal returned no compute pipeline");
        return false;
    }

    NSError *spatialError = nil;
    id<MTLComputePipelineState> spatialPipeline =
        [device newComputePipelineStateWithFunction:spatialFunction
                                               error:&spatialError];
    if (spatialPipeline == nil) {
        error = "ray-tracing spatial pipeline creation failed: " +
            metalErrorMessage(spatialError, "Metal returned no compute pipeline");
        return false;
    }

    id<MTLFunctionHandle> alphaIntersectionHandle =
        [lightingPipeline functionHandleWithFunction:alphaIntersectionFunction];
    if (alphaIntersectionHandle == nil) {
        error = "ray-tracing pipeline did not expose the linked alpha intersection "
            "function";
        return false;
    }
    MTLIntersectionFunctionTableDescriptor *tableDescriptor =
        [MTLIntersectionFunctionTableDescriptor intersectionFunctionTableDescriptor];
    tableDescriptor.functionCount = 1;
    std::array<id<MTLIntersectionFunctionTable>, kLocalLightFramesInFlight>
        intersectionFunctionTables{};
    for (NSUInteger index = 0; index < intersectionFunctionTables.size(); ++index) {
        id<MTLIntersectionFunctionTable> table =
            [lightingPipeline newIntersectionFunctionTableWithDescriptor:
                tableDescriptor];
        if (table == nil) {
            error = "Metal failed to allocate an alpha intersection function table";
            return false;
        }
        table.label = [NSString stringWithFormat:
            @"ShaderMetal Alpha Intersection Table %lu",
            static_cast<unsigned long>(index)];
        [table setFunction:alphaIntersectionHandle atIndex:0];
        intersectionFunctionTables[index] = table;
    }

    id<MTLBuffer> intersectionSceneCountsBuffer = [device
        newBufferWithLength:kLocalLightFramesInFlight *
            kIntersectionSceneCountFrameStride
                    options:MTLResourceStorageModeShared];
    if (intersectionSceneCountsBuffer == nil ||
        intersectionSceneCountsBuffer.contents == nullptr) {
        error = "Metal failed to allocate the intersection-function scene-count ring";
        return false;
    }
    intersectionSceneCountsBuffer.label =
        @"ShaderMetal Intersection Scene Count Ring";

    MTLRenderPipelineDescriptor *renderDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    renderDescriptor.label = @"ShaderMetal Ray-Traced Lighting Composite";
    renderDescriptor.vertexFunction = vertexFunction;
    renderDescriptor.fragmentFunction = fragmentFunction;
    renderDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    NSError *renderError = nil;
    id<MTLRenderPipelineState> compositePipeline =
        [device newRenderPipelineStateWithDescriptor:renderDescriptor error:&renderError];
    if (compositePipeline == nil) {
        error = "ray-tracing composite pipeline creation failed: " +
            metalErrorMessage(renderError, "Metal returned no render pipeline");
        return false;
    }

    id<MTLBuffer> localLightBuffer = [device
        newBufferWithLength:kLocalLightFramesInFlight * kLocalLightFrameStride
                    options:MTLResourceStorageModeShared];
    if (localLightBuffer == nil || localLightBuffer.contents == nullptr) {
        error = "Metal failed to allocate the shared local-light buffer";
        return false;
    }
    localLightBuffer.label = @"ShaderMetal Local Light Ring";

    device_ = device;
    library_ = library;
    lightingPipeline_ = lightingPipeline;
    temporalPipeline_ = temporalPipeline;
    spatialPipeline_ = spatialPipeline;
    compositePipeline_ = compositePipeline;
    intersectionFunctionTables_ = intersectionFunctionTables;
    intersectionSceneCountsBuffer_ = intersectionSceneCountsBuffer;
    materialArgumentEncoder_ = materialArgumentEncoder;
    materialArgumentBuffer_ = nil;
    materialAvailabilityBuffer_ = nil;
    materialBindingRevision_ = 0;
    localLightBuffer_ = localLightBuffer;
    rawLightingTexture_ = nil;
    currentGeometryTexture_ = nil;
    historyRadianceTextures_.fill(nil);
    historyGeometryTextures_.fill(nil);
    filterScratchTexture_ = nil;
    lightingTexture_ = nil;
    metalFXDenoisedScaler_ = nil;
    metalFXDepthTexture_ = nil;
    metalFXMotionTexture_ = nil;
    metalFXNormalTexture_ = nil;
    metalFXDiffuseAlbedoTexture_ = nil;
    metalFXSpecularAlbedoTexture_ = nil;
    metalFXRoughnessTexture_ = nil;
    metalFXReactiveMaskTexture_ = nil;
    metalFXExposureTexture_ = nil;
    metalFXOutputTexture_ = nil;
    metalFXSupported_ = false;
    if (@available(macOS 26.0, *)) {
        metalFXSupported_ =
            [MTLFXTemporalDenoisedScalerDescriptor supportsDevice:device];
    }
    metalFXRuntimeDisabled_ = false;
    metalFXReactiveMaskEnabled_ = false;
    usingMetalFXThisFrame_ = false;
    metalFXSuccessLogged_ = false;
    metalFXFallbackLogged_ = false;
    historyReadIndex_ = 0;
    historyValid_ = false;
    hasPreviousFrame_ = false;
    previousFrameIndex_ = 0;
    hasPreviousFrameIndex_ = false;
    previousProjection_ = matrix_identity_float4x4;
    previousViewToScene_ = matrix_identity_float4x4;
    previousSceneCamera_ = simd_make_float3(0.0F, 0.0F, 0.0F);
    previousWorldCamera_ = simd_make_float3(0.0F, 0.0F, 0.0F);
    previousViewForward_ = simd_make_float3(0.0F, 0.0F, -1.0F);
    previousCameraSubmergedInWater_ = false;
    displayParameters_ = simd_make_float4(0.90F, 0.02F, 1.0F, 0.0F);
    if (!metalFXSupported_) {
        NSLog(@"[ShaderMetal] MetalFX temporal denoised upscaling unavailable; "
               "using the built-in temporal/spatial fallback");
        metalFXFallbackLogged_ = true;
    }
    return true;
}

bool RayTracePass::ensureLightingTexturesLocked(NSUInteger width,
                                                NSUInteger height,
                                                NSUInteger outputWidth,
                                                NSUInteger outputHeight,
                                                std::string &error) {
    constexpr MTLTextureUsage guideUsage =
        MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    const bool resourcesMatch =
        textureMatches(rawLightingTexture_, device_, width, height) &&
        textureMatches(currentGeometryTexture_, device_, width, height) &&
        textureMatches(historyRadianceTextures_[0], device_, width, height) &&
        textureMatches(historyRadianceTextures_[1], device_, width, height) &&
        textureMatches(historyGeometryTextures_[0], device_, width, height) &&
        textureMatches(historyGeometryTextures_[1], device_, width, height) &&
        textureMatches(filterScratchTexture_, device_, width, height) &&
        textureMatches(lightingTexture_, device_, width, height) &&
        textureMatches(metalFXDepthTexture_, device_, MTLPixelFormatR32Float,
                       width, height, guideUsage) &&
        textureMatches(metalFXMotionTexture_, device_, MTLPixelFormatRG16Float,
                       width, height, guideUsage) &&
        textureMatches(metalFXNormalTexture_, device_, MTLPixelFormatRGBA16Float,
                       width, height, guideUsage) &&
        textureMatches(metalFXDiffuseAlbedoTexture_, device_,
                       MTLPixelFormatRGBA16Float, width, height, guideUsage) &&
        textureMatches(metalFXSpecularAlbedoTexture_, device_,
                       MTLPixelFormatRGBA16Float, width, height, guideUsage) &&
        textureMatches(metalFXRoughnessTexture_, device_, MTLPixelFormatR16Float,
                       width, height, guideUsage) &&
        textureMatches(metalFXReactiveMaskTexture_, device_,
                       MTLPixelFormatR8Unorm, width, height, guideUsage);

    if (device_ == nil || !finiteTextureDimensions(width, height) ||
        !finiteTextureDimensions(outputWidth, outputHeight)) {
        error = "cannot allocate ray-tracing history with invalid dimensions";
        return false;
    }

    if (!resourcesMatch) {
        historyValid_ = false;
        usingMetalFXThisFrame_ = false;

        id<MTLTexture> rawLighting = makeLightingTexture(
            device_, width, height, @"ShaderMetal Raw Ray-Traced Lighting");
        id<MTLTexture> currentGeometry = makeLightingTexture(
            device_, width, height, @"ShaderMetal Current RT Geometry");
        std::array<id<MTLTexture>, 2> historyRadiance{
            makeLightingTexture(device_, width, height,
                                @"ShaderMetal RT Radiance History A"),
            makeLightingTexture(device_, width, height,
                                @"ShaderMetal RT Radiance History B")};
        std::array<id<MTLTexture>, 2> historyGeometry{
            makeLightingTexture(device_, width, height,
                                @"ShaderMetal RT Geometry History A"),
            makeLightingTexture(device_, width, height,
                                @"ShaderMetal RT Geometry History B")};
        id<MTLTexture> filterScratch = makeLightingTexture(
            device_, width, height, @"ShaderMetal RT Spatial Filter Scratch");
        id<MTLTexture> lighting = makeLightingTexture(
            device_, width, height, @"ShaderMetal Filtered Ray-Traced Lighting");
        id<MTLTexture> depth = makePrivateTexture(
            device_, MTLPixelFormatR32Float, width, height, guideUsage,
            @"ShaderMetal MetalFX NDC Depth");
        id<MTLTexture> motion = makePrivateTexture(
            device_, MTLPixelFormatRG16Float, width, height, guideUsage,
            @"ShaderMetal MetalFX Motion");
        id<MTLTexture> normal = makePrivateTexture(
            device_, MTLPixelFormatRGBA16Float, width, height, guideUsage,
            @"ShaderMetal MetalFX World Normal");
        id<MTLTexture> diffuse = makePrivateTexture(
            device_, MTLPixelFormatRGBA16Float, width, height, guideUsage,
            @"ShaderMetal MetalFX Diffuse Albedo");
        id<MTLTexture> specular = makePrivateTexture(
            device_, MTLPixelFormatRGBA16Float, width, height, guideUsage,
            @"ShaderMetal MetalFX Specular Albedo");
        id<MTLTexture> roughness = makePrivateTexture(
            device_, MTLPixelFormatR16Float, width, height, guideUsage,
            @"ShaderMetal MetalFX Roughness");
        id<MTLTexture> reactive = makePrivateTexture(
            device_, MTLPixelFormatR8Unorm, width, height, guideUsage,
            @"ShaderMetal MetalFX Reactive Mask");

        if (rawLighting == nil || currentGeometry == nil ||
            historyRadiance[0] == nil || historyRadiance[1] == nil ||
            historyGeometry[0] == nil || historyGeometry[1] == nil ||
            filterScratch == nil || lighting == nil || depth == nil ||
            motion == nil || normal == nil || diffuse == nil ||
            specular == nil || roughness == nil || reactive == nil) {
            error = "Metal failed to allocate the ray-tracing and MetalFX "
                "guide targets (" + std::to_string(width) + "x" +
                std::to_string(height) + ")";
            return false;
        }

        rawLightingTexture_ = rawLighting;
        currentGeometryTexture_ = currentGeometry;
        historyRadianceTextures_ = historyRadiance;
        historyGeometryTextures_ = historyGeometry;
        filterScratchTexture_ = filterScratch;
        lightingTexture_ = lighting;
        metalFXDepthTexture_ = depth;
        metalFXMotionTexture_ = motion;
        metalFXNormalTexture_ = normal;
        metalFXDiffuseAlbedoTexture_ = diffuse;
        metalFXSpecularAlbedoTexture_ = specular;
        metalFXRoughnessTexture_ = roughness;
        metalFXReactiveMaskTexture_ = reactive;
        historyReadIndex_ = 0;
    }

    std::string metalFXDiagnostic;
    if (metalFXSupported_ && !metalFXRuntimeDisabled_ &&
        !ensureMetalFXResourcesLocked(width, height, outputWidth, outputHeight,
                                      metalFXDiagnostic)) {
        disableMetalFXLocked(metalFXDiagnostic);
    }
    return true;
}

bool RayTracePass::ensureMetalFXResourcesLocked(NSUInteger inputWidth,
                                                NSUInteger inputHeight,
                                                NSUInteger outputWidth,
                                                NSUInteger outputHeight,
                                                std::string &diagnostic) {
    diagnostic.clear();
    if (!metalFXSupported_ || metalFXRuntimeDisabled_) {
        diagnostic = "MetalFX temporal denoised scaling is unavailable";
        return false;
    }

    if (@available(macOS 26.0, *)) {
        id<MTLFXTemporalDenoisedScaler> existingScaler =
            metalFXDenoisedScaler_;
        const bool scalerMatches = existingScaler != nil &&
            existingScaler.inputWidth == inputWidth &&
            existingScaler.inputHeight == inputHeight &&
            existingScaler.outputWidth == outputWidth &&
            existingScaler.outputHeight == outputHeight &&
            textureMatches(metalFXExposureTexture_, device_,
                           MTLPixelFormatR16Float, 1, 1,
                           MTLTextureUsageShaderRead);
        if (scalerMatches &&
            textureMatches(metalFXOutputTexture_, device_,
                           MTLPixelFormatRGBA16Float, outputWidth, outputHeight,
                           MTLTextureUsageShaderRead |
                               existingScaler.outputTextureUsage)) {
            return true;
        }

        metalFXDenoisedScaler_ = nil;
        metalFXExposureTexture_ = nil;
        metalFXOutputTexture_ = nil;
        metalFXReactiveMaskEnabled_ = false;
        historyValid_ = false;

        MTLFXTemporalDenoisedScalerDescriptor *descriptor =
            [[MTLFXTemporalDenoisedScalerDescriptor alloc] init];
        descriptor.colorTextureFormat = MTLPixelFormatRGBA16Float;
        descriptor.depthTextureFormat = MTLPixelFormatR32Float;
        descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
        descriptor.diffuseAlbedoTextureFormat = MTLPixelFormatRGBA16Float;
        descriptor.specularAlbedoTextureFormat = MTLPixelFormatRGBA16Float;
        descriptor.normalTextureFormat = MTLPixelFormatRGBA16Float;
        descriptor.roughnessTextureFormat = MTLPixelFormatR16Float;
        descriptor.outputTextureFormat = MTLPixelFormatRGBA16Float;
        descriptor.inputWidth = inputWidth;
        descriptor.inputHeight = inputHeight;
        descriptor.outputWidth = outputWidth;
        descriptor.outputHeight = outputHeight;
        // The game owns exposure and tone mapping. Letting MetalFX auto-expose
        // the noisy path-traced input and then exposing it again in composite
        // amplifies variance and makes brightness depend on the current view.
        descriptor.autoExposureEnabled = NO;
        descriptor.requiresSynchronousInitialization = NO;
        descriptor.specularHitDistanceTextureEnabled = NO;
        descriptor.denoiseStrengthMaskTextureEnabled = NO;
        descriptor.transparencyOverlayTextureEnabled = NO;
#if defined(__MAC_27_0) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_27_0
        if (@available(macOS 27.0, *)) {
            descriptor.reactiveMaskTextureEnabled = YES;
            descriptor.reactiveMaskTextureFormat = MTLPixelFormatR8Unorm;
        }
#endif

        id<MTLFXTemporalDenoisedScaler> scaler =
            [descriptor newTemporalDenoisedScalerWithDevice:device_];
        if (scaler == nil) {
            diagnostic = "MetalFX rejected the RGBA16F/R32F/RG16F denoised "
                "scaler contract";
            return false;
        }

        const MTLTextureUsage inputWriteUsage =
            MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        const auto ensureInput = [&] (id<MTLTexture> __strong &texture,
                                      MTLPixelFormat format,
                                      MTLTextureUsage scalerUsage,
                                      NSString *label) -> bool {
            const MTLTextureUsage required = inputWriteUsage | scalerUsage;
            if (textureMatches(texture, device_, format, inputWidth, inputHeight,
                               required)) {
                return true;
            }
            texture = makePrivateTexture(device_, format, inputWidth, inputHeight,
                                         required, label);
            return texture != nil;
        };

        if (!ensureInput(rawLightingTexture_, MTLPixelFormatRGBA16Float,
                         scaler.colorTextureUsage,
                         @"ShaderMetal Raw Ray-Traced Lighting") ||
            !ensureInput(metalFXDepthTexture_, MTLPixelFormatR32Float,
                         scaler.depthTextureUsage,
                         @"ShaderMetal MetalFX NDC Depth") ||
            !ensureInput(metalFXMotionTexture_, MTLPixelFormatRG16Float,
                         scaler.motionTextureUsage,
                         @"ShaderMetal MetalFX Motion") ||
            !ensureInput(metalFXNormalTexture_, MTLPixelFormatRGBA16Float,
                         scaler.normalTextureUsage,
                         @"ShaderMetal MetalFX World Normal") ||
            !ensureInput(metalFXDiffuseAlbedoTexture_,
                         MTLPixelFormatRGBA16Float,
                         scaler.diffuseAlbedoTextureUsage,
                         @"ShaderMetal MetalFX Diffuse Albedo") ||
            !ensureInput(metalFXSpecularAlbedoTexture_,
                         MTLPixelFormatRGBA16Float,
                         scaler.specularAlbedoTextureUsage,
                         @"ShaderMetal MetalFX Specular Albedo") ||
            !ensureInput(metalFXRoughnessTexture_, MTLPixelFormatR16Float,
                         scaler.roughnessTextureUsage,
                         @"ShaderMetal MetalFX Roughness")) {
            diagnostic = "Metal failed to allocate one or more MetalFX inputs "
                "with the usages requested by the scaler";
            return false;
        }

        bool reactiveEnabled = false;
#if defined(__MAC_27_0) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_27_0
        if (@available(macOS 27.0, *)) {
            reactiveEnabled = ensureInput(
                metalFXReactiveMaskTexture_, MTLPixelFormatR8Unorm,
                scaler.reactiveMaskTextureUsage,
                @"ShaderMetal MetalFX Reactive Mask");
            if (!reactiveEnabled) {
                diagnostic = "Metal failed to allocate the MetalFX reactive mask";
                return false;
            }
        }
#endif

        const MTLTextureUsage outputUsage =
            MTLTextureUsageShaderRead | scaler.outputTextureUsage;
        id<MTLTexture> output = makePrivateTexture(
            device_, MTLPixelFormatRGBA16Float, outputWidth, outputHeight,
            outputUsage, @"ShaderMetal MetalFX Denoised Full-Resolution Lighting");
        if (output == nil) {
            diagnostic = "Metal failed to allocate the full-resolution MetalFX output";
            return false;
        }

        MTLTextureDescriptor *exposureDescriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float
                                         width:1
                                        height:1
                                     mipmapped:NO];
        exposureDescriptor.storageMode = MTLStorageModeShared;
        exposureDescriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> exposure = [device_ newTextureWithDescriptor:exposureDescriptor];
        if (exposure == nil) {
            diagnostic = "Metal failed to allocate the fixed MetalFX exposure texture";
            return false;
        }
        const std::uint16_t halfOne = 0x3c00U;
        [exposure replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                   mipmapLevel:0
                     withBytes:&halfOne
                   bytesPerRow:sizeof(halfOne)];
        exposure.label = @"ShaderMetal MetalFX Fixed Exposure";

        metalFXDenoisedScaler_ = scaler;
        metalFXExposureTexture_ = exposure;
        metalFXOutputTexture_ = output;
        metalFXReactiveMaskEnabled_ = reactiveEnabled;
        if (!metalFXSuccessLogged_) {
            NSLog(@"[ShaderMetal] MetalFX temporal denoised upscaling active: "
                   "%lux%lu -> %lux%lu, reactive-mask=%s",
                  static_cast<unsigned long>(inputWidth),
                  static_cast<unsigned long>(inputHeight),
                  static_cast<unsigned long>(outputWidth),
                  static_cast<unsigned long>(outputHeight),
                  reactiveEnabled ? "on" : "off");
            metalFXSuccessLogged_ = true;
        }
        return true;
    }

    diagnostic = "MetalFX temporal denoised scaling requires macOS 26 or later";
    return false;
}

void RayTracePass::disableMetalFXLocked(std::string_view diagnostic) {
    metalFXDenoisedScaler_ = nil;
    metalFXExposureTexture_ = nil;
    metalFXOutputTexture_ = nil;
    metalFXReactiveMaskEnabled_ = false;
    usingMetalFXThisFrame_ = false;
    metalFXRuntimeDisabled_ = true;
    if (!metalFXFallbackLogged_) {
        NSString *reason = diagnostic.empty()
            ? @"unknown MetalFX initialization failure"
            : [NSString stringWithUTF8String:std::string(diagnostic).c_str()];
        NSLog(@"[ShaderMetal] MetalFX temporal denoised upscaling disabled (%@); "
               "using the built-in temporal/spatial fallback", reason);
        metalFXFallbackLogged_ = true;
    }
}

bool RayTracePass::encodeLighting(const RayTraceLightingInput &input,
                                  std::string &error) {
    std::lock_guard lock(mutex_);
    error.clear();

    if (device_ == nil || lightingPipeline_ == nil || temporalPipeline_ == nil ||
        spatialPipeline_ == nil || materialArgumentEncoder_ == nil ||
        intersectionSceneCountsBuffer_ == nil || localLightBuffer_ == nil) {
        error = "ray-tracing pass is not initialized";
        return false;
    }
    if (input.commandBuffer == nil) {
        error = "ray-tracing input has no command buffer";
        return false;
    }
    if (input.commandBuffer.device != device_) {
        error = "ray-tracing command buffer belongs to a different Metal device";
        return false;
    }
    if (input.topLevelAccelerationStructure == nil) {
        error = "ray-tracing input has no TLAS";
        return false;
    }
    if (input.canonicalVertices == nil || input.canonicalVertexCount < 3) {
        error = "ray-tracing input has no canonical triangle vertices";
        return false;
    }
    if (input.canonicalVertexCount > std::numeric_limits<std::uint32_t>::max() ||
        input.canonicalVertexCount >
            input.canonicalVertices.length / kCanonicalVertexStride) {
        error = "canonical RT vertex count exceeds the supplied buffer";
        return false;
    }
    if (input.dynamicCanonicalVertexCount >
            std::numeric_limits<std::uint32_t>::max() ||
        (input.dynamicCanonicalVertexCount != 0 &&
         (input.dynamicCanonicalVertices == nil ||
          input.dynamicCanonicalVertexCount >
              input.dynamicCanonicalVertices.length / kCanonicalVertexStride))) {
        error = "dynamic canonical RT vertex count exceeds the supplied buffer";
        return false;
    }
    if (input.instanceMetadata == nil || input.instanceCount == 0) {
        error = "ray-tracing input has no active instance metadata";
        return false;
    }
    if (input.instanceCount > std::numeric_limits<std::uint32_t>::max() ||
        input.instanceCount > input.instanceMetadata.length / kInstanceMetadataStride) {
        error = "ray-tracing instance count exceeds the metadata buffer";
        return false;
    }
    if (input.activeBottomLevelStructures.empty()) {
        error = "ray-tracing TLAS has no active bottom-level structures";
        return false;
    }
    if (input.topLevelAccelerationStructure.device != device_ ||
        input.canonicalVertices.device != device_ ||
        (input.dynamicCanonicalVertices != nil &&
         input.dynamicCanonicalVertices.device != device_) ||
        input.instanceMetadata.device != device_) {
        error = "ray-tracing scene resources belong to a different Metal device";
        return false;
    }
    for (id<MTLAccelerationStructure> bottomLevel :
         input.activeBottomLevelStructures) {
        if (bottomLevel == nil || bottomLevel.device != device_) {
            error = "active bottom-level acceleration structure is nil or belongs "
                "to a different Metal device";
            return false;
        }
    }
    if (input.worldColor == nil || input.worldColor.textureType != MTLTextureType2D ||
        input.worldColor.width == 0 || input.worldColor.height == 0 ||
        !hasShaderReadUsage(input.worldColor)) {
        error = "worldColor must be a nonempty shader-readable 2D texture";
        return false;
    }
    if (input.worldColor.device != device_) {
        error = "worldColor belongs to a different Metal device";
        return false;
    }
    if (input.worldDepth == nil ||
        input.worldDepth.textureType != MTLTextureType2D ||
        input.worldDepth.width != input.worldColor.width ||
        input.worldDepth.height != input.worldColor.height ||
        input.worldDepth.pixelFormat != MTLPixelFormatDepth32Float_Stencil8 ||
        !hasShaderReadUsage(input.worldDepth) ||
        input.worldDepth.device != device_) {
        error = "worldDepth must match worldColor and be shader-readable";
        return false;
    }
    if (!finiteTextureDimensions(input.outputWidth, input.outputHeight)) {
        error = "ray-tracing output dimensions must fit the shader's uint range";
        return false;
    }
    const NSUInteger expectedWidth = std::max<NSUInteger>(
        1, (input.worldColor.width + 1) / 2);
    const NSUInteger expectedHeight = std::max<NSUInteger>(
        1, (input.worldColor.height + 1) / 2);
    if (input.outputWidth != expectedWidth ||
        input.outputHeight != expectedHeight) {
        error = "ray-tracing output must be half the world-color dimensions";
        return false;
    }
    if (!finitePositive(input.ambientOcclusionRadius) ||
        !finitePositive(input.minimumRayDistance) ||
        !finitePositive(input.primaryRayDistance) ||
        !finitePositive(input.indirectRayDistance) ||
        input.minimumRayDistance >= input.ambientOcclusionRadius ||
        input.minimumRayDistance >= input.primaryRayDistance ||
        input.ambientOcclusionRadius > input.indirectRayDistance ||
        input.indirectRayDistance > input.primaryRayDistance) {
        error = "ray distances must be finite, positive, and consistently ordered";
        return false;
    }
    const float projectionDeterminant = simd_determinant(input.projection);
    const float viewToSceneDeterminant = simd_determinant(input.viewToScene);
    if (!finiteMatrix(input.projection) || !std::isfinite(projectionDeterminant) ||
        std::abs(projectionDeterminant) < 1.0e-8F ||
        !finiteMatrix(input.viewToScene) ||
        !std::isfinite(viewToSceneDeterminant) ||
        std::abs(viewToSceneDeterminant) < 1.0e-8F ||
        !finiteVector(input.cameraOrigin) ||
        !finiteVector(input.sunDirection) ||
        simd_length_squared(input.sunDirection) < 1.0e-8F ||
        !finiteNonNegativeVector(input.sunRadiance) ||
        !finiteVector(input.moonDirection) ||
        simd_length_squared(input.moonDirection) < 1.0e-8F ||
        !finiteNonNegativeVector(input.moonRadiance) ||
        !finiteNonNegativeVector(input.skyRadiance) ||
        !finiteVector(input.sceneUpDirection) ||
        simd_length_squared(input.sceneUpDirection) < 1.0e-8F ||
        !finiteVector(input.sceneEast) ||
        simd_length_squared(input.sceneEast) < 1.0e-8F ||
        !finiteVector(input.sceneNorth) ||
        simd_length_squared(input.sceneNorth) < 1.0e-8F ||
        !finiteVector(input.worldCameraPosition)) {
        error = "ray-tracing projection or lighting vectors are invalid";
        return false;
    }
    const simd_float3 normalizedUp = simd_normalize(input.sceneUpDirection);
    const simd_float3 normalizedEast = simd_normalize(input.sceneEast);
    const simd_float3 normalizedNorth = simd_normalize(input.sceneNorth);
    if (std::abs(simd_dot(simd_cross(normalizedEast, normalizedNorth),
                          normalizedUp)) < 1.0e-3F) {
        error = "ray-tracing scene basis is degenerate";
        return false;
    }
    for (const RTLocalLight &light : input.localLights) {
        const simd_float3 position = simd_make_float3(
            light.position[0], light.position[1], light.position[2]);
        const simd_float3 color = simd_make_float3(
            light.color[0], light.color[1], light.color[2]);
        if (!finiteVector(position) || !finitePositive(light.radius) ||
            light.radius > input.primaryRayDistance ||
            !finiteNonNegativeVector(color) ||
            !std::isfinite(light.intensity) || light.intensity < 0.0F) {
            error = "local light contains a non-finite or out-of-range value";
            return false;
        }
    }
    const simd_float4x4 inverseProjection = simd_inverse(input.projection);
    const simd_float4x4 sceneToCurrentView = simd_inverse(input.viewToScene);
    const simd_float4x4 sceneToCurrentClip = simd_mul(
        input.projection, sceneToCurrentView);
    simd_float4x4 clipDepthRemap = matrix_identity_float4x4;
    clipDepthRemap.columns[2] = simd_make_float4(0.0F, 0.0F, 0.5F, 0.0F);
    clipDepthRemap.columns[3] = simd_make_float4(0.0F, 0.0F, 0.5F, 1.0F);
    const simd_float4x4 metalViewToClip = simd_mul(
        clipDepthRemap, input.projection);
    simd_float3 currentSceneCamera{};
    simd_float3 currentViewForward{};
    if (!finiteMatrix(inverseProjection) || !finiteMatrix(sceneToCurrentView) ||
        !finiteMatrix(sceneToCurrentClip) ||
        !finiteMatrix(metalViewToClip) ||
        !transformedPoint(input.viewToScene, input.cameraOrigin,
                          currentSceneCamera) ||
        !viewForward(input.viewToScene, currentViewForward)) {
        error = "ray-tracing camera transforms contain non-finite values";
        return false;
    }
    simd_float4x4 worldToScene = matrix_identity_float4x4;
    worldToScene.columns[0] = simd_make_float4(
        normalizedEast.x, normalizedEast.y, normalizedEast.z, 0.0F);
    worldToScene.columns[1] = simd_make_float4(
        normalizedUp.x, normalizedUp.y, normalizedUp.z, 0.0F);
    worldToScene.columns[2] = simd_make_float4(
        normalizedNorth.x, normalizedNorth.y, normalizedNorth.z, 0.0F);
    const simd_float3 worldCameraInScene =
        normalizedEast * input.worldCameraPosition.x +
        normalizedUp * input.worldCameraPosition.y +
        normalizedNorth * input.worldCameraPosition.z;
    const simd_float3 sceneTranslation =
        currentSceneCamera - worldCameraInScene;
    worldToScene.columns[3] = simd_make_float4(
        sceneTranslation.x, sceneTranslation.y, sceneTranslation.z, 1.0F);
    const simd_float4x4 worldToCurrentView = simd_mul(
        sceneToCurrentView, worldToScene);
    if (!finiteMatrix(worldToCurrentView)) {
        error = "ray-tracing world-to-view transform contains non-finite values";
        return false;
    }
    if (!ensureLightingTexturesLocked(input.outputWidth, input.outputHeight,
                                      input.worldColor.width,
                                      input.worldColor.height,
                                      error)) {
        return false;
    }

    const bool frameSequenceBroken = !hasPreviousFrameIndex_ ||
        static_cast<std::uint32_t>(
            input.frameIndex - previousFrameIndex_) != 1U;
    bool historyCut = input.historyReset || !hasPreviousFrame_ ||
        frameSequenceBroken;
    if (hasPreviousFrame_) {
        historyCut = historyCut ||
            matrixMateriallyDifferent(input.projection, previousProjection_);
        const simd_float3 cameraDelta =
            input.worldCameraPosition - previousWorldCamera_;
        const float cameraDistanceSquared = simd_length_squared(cameraDelta);
        const float forwardCosine = simd_dot(
            currentViewForward, previousViewForward_);
        historyCut = historyCut || !std::isfinite(cameraDistanceSquared) ||
            cameraDistanceSquared > kCameraCutDistanceSquared ||
            !std::isfinite(forwardCosine) || forwardCosine < kCameraCutCosine ||
            input.cameraSubmergedInWater != previousCameraSubmergedInWater_;
    }
    const bool useHistory = historyValid_ && !historyCut;
    if (!useHistory) {
        // A reset remains sticky if a later encoder cannot be created. Reusing the
        // old history after a failed cut frame would produce severe ghosting.
        historyValid_ = false;
    }

    simd_float4x4 sceneToPreviousClip = simd_mul(
        input.projection, sceneToCurrentView);
    simd_float3 previousSceneCamera = currentSceneCamera;
    if (useHistory) {
        const simd_float4x4 previousSceneToView =
            simd_inverse(previousViewToScene_);
        if (!finiteMatrix(previousSceneToView)) {
            historyValid_ = false;
            error = "previous ray-tracing camera transform is not invertible";
            return false;
        }
        sceneToPreviousClip = simd_mul(
            previousProjection_, previousSceneToView);
        previousSceneCamera = previousSceneCamera_;
    }
    if (!finiteMatrix(sceneToPreviousClip)) {
        historyValid_ = false;
        error = "ray-tracing reprojection matrix contains non-finite values";
        return false;
    }

    const std::size_t historyWriteIndex = 1U - historyReadIndex_;

    const TextureManager::BindingSnapshot materialBindings =
        TextureManager::shared().bindingSnapshot();
    if (materialArgumentBuffer_ == nil || materialAvailabilityBuffer_ == nil ||
        materialBindingRevision_ != materialBindings.revision) {
        id<MTLBuffer> argumentBuffer = [device_
            newBufferWithLength:materialArgumentEncoder_.encodedLength
                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> availabilityBuffer = [device_
            newBufferWithLength:kTextureTableSize
                        options:MTLResourceStorageModeShared];
        if (argumentBuffer == nil || availabilityBuffer == nil ||
            argumentBuffer.contents == nullptr ||
            availabilityBuffer.contents == nullptr) {
            error = "Metal failed to allocate the GI material argument buffers";
            return false;
        }
        argumentBuffer.label = @"ShaderMetal GI Material Table";
        availabilityBuffer.label = @"ShaderMetal GI Material Availability";
        std::memset(argumentBuffer.contents, 0,
                    static_cast<std::size_t>(argumentBuffer.length));
        std::memset(availabilityBuffer.contents, 0, kTextureTableSize);
        [materialArgumentEncoder_ setArgumentBuffer:argumentBuffer offset:0];

        auto *availability = static_cast<std::uint8_t *>(
            availabilityBuffer.contents);
        for (const TextureManager::TextureBinding &binding :
             materialBindings.bindings) {
            if (binding.textureId < 0 ||
                static_cast<NSUInteger>(binding.textureId) >= kTextureTableSize ||
                binding.texture == nil || binding.texture.device != device_) {
                error = "GI material texture has an invalid ID or Metal device";
                return false;
            }
            std::string samplerError;
            id<MTLSamplerState> sampler = SamplerCache::shared().sampler(
                device_, binding.sampler, samplerError);
            if (sampler == nil) {
                error = "GI material texture " + std::to_string(binding.textureId) +
                    " has no usable sampler: " + samplerError;
                return false;
            }
            const NSUInteger textureIndex =
                static_cast<NSUInteger>(binding.textureId);
            [materialArgumentEncoder_ setTexture:binding.texture
                                         atIndex:textureIndex];
            [materialArgumentEncoder_ setSamplerState:sampler
                                               atIndex:kTextureTableSize + textureIndex];
            availability[textureIndex] = 1;
        }
        materialArgumentBuffer_ = argumentBuffer;
        materialAvailabilityBuffer_ = availabilityBuffer;
        materialBindingRevision_ = materialBindings.revision;
    }

    RayTraceUniforms uniforms{};
    uniforms.inverseProjection = inverseProjection;
    uniforms.viewToScene = input.viewToScene;
    uniforms.sceneToCurrentClip = sceneToCurrentClip;
    uniforms.sceneToPreviousClip = sceneToPreviousClip;
    uniforms.cameraAndMinimumDistance = simd_make_float4(
        input.cameraOrigin.x, input.cameraOrigin.y, input.cameraOrigin.z,
        input.minimumRayDistance);
    uniforms.previousSceneCameraAndHistory = simd_make_float4(
        previousSceneCamera.x, previousSceneCamera.y, previousSceneCamera.z,
        useHistory ? 1.0F : 0.0F);
    const simd_float3 normalizedSun = simd_normalize(input.sunDirection);
    const simd_float3 normalizedMoon = simd_normalize(input.moonDirection);
    uniforms.sunDirectionAndAORadius = simd_make_float4(
        normalizedSun.x, normalizedSun.y, normalizedSun.z,
        input.ambientOcclusionRadius);
    uniforms.sunRadiance = simd_make_float4(
        input.sunRadiance.x, input.sunRadiance.y, input.sunRadiance.z, 0.0F);
    uniforms.moonDirection = simd_make_float4(
        normalizedMoon.x, normalizedMoon.y, normalizedMoon.z, 0.0F);
    uniforms.moonRadiance = simd_make_float4(
        input.moonRadiance.x, input.moonRadiance.y, input.moonRadiance.z, 0.0F);
    uniforms.skyRadiance = simd_make_float4(
        input.skyRadiance.x, input.skyRadiance.y, input.skyRadiance.z,
        std::clamp(input.weatherStrength, 0.0F, 1.0F));
    uniforms.sceneUpAndTime = simd_make_float4(
        normalizedUp.x, normalizedUp.y, normalizedUp.z,
        static_cast<float>(input.frameIndex) * (1.0F / 60.0F));
    const bool metalFXFrameAvailable = metalFXDenoisedScaler_ != nil &&
        metalFXOutputTexture_ != nil;
    const simd_float2 jitter = metalFXFrameAvailable
        ? metalFXJitter(input.frameIndex)
        : simd_make_float2(0.0F, 0.0F);
    uniforms.sceneEast = simd_make_float4(
        normalizedEast.x, normalizedEast.y, normalizedEast.z, jitter.x);
    uniforms.sceneNorth = simd_make_float4(
        normalizedNorth.x, normalizedNorth.y, normalizedNorth.z, jitter.y);
    uniforms.worldCamera = simd_make_float4(
        input.worldCameraPosition.x, input.worldCameraPosition.y,
        input.worldCameraPosition.z,
        input.cameraSubmergedInWater ? 1.0F : 0.0F);
    uniforms.traceParameters = simd_make_float4(
        input.primaryRayDistance, input.indirectRayDistance,
        static_cast<float>(input.outputWidth),
        static_cast<float>(input.outputHeight));
    const NSUInteger localLightCount = std::min<NSUInteger>(
        input.localLights.size(), kMaxLocalLights);
    uniforms.geometryCounts = simd_make_uint4(
        static_cast<std::uint32_t>(input.canonicalVertexCount),
        static_cast<std::uint32_t>(input.dynamicCanonicalVertexCount),
        static_cast<std::uint32_t>(input.instanceCount),
        static_cast<std::uint32_t>(localLightCount));
    uniforms.frameData = simd_make_uint4(
        input.frameIndex, useHistory ? 1U : 0U, 0U, 0U);

    const float daylightStrength = smoothstep(
        -0.08F, 0.18F, simd_dot(normalizedSun, normalizedUp));
    const float exposure = 1.55F + (0.98F - 1.55F) * daylightStrength;
    const simd_float4 displayParameters = simd_make_float4(
        exposure, 0.02F, daylightStrength, 0.0F);

    const NSUInteger frameSlot = input.frameIndex % kLocalLightFramesInFlight;
    const NSUInteger localLightOffset =
        frameSlot * kLocalLightFrameStride;
    auto *localLightDestination = static_cast<std::byte *>(
        localLightBuffer_.contents) + localLightOffset;
    std::memset(localLightDestination, 0, kLocalLightFrameStride);
    if (localLightCount != 0) {
        std::memcpy(localLightDestination, input.localLights.data(),
                    localLightCount * sizeof(RTLocalLight));
    }
    const NSUInteger intersectionSceneCountOffset =
        frameSlot * kIntersectionSceneCountFrameStride;
    std::memcpy(static_cast<std::byte *>(
                    intersectionSceneCountsBuffer_.contents) +
                    intersectionSceneCountOffset,
                &uniforms.geometryCounts, sizeof(uniforms.geometryCounts));
    id<MTLBuffer> dynamicVertices = input.dynamicCanonicalVertexCount != 0
        ? input.dynamicCanonicalVertices
        : input.canonicalVertices;
    id<MTLIntersectionFunctionTable> intersectionFunctionTable =
        intersectionFunctionTables_[frameSlot];
    [intersectionFunctionTable setBuffer:input.canonicalVertices
                                  offset:0
                                 atIndex:0];
    [intersectionFunctionTable setBuffer:dynamicVertices offset:0 atIndex:1];
    [intersectionFunctionTable setBuffer:input.instanceMetadata offset:0 atIndex:2];
    [intersectionFunctionTable setBuffer:intersectionSceneCountsBuffer_
                                  offset:intersectionSceneCountOffset
                                 atIndex:3];
    [intersectionFunctionTable setBuffer:materialArgumentBuffer_ offset:0 atIndex:4];
    [intersectionFunctionTable setBuffer:materialAvailabilityBuffer_
                                  offset:0
                                 atIndex:5];
    id<MTLComputeCommandEncoder> rayTraceEncoder =
        [input.commandBuffer computeCommandEncoder];
    if (rayTraceEncoder == nil) {
        error = "Metal failed to create the ray-tracing compute encoder";
        return false;
    }
    rayTraceEncoder.label = @"ShaderMetal Hardware Ray-Traced GI";
    [rayTraceEncoder setComputePipelineState:lightingPipeline_];
    [rayTraceEncoder
        setAccelerationStructure:input.topLevelAccelerationStructure
                atBufferIndex:0];
    [rayTraceEncoder setBuffer:input.canonicalVertices offset:0 atIndex:1];
    [rayTraceEncoder setBuffer:input.instanceMetadata offset:0 atIndex:2];
    [rayTraceEncoder setBytes:&uniforms length:sizeof(uniforms) atIndex:3];
    [rayTraceEncoder setBuffer:materialArgumentBuffer_ offset:0 atIndex:4];
    [rayTraceEncoder setBuffer:materialAvailabilityBuffer_ offset:0 atIndex:5];
    [rayTraceEncoder setBuffer:localLightBuffer_ offset:localLightOffset atIndex:6];
    [rayTraceEncoder setBuffer:dynamicVertices offset:0 atIndex:7];
    [rayTraceEncoder setIntersectionFunctionTable:intersectionFunctionTable
                                    atBufferIndex:8];
    [rayTraceEncoder setTexture:input.worldColor atIndex:0];
    [rayTraceEncoder setTexture:rawLightingTexture_ atIndex:1];
    [rayTraceEncoder setTexture:currentGeometryTexture_ atIndex:2];
    [rayTraceEncoder setTexture:metalFXDepthTexture_ atIndex:3];
    [rayTraceEncoder setTexture:metalFXMotionTexture_ atIndex:4];
    [rayTraceEncoder setTexture:metalFXNormalTexture_ atIndex:5];
    [rayTraceEncoder setTexture:metalFXDiffuseAlbedoTexture_ atIndex:6];
    [rayTraceEncoder setTexture:metalFXSpecularAlbedoTexture_ atIndex:7];
    [rayTraceEncoder setTexture:metalFXRoughnessTexture_ atIndex:8];
    [rayTraceEncoder setTexture:metalFXReactiveMaskTexture_ atIndex:9];
    [rayTraceEncoder setTexture:input.worldDepth atIndex:10];

    [rayTraceEncoder useResource:input.topLevelAccelerationStructure
                              usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:input.canonicalVertices
                              usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:input.instanceMetadata
                              usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:dynamicVertices usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:intersectionFunctionTable
                              usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:intersectionSceneCountsBuffer_
                              usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:materialArgumentBuffer_
                              usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:materialAvailabilityBuffer_
                              usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:localLightBuffer_ usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:input.worldColor usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:input.worldDepth usage:MTLResourceUsageRead];
    [rayTraceEncoder useResource:rawLightingTexture_
                              usage:MTLResourceUsageWrite];
    [rayTraceEncoder useResource:currentGeometryTexture_
                              usage:MTLResourceUsageWrite];
    [rayTraceEncoder useResource:metalFXDepthTexture_
                              usage:MTLResourceUsageWrite];
    [rayTraceEncoder useResource:metalFXMotionTexture_
                              usage:MTLResourceUsageWrite];
    [rayTraceEncoder useResource:metalFXNormalTexture_
                              usage:MTLResourceUsageWrite];
    [rayTraceEncoder useResource:metalFXDiffuseAlbedoTexture_
                              usage:MTLResourceUsageWrite];
    [rayTraceEncoder useResource:metalFXSpecularAlbedoTexture_
                              usage:MTLResourceUsageWrite];
    [rayTraceEncoder useResource:metalFXRoughnessTexture_
                              usage:MTLResourceUsageWrite];
    [rayTraceEncoder useResource:metalFXReactiveMaskTexture_
                              usage:MTLResourceUsageWrite];

    for (const TextureManager::TextureBinding &binding :
         materialBindings.bindings) {
        [rayTraceEncoder useResource:binding.texture usage:MTLResourceUsageRead];
    }

    std::vector<id<MTLResource>> bottomLevelResources;
    bottomLevelResources.reserve(input.activeBottomLevelStructures.size());
    for (id<MTLAccelerationStructure> bottomLevel :
         input.activeBottomLevelStructures) {
        id<MTLResource> resource = bottomLevel;
        bottomLevelResources.push_back(resource);
    }
    if (!bottomLevelResources.empty()) {
        // BLAS residency is indirect through the TLAS. Batch it to avoid one
        // Objective-C message per active chunk every frame.
        [rayTraceEncoder useResources:bottomLevelResources.data()
                                count:bottomLevelResources.size()
                                usage:MTLResourceUsageRead];
    }

    dispatch2D(rayTraceEncoder, lightingPipeline_, rawLightingTexture_.width,
               rawLightingTexture_.height);
    [rayTraceEncoder endEncoding];

    usingMetalFXThisFrame_ = false;
    if (metalFXFrameAvailable) {
        if (@available(macOS 26.0, *)) {
            id<MTLFXTemporalDenoisedScaler> scaler = metalFXDenoisedScaler_;
            scaler.colorTexture = rawLightingTexture_;
            scaler.depthTexture = metalFXDepthTexture_;
            scaler.motionTexture = metalFXMotionTexture_;
            scaler.diffuseAlbedoTexture = metalFXDiffuseAlbedoTexture_;
            scaler.specularAlbedoTexture = metalFXSpecularAlbedoTexture_;
            scaler.normalTexture = metalFXNormalTexture_;
            scaler.roughnessTexture = metalFXRoughnessTexture_;
            scaler.exposureTexture = metalFXExposureTexture_;
            scaler.outputTexture = metalFXOutputTexture_;
            scaler.preExposure = 1.0F;
            // MetalFX expects the offset that returns the displaced sample to
            // the pixel center, which is the negative of the ray jitter.
            scaler.jitterOffsetX = -jitter.x;
            scaler.jitterOffsetY = -jitter.y;
            scaler.motionVectorScaleX = static_cast<float>(scaler.inputWidth);
            scaler.motionVectorScaleY = static_cast<float>(scaler.inputHeight);
            scaler.shouldResetHistory = historyCut ? YES : NO;
            scaler.depthReversed = NO;
            scaler.worldToViewMatrix = worldToCurrentView;
            scaler.viewToClipMatrix = metalViewToClip;
#if defined(__MAC_27_0) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_27_0
            if (@available(macOS 27.0, *)) {
                scaler.reactiveMaskTexture = metalFXReactiveMaskEnabled_
                    ? metalFXReactiveMaskTexture_
                    : nil;
            }
#endif
            [scaler encodeToCommandBuffer:input.commandBuffer];
            usingMetalFXThisFrame_ = true;
        }
    }

    if (!usingMetalFXThisFrame_) {
        id<MTLTexture> previousRadiance =
            historyRadianceTextures_[historyReadIndex_];
        id<MTLTexture> previousGeometry =
            historyGeometryTextures_[historyReadIndex_];
        id<MTLTexture> nextRadiance =
            historyRadianceTextures_[historyWriteIndex];
        id<MTLTexture> nextGeometry =
            historyGeometryTextures_[historyWriteIndex];

    id<MTLComputeCommandEncoder> temporalEncoder =
        [input.commandBuffer computeCommandEncoder];
    if (temporalEncoder == nil) {
        error = "Metal failed to create the ray-tracing temporal encoder";
        return false;
    }
    temporalEncoder.label = @"ShaderMetal Ray-Tracing Temporal Resolve";
    [temporalEncoder setComputePipelineState:temporalPipeline_];
    [temporalEncoder setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [temporalEncoder setTexture:rawLightingTexture_ atIndex:0];
    [temporalEncoder setTexture:currentGeometryTexture_ atIndex:1];
    [temporalEncoder setTexture:previousRadiance atIndex:2];
    [temporalEncoder setTexture:previousGeometry atIndex:3];
    [temporalEncoder setTexture:nextRadiance atIndex:4];
    [temporalEncoder setTexture:nextGeometry atIndex:5];
    [temporalEncoder useResource:rawLightingTexture_
                              usage:MTLResourceUsageRead];
    [temporalEncoder useResource:currentGeometryTexture_
                              usage:MTLResourceUsageRead];
    [temporalEncoder useResource:previousRadiance usage:MTLResourceUsageRead];
    [temporalEncoder useResource:previousGeometry usage:MTLResourceUsageRead];
    [temporalEncoder useResource:nextRadiance usage:MTLResourceUsageWrite];
    [temporalEncoder useResource:nextGeometry usage:MTLResourceUsageWrite];
    dispatch2D(temporalEncoder, temporalPipeline_, nextRadiance.width,
               nextRadiance.height);
    [temporalEncoder endEncoding];

    const simd_int2 horizontalAxis = simd_make_int2(1, 0);
    id<MTLComputeCommandEncoder> horizontalEncoder =
        [input.commandBuffer computeCommandEncoder];
    if (horizontalEncoder == nil) {
        error = "Metal failed to create the horizontal spatial-filter encoder";
        return false;
    }
    horizontalEncoder.label = @"ShaderMetal RT Spatial Filter Horizontal";
    [horizontalEncoder setComputePipelineState:spatialPipeline_];
    [horizontalEncoder setBytes:&horizontalAxis
                         length:sizeof(horizontalAxis)
                        atIndex:0];
    [horizontalEncoder setTexture:nextRadiance atIndex:0];
    [horizontalEncoder setTexture:currentGeometryTexture_ atIndex:1];
    [horizontalEncoder setTexture:filterScratchTexture_ atIndex:2];
    [horizontalEncoder useResource:nextRadiance usage:MTLResourceUsageRead];
    [horizontalEncoder useResource:currentGeometryTexture_
                                usage:MTLResourceUsageRead];
    [horizontalEncoder useResource:filterScratchTexture_
                                usage:MTLResourceUsageWrite];
    dispatch2D(horizontalEncoder, spatialPipeline_, filterScratchTexture_.width,
               filterScratchTexture_.height);
    [horizontalEncoder endEncoding];

    const simd_int2 verticalAxis = simd_make_int2(0, 1);
    id<MTLComputeCommandEncoder> verticalEncoder =
        [input.commandBuffer computeCommandEncoder];
    if (verticalEncoder == nil) {
        error = "Metal failed to create the vertical spatial-filter encoder";
        return false;
    }
    verticalEncoder.label = @"ShaderMetal RT Spatial Filter Vertical";
    [verticalEncoder setComputePipelineState:spatialPipeline_];
    [verticalEncoder setBytes:&verticalAxis
                       length:sizeof(verticalAxis)
                      atIndex:0];
    [verticalEncoder setTexture:filterScratchTexture_ atIndex:0];
    [verticalEncoder setTexture:currentGeometryTexture_ atIndex:1];
    [verticalEncoder setTexture:lightingTexture_ atIndex:2];
    [verticalEncoder useResource:filterScratchTexture_
                              usage:MTLResourceUsageRead];
    [verticalEncoder useResource:currentGeometryTexture_
                              usage:MTLResourceUsageRead];
    [verticalEncoder useResource:lightingTexture_
                              usage:MTLResourceUsageWrite];
    dispatch2D(verticalEncoder, spatialPipeline_, lightingTexture_.width,
               lightingTexture_.height);
    [verticalEncoder endEncoding];

        historyReadIndex_ = historyWriteIndex;
    }
    historyValid_ = true;
    hasPreviousFrame_ = true;
    previousFrameIndex_ = input.frameIndex;
    hasPreviousFrameIndex_ = true;
    previousProjection_ = input.projection;
    previousViewToScene_ = input.viewToScene;
    previousSceneCamera_ = currentSceneCamera;
    previousWorldCamera_ = input.worldCameraPosition;
    previousViewForward_ = currentViewForward;
    previousCameraSubmergedInWater_ = input.cameraSubmergedInWater;
    displayParameters_ = displayParameters;
    return true;
}

bool RayTracePass::encodeComposite(id<MTLCommandBuffer> commandBuffer,
                                   id<MTLTexture> worldColor,
                                   id<MTLTexture> bgra8Drawable,
                                   std::string &error) {
    std::lock_guard lock(mutex_);
    error.clear();
    id<MTLTexture> displayLighting = usingMetalFXThisFrame_
        ? metalFXOutputTexture_
        : lightingTexture_;
    if (device_ == nil || compositePipeline_ == nil ||
        displayLighting == nil || displayLighting.device != device_ ||
        displayLighting.textureType != MTLTextureType2D ||
        displayLighting.pixelFormat != MTLPixelFormatRGBA16Float ||
        !hasShaderReadUsage(displayLighting)) {
        error = "ray-tracing composite pass is not ready";
        return false;
    }
    if (commandBuffer == nil || worldColor == nil || bgra8Drawable == nil) {
        error = "ray-tracing composite is missing a command buffer or texture";
        return false;
    }
    if (commandBuffer.device != device_ || worldColor.device != device_ ||
        bgra8Drawable.device != device_) {
        error = "ray-tracing composite resources belong to different Metal devices";
        return false;
    }
    if (worldColor == bgra8Drawable) {
        error = "ray-tracing composite cannot sample from its render target";
        return false;
    }
    if (worldColor.textureType != MTLTextureType2D || worldColor.width == 0 ||
        worldColor.height == 0 || !hasShaderReadUsage(worldColor)) {
        error = "composite worldColor must be a shader-readable 2D texture";
        return false;
    }
    if (worldColor.width != bgra8Drawable.width ||
        worldColor.height != bgra8Drawable.height) {
        error = "composite worldColor and drawable dimensions must match";
        return false;
    }
    if (bgra8Drawable.textureType != MTLTextureType2D ||
        bgra8Drawable.pixelFormat != MTLPixelFormatBGRA8Unorm ||
        (bgra8Drawable.usage & MTLTextureUsageRenderTarget) == 0) {
        error = "composite output must be a BGRA8Unorm 2D render target";
        return false;
    }
    const NSUInteger expectedLightingWidth = std::max<NSUInteger>(
        1, (worldColor.width + 1) / 2);
    const NSUInteger expectedLightingHeight = std::max<NSUInteger>(
        1, (worldColor.height + 1) / 2);
    const bool fullResolutionMetalFX = usingMetalFXThisFrame_ &&
        displayLighting.width == worldColor.width &&
        displayLighting.height == worldColor.height;
    const bool halfResolutionFallback = !usingMetalFXThisFrame_ &&
        displayLighting.width == expectedLightingWidth &&
        displayLighting.height == expectedLightingHeight;
    if (!fullResolutionMetalFX && !halfResolutionFallback) {
        error = "composite lighting texture has an unexpected MetalFX/fallback "
            "resolution";
        return false;
    }
    if (!std::isfinite(displayParameters_.x) ||
        !std::isfinite(displayParameters_.y) ||
        !std::isfinite(displayParameters_.z) ||
        !std::isfinite(displayParameters_.w)) {
        error = "composite display parameters are invalid";
        return false;
    }

    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = bgra8Drawable;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    if (encoder == nil) {
        error = "Metal failed to create the ray-tracing composite encoder";
        return false;
    }
    encoder.label = @"ShaderMetal Ray-Traced World Composite";
    [encoder setRenderPipelineState:compositePipeline_];
    [encoder setViewport:MTLViewport{0.0, 0.0,
                                    static_cast<double>(bgra8Drawable.width),
                                    static_cast<double>(bgra8Drawable.height),
                                    0.0, 1.0}];
    [encoder setScissorRect:MTLScissorRect{0, 0, bgra8Drawable.width,
                                           bgra8Drawable.height}];
    [encoder setFragmentBytes:&displayParameters_
                       length:sizeof(displayParameters_)
                      atIndex:0];
    [encoder setFragmentTexture:worldColor atIndex:0];
    [encoder setFragmentTexture:displayLighting atIndex:1];
    [encoder useResource:worldColor
                   usage:MTLResourceUsageRead
                  stages:MTLRenderStageFragment];
    [encoder useResource:displayLighting
                   usage:MTLResourceUsageRead
                  stages:MTLRenderStageFragment];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return true;
}

id<MTLTexture> RayTracePass::lightingTexture() const {
    std::lock_guard lock(mutex_);
    return usingMetalFXThisFrame_ ? metalFXOutputTexture_ : lightingTexture_;
}

void RayTracePass::invalidateHistory() {
    std::lock_guard lock(mutex_);
    historyValid_ = false;
    usingMetalFXThisFrame_ = false;
    hasPreviousFrame_ = false;
    previousFrameIndex_ = 0;
    hasPreviousFrameIndex_ = false;
}

void RayTracePass::close() {
    std::lock_guard lock(mutex_);
    rawLightingTexture_ = nil;
    currentGeometryTexture_ = nil;
    historyRadianceTextures_.fill(nil);
    historyGeometryTextures_.fill(nil);
    filterScratchTexture_ = nil;
    lightingTexture_ = nil;
    metalFXDenoisedScaler_ = nil;
    metalFXDepthTexture_ = nil;
    metalFXMotionTexture_ = nil;
    metalFXNormalTexture_ = nil;
    metalFXDiffuseAlbedoTexture_ = nil;
    metalFXSpecularAlbedoTexture_ = nil;
    metalFXRoughnessTexture_ = nil;
    metalFXReactiveMaskTexture_ = nil;
    metalFXExposureTexture_ = nil;
    metalFXOutputTexture_ = nil;
    metalFXSupported_ = false;
    metalFXRuntimeDisabled_ = false;
    metalFXReactiveMaskEnabled_ = false;
    usingMetalFXThisFrame_ = false;
    metalFXSuccessLogged_ = false;
    metalFXFallbackLogged_ = false;
    compositePipeline_ = nil;
    spatialPipeline_ = nil;
    temporalPipeline_ = nil;
    lightingPipeline_ = nil;
    intersectionFunctionTables_.fill(nil);
    intersectionSceneCountsBuffer_ = nil;
    materialArgumentEncoder_ = nil;
    materialArgumentBuffer_ = nil;
    materialAvailabilityBuffer_ = nil;
    materialBindingRevision_ = 0;
    localLightBuffer_ = nil;
    historyReadIndex_ = 0;
    historyValid_ = false;
    hasPreviousFrame_ = false;
    previousFrameIndex_ = 0;
    hasPreviousFrameIndex_ = false;
    previousProjection_ = matrix_identity_float4x4;
    previousViewToScene_ = matrix_identity_float4x4;
    previousSceneCamera_ = simd_make_float3(0.0F, 0.0F, 0.0F);
    previousWorldCamera_ = simd_make_float3(0.0F, 0.0F, 0.0F);
    previousViewForward_ = simd_make_float3(0.0F, 0.0F, -1.0F);
    previousCameraSubmergedInWater_ = false;
    displayParameters_ = simd_make_float4(0.90F, 0.02F, 1.0F, 0.0F);
    library_ = nil;
    device_ = nil;
}

} // namespace shadermetal
