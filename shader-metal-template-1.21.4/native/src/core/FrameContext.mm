#include "core/FrameContext.hpp"

#include "core/MetalDevice.hpp"
#include "raytracing/AccelStructManager.hpp"
#include "raytracing/RayTracePass.hpp"
#include "render/RasterPass.hpp"
#include "render/ShaderRegistry.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iterator>
#include <string>
#include <string_view>

namespace shadermetal {
namespace {

void appendRasterResult(RasterEncodeResult &target,
                        RasterEncodeResult source) {
    target.submittedDrawCount += source.submittedDrawCount;
    target.encodedDrawCount += source.encodedDrawCount;
    target.skippedDrawCount += source.skippedDrawCount;
    if (target.firstSkippedReason.empty()) {
        target.firstSkippedReason = std::move(source.firstSkippedReason);
    }
    target.errors.insert(target.errors.end(),
                         std::make_move_iterator(source.errors.begin()),
                         std::make_move_iterator(source.errors.end()));
}

void discardRayTracingTransaction() {
    RayTracePass::shared().invalidateHistory();
    AccelStructManager::shared().close();
}

simd_float4x4 simdMatrix(const std::array<float, 16> &values) {
    simd_float4x4 result;
    result.columns[0] = simd_make_float4(
        values[0], values[1], values[2], values[3]);
    result.columns[1] = simd_make_float4(
        values[4], values[5], values[6], values[7]);
    result.columns[2] = simd_make_float4(
        values[8], values[9], values[10], values[11]);
    result.columns[3] = simd_make_float4(
        values[12], values[13], values[14], values[15]);
    return result;
}

simd_float3 sceneDirection(const std::array<float, 12> &worldToScene,
                           const std::array<float, 3> &worldDirection) {
    const simd_float3 direction =
        simd_make_float3(worldToScene[0], worldToScene[1], worldToScene[2]) *
            worldDirection[0] +
        simd_make_float3(worldToScene[4], worldToScene[5], worldToScene[6]) *
            worldDirection[1] +
        simd_make_float3(worldToScene[8], worldToScene[9], worldToScene[10]) *
            worldDirection[2];
    const float lengthSquared = simd_length_squared(direction);
    return std::isfinite(lengthSquared) && lengthSquared > 1.0e-8F
        ? simd_normalize(direction)
        : simd_make_float3(0.0F, 1.0F, 0.0F);
}

simd_float3 sceneVector(const std::array<float, 12> &worldToScene,
                        const std::array<float, 3> &worldVector) {
    return simd_make_float3(
               worldToScene[0], worldToScene[1], worldToScene[2]) * worldVector[0] +
           simd_make_float3(
               worldToScene[4], worldToScene[5], worldToScene[6]) * worldVector[1] +
           simd_make_float3(
               worldToScene[8], worldToScene[9], worldToScene[10]) * worldVector[2];
}

simd_float3 simdVector(const std::array<float, 3> &values) {
    return simd_make_float3(values[0], values[1], values[2]);
}

bool isPrimaryEntityShader(const ShaderRecord &shader) {
    const std::string_view key = shader.key;
    const bool entityCore =
        key.find("minecraft:core/rendertype_entity_") != std::string_view::npos ||
        key.find("minecraft:core/rendertype_armor_") != std::string_view::npos ||
        key.find("minecraft:core/rendertype_item_entity_translucent_cull+") !=
            std::string_view::npos ||
        key.find("minecraft:core/entity+") != std::string_view::npos;
    if (!entityCore) {
        return false;
    }

    constexpr std::string_view excludedPasses[] = {
        "shadow",
        "glint",
        "eyes",
        "decal",
        "energy_swirl",
        "crumbling",
        "emissive",
        "rendertype_outline",
    };
    return std::none_of(std::begin(excludedPasses), std::end(excludedPasses),
                        [key](std::string_view excluded) {
        return key.find(excluded) != std::string_view::npos;
    });
}

} // namespace

FrameContext &FrameContext::shared() {
    static FrameContext frameContext;
    return frameContext;
}

bool FrameContext::begin() {
    CAMetalLayer *metalLayer = MetalDevice::shared().layer();
    id<MTLCommandQueue> commandQueue = MetalDevice::shared().commandQueue();
    if (metalLayer == nil || commandQueue == nil) {
        return false;
    }

    std::lock_guard lock(mutex_);
    closed_ = false;
    if (frameActive_) {
        NSLog(@"[ShaderMetal] Dropping an unfinished frame before starting the next frame");
        resetFrameLocked();
        RasterPass::shared().discardFrame();
    }

    RasterPass::shared().beginFrame();
    rayTracingState_.renderWorld = false;
    frameActive_ = true;
    clearEncoded_ = false;
    clearColor_ = configuredClearColor_;
    clearColorRequested_ = true;
    clearColorCaptured_ = false;
    clearDepthStencilMask_ |= 0x6U;
    return true;
}

bool FrameContext::acquireDrawableLocked() {
    if (drawable_ != nil && commandBuffer_ != nil) {
        return true;
    }

    CAMetalLayer *metalLayer = MetalDevice::shared().layer();
    id<MTLCommandQueue> commandQueue = MetalDevice::shared().commandQueue();
    if (metalLayer == nil || commandQueue == nil) {
        return false;
    }

    // Acquire only after Java has produced every draw for this frame. Holding a
    // drawable during CPU scene submission can exhaust CAMetalLayer's small pool.
    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    if (drawable == nil) {
        const std::uint64_t misses = unavailableDrawableCount_.fetch_add(1) + 1;
        if (misses == 1 || misses % 60 == 0) {
            NSLog(@"[ShaderMetal] CAMetalLayer returned no drawable (%llu total)",
                  static_cast<unsigned long long>(misses));
        }
        return false;
    }

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    if (commandBuffer == nil) {
        NSLog(@"[ShaderMetal] Failed to allocate a Metal command buffer");
        return false;
    }

    commandBuffer.label = @"ShaderMetal Raster Frame";
    drawable_ = drawable;
    commandBuffer_ = commandBuffer;
    return true;
}

void FrameContext::encodeStageAClear() {
    std::lock_guard lock(mutex_);
    encodeStageAClearLocked();
}

bool FrameContext::encodeStageAClearLocked() {
    if (!frameActive_ || !acquireDrawableLocked()) {
        return false;
    }
    if (clearEncoded_) {
        return true;
    }

    id<MTLDevice> device = MetalDevice::shared().device();
    const NSUInteger targetWidth = drawable_.texture.width;
    const NSUInteger targetHeight = drawable_.texture.height;
    if (device == nil || targetWidth == 0 || targetHeight == 0 ||
        !ensureDepthStencilTextureLocked(device, targetWidth, targetHeight)) {
        RasterPass::shared().discardFrame();
        return false;
    }

    RasterEncodeResult rasterResult;
    bool rayTracingReady = false;
    bool rayTracingSceneWarming = false;
    AccelerationSceneSnapshot scene;
    AccelerationUpdateResult accelerationResult;
    std::string rayTracingError;

    const std::vector<RayTracingDraw> rayTracingDraws =
        RasterPass::shared().rayTracingDraws();
    if (rayTracingState_.renderWorld && !rayTracingDraws.empty() &&
        AccelStructManager::shared().beginFrame(device, rayTracingError)) {
        for (const RayTracingDraw &draw : rayTracingDraws) {
            const std::optional<ShaderRecord> shader =
                ShaderRegistry::shared().shader(draw.shaderId);
            if (!shader.has_value() || !draw.worldDraw ||
                draw.instanceCount != 1 ||
                (shader->drawMode != 4 && shader->drawMode != 7)) {
                continue;
            }

            if (!draw.transientBuffers && shader->vertexFormatType == 0 &&
                shader->vertexStride == 32 &&
                shader->key.starts_with("minecraft:core/terrain+")) {
                WorldDrawInput input;
                input.vertexBufferId = draw.vertexId;
                input.indexBufferId = draw.indexId;
                input.vertexFormatType = shader->vertexFormatType;
                input.vertexStride = shader->vertexStride;
                input.drawMode = shader->drawMode;
                input.indexCount = draw.indexCount;
                input.indexType = draw.indexType;
                input.firstIndex = draw.firstIndex;
                input.firstVertex = draw.firstVertex;
                input.modelView = draw.modelView;
                input.projection = draw.projection;
                input.textureId = draw.textureId;
                input.metadataFlags = draw.translucent
                    ? kRTInstanceFlagTranslucent
                    : kRTInstanceFlagOpaque |
                        (shader->key.find("/alpha_cutout") != std::string::npos
                            ? kRTInstanceFlagAlphaTest : 0U);
                std::string observationError;
                if (!AccelStructManager::shared().observeWorldDraw(
                        input, observationError) && rayTracingError.empty()) {
                    rayTracingError = std::move(observationError);
                }
                continue;
            }

            if (draw.transientBuffers && shader->vertexFormatType == 1 &&
                shader->vertexStride == 36 && isPrimaryEntityShader(*shader)) {
                DynamicEntityDrawInput input;
                input.vertexBufferId = draw.vertexId;
                input.indexBufferId = draw.indexId;
                input.vertexFormatType = shader->vertexFormatType;
                input.vertexStride = shader->vertexStride;
                input.drawMode = shader->drawMode;
                input.indexCount = draw.indexCount;
                input.indexType = draw.indexType;
                input.instanceCount = draw.instanceCount;
                input.firstIndex = draw.firstIndex;
                input.firstVertex = draw.firstVertex;
                input.modelView = draw.modelView;
                input.textureId = draw.textureId;
                // A blended entity RenderType is raster compositing metadata,
                // not evidence that the skin is a dielectric transmission medium.
                input.materialFlags =
                    kRTInstanceFlagOpaque | kRTInstanceFlagAlphaTest;
                std::string ignoredObservationError;
                AccelStructManager::shared().observeDynamicEntityDraw(
                    input, ignoredObservationError);
            }
        }

        LocalPlayerShadowProxyInput localPlayerProxy;
        localPlayerProxy.enabled =
            rayTracingState_.localPlayerShadowProxyEnabled;
        localPlayerProxy.cameraRelativePosition =
            rayTracingState_.localPlayerCameraRelativePosition;
        localPlayerProxy.bodyYawRadians =
            rayTracingState_.localPlayerBodyYawRadians;
        localPlayerProxy.pose = rayTracingState_.localPlayerPose;
        localPlayerProxy.limbPhase = rayTracingState_.localPlayerLimbPhase;
        localPlayerProxy.limbAmplitude =
            rayTracingState_.localPlayerLimbAmplitude;
        localPlayerProxy.handSwingProgress =
            rayTracingState_.localPlayerHandSwingProgress;
        localPlayerProxy.headYawRadians =
            rayTracingState_.localPlayerHeadYawRadians;
        localPlayerProxy.headPitchRadians =
            rayTracingState_.localPlayerHeadPitchRadians;
        std::string proxyError;
        if (!AccelStructManager::shared().setLocalPlayerShadowProxy(
                localPlayerProxy, proxyError) && rayTracingError.empty()) {
            rayTracingError = std::move(proxyError);
        }

        std::string updateError;
        AccelerationBuildBudget buildBudget;
        buildBudget.maxNewBottomLevelBuilds = 4;
        buildBudget.maxNewTriangles = 65'536;
        accelerationResult = AccelStructManager::shared().encodeUpdates(
            commandBuffer_, buildBudget, rayTracingState_.cameraPosition,
            updateError);
        if (!updateError.empty()) {
            rayTracingError = std::move(updateError);
        } else {
            scene = AccelStructManager::shared().sceneSnapshot();
            rayTracingSceneWarming =
                accelerationResult.pendingBottomLevelBuildCount != 0 ||
                accelerationResult.rejectedGeometryCount != 0 ||
                accelerationResult.activeInstanceCount <
                    accelerationResult.eligibleInstanceCount;
            const bool hasActiveScene = scene.ready() &&
                accelerationResult.activeInstanceCount != 0;
            std::string initializationError;
            rayTracingReady = hasActiveScene &&
                RayTracePass::shared().initialize(device, initializationError);
            if (!rayTracingReady) {
                if (!hasActiveScene && rayTracingError.empty()) {
                    rayTracingError = accelerationResult.firstDiagnostic.empty()
                        ? "hardware RT scene is still warming up"
                        : accelerationResult.firstDiagnostic;
                } else if (hasActiveScene) {
                    rayTracingError = initializationError.empty()
                        ? "hardware RT pipeline initialization failed"
                        : std::move(initializationError);
                }
            }
        }
    }

    const std::uint64_t frameOrdinal = submittedFrameCount_.load() + 1;
    if (rayTracingReady &&
        (frameOrdinal == 1 || frameOrdinal % 300 == 0)) {
        NSLog(@"[ShaderMetal] Hardware RT scene frame %llu "
               "(instances=%zu, eligible=%zu, rejected=%zu, state=%s, "
               "dynamicDraws=%zu, dynamicTriangles=%zu, "
               "dynamicSkipped=%zu, dynamicBLAS=%s, playerShadowBLAS=%s, "
               "localLights=%zu, newBLAS=%zu, "
               "pendingBLAS=%zu, TLAS=%s)",
              static_cast<unsigned long long>(frameOrdinal),
              accelerationResult.activeInstanceCount,
              accelerationResult.eligibleInstanceCount,
              accelerationResult.rejectedGeometryCount,
              rayTracingSceneWarming ? "warming" : "ready",
              accelerationResult.encodedDynamicDrawCount,
              accelerationResult.dynamicTriangleCount,
              accelerationResult.skippedDynamicDrawCount,
              accelerationResult.rebuiltDynamicBottomLevel ? "build" :
                  (accelerationResult.refitDynamicBottomLevel ? "refit" : "none"),
              accelerationResult.rebuiltLocalPlayerBottomLevel ? "build" :
                  (accelerationResult.refitLocalPlayerBottomLevel
                      ? "refit" : "none"),
              rayTracingState_.localLightCount,
              accelerationResult.newBottomLevelBuildCount,
              accelerationResult.pendingBottomLevelBuildCount,
              accelerationResult.rebuiltTopLevel ? "rebuild" :
                  (accelerationResult.refitTopLevel ? "refit" : "reuse"));
    } else if (!rayTracingError.empty() &&
               (frameOrdinal == 1 || frameOrdinal % 300 == 0)) {
        NSLog(@"[ShaderMetal] Hardware RT frame %llu unavailable: %s",
              static_cast<unsigned long long>(frameOrdinal),
              rayTracingError.c_str());
    }
    if (!accelerationResult.dynamicFirstDiagnostic.empty() &&
        (frameOrdinal == 1 || frameOrdinal % 300 == 0)) {
        NSLog(@"[ShaderMetal] Hardware RT dynamic frame %llu "
               "diagnostic (skipped=%zu): %s",
              static_cast<unsigned long long>(frameOrdinal),
              accelerationResult.skippedDynamicDrawCount,
              accelerationResult.dynamicFirstDiagnostic.c_str());
    }

    const auto encodeRasterPartition = [&] (
        id<MTLTexture> colorTexture,
        MTLLoadAction colorLoadAction,
        MTLLoadAction depthLoadAction,
        MTLLoadAction stencilLoadAction,
        RasterPartition partition,
        NSString *label,
        RasterEncodeResult &partitionResult) -> bool {
        MTLRenderPassDescriptor *renderPass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        MTLRenderPassColorAttachmentDescriptor *colorAttachment =
            renderPass.colorAttachments[0];
        colorAttachment.texture = colorTexture;
        colorAttachment.loadAction = colorLoadAction;
        colorAttachment.storeAction = MTLStoreActionStore;
        colorAttachment.clearColor = clearColor_;

        MTLRenderPassDepthAttachmentDescriptor *depthAttachment =
            renderPass.depthAttachment;
        depthAttachment.texture = depthStencilTexture_;
        depthAttachment.loadAction = depthLoadAction;
        depthAttachment.storeAction = MTLStoreActionStore;
        depthAttachment.clearDepth = clearDepth_;

        MTLRenderPassStencilAttachmentDescriptor *stencilAttachment =
            renderPass.stencilAttachment;
        stencilAttachment.texture = depthStencilTexture_;
        stencilAttachment.loadAction = stencilLoadAction;
        stencilAttachment.storeAction = MTLStoreActionStore;
        stencilAttachment.clearStencil = clearStencil_;

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer_ renderCommandEncoderWithDescriptor:renderPass];
        if (encoder == nil) {
            return false;
        }
        encoder.label = label;
        partitionResult = RasterPass::shared().encodeQueuedDraws(
            encoder, targetWidth, targetHeight, partition);
        [encoder endEncoding];
        return true;
    };

    bool encoded = false;
    if (rayTracingReady &&
        ensureWorldColorTextureLocked(device, targetWidth, targetHeight)) {
        RasterEncodeResult worldResult;
        encoded = encodeRasterPartition(
            worldColorTexture_, MTLLoadActionClear, MTLLoadActionClear,
            MTLLoadActionClear, RasterPartition::World,
            @"ShaderMetal World Raster Base", worldResult);
        if (encoded) {
            appendRasterResult(rasterResult, std::move(worldResult));

            RayTraceLightingInput lightingInput;
            lightingInput.commandBuffer = commandBuffer_;
            lightingInput.topLevelAccelerationStructure = scene.topLevel;
            lightingInput.canonicalVertices = scene.canonicalVertices;
            lightingInput.canonicalVertexCount = scene.canonicalVertexCount;
            lightingInput.dynamicCanonicalVertices =
                scene.dynamicCanonicalVertices;
            lightingInput.dynamicCanonicalVertexCount =
                scene.dynamicCanonicalVertexCount;
            lightingInput.instanceMetadata = scene.instanceMetadata;
            lightingInput.instanceCount = scene.instanceCount;
            lightingInput.activeBottomLevelStructures = {
                scene.bottomLevels.data(), scene.bottomLevels.size()};
            lightingInput.projection = simdMatrix(scene.projection);
            lightingInput.viewToScene = simdMatrix(scene.viewToScene);
            lightingInput.cameraOrigin = simd_make_float3(0.0F, 0.0F, 0.0F);
            lightingInput.worldCameraPosition = simd_make_float3(
                static_cast<float>(rayTracingState_.cameraPosition[0]),
                static_cast<float>(rayTracingState_.cameraPosition[1]),
                static_cast<float>(rayTracingState_.cameraPosition[2]));
            lightingInput.cameraSubmergedInWater =
                rayTracingState_.cameraSubmergedInWater;
            lightingInput.sceneUpDirection = sceneDirection(
                scene.worldToSceneLinear,
                std::array<float, 3>{0.0F, 1.0F, 0.0F});
            lightingInput.sceneEast = sceneDirection(
                scene.worldToSceneLinear,
                std::array<float, 3>{1.0F, 0.0F, 0.0F});
            lightingInput.sceneNorth = sceneDirection(
                scene.worldToSceneLinear,
                std::array<float, 3>{0.0F, 0.0F, 1.0F});
            lightingInput.sunDirection = sceneDirection(
                scene.worldToSceneLinear,
                rayTracingState_.sunDirection);
            lightingInput.sunRadiance = simdVector(rayTracingState_.sunRadiance);
            lightingInput.moonDirection = sceneDirection(
                scene.worldToSceneLinear,
                rayTracingState_.moonDirection);
            lightingInput.moonRadiance = simdVector(rayTracingState_.moonRadiance);
            lightingInput.skyRadiance = simdVector(rayTracingState_.skyRadiance);
            lightingInput.weatherStrength = rayTracingState_.weatherStrength;

            std::array<RTLocalLight, 128> sceneLocalLights{};
            const simd_float4 sceneCameraHomogeneous = simd_mul(
                lightingInput.viewToScene,
                simd_make_float4(0.0F, 0.0F, 0.0F, 1.0F));
            const simd_float3 sceneCamera = simd_make_float3(
                sceneCameraHomogeneous.x, sceneCameraHomogeneous.y,
                sceneCameraHomogeneous.z) / sceneCameraHomogeneous.w;
            const std::size_t localLightCount = std::min(
                rayTracingState_.localLightCount, sceneLocalLights.size());
            for (std::size_t index = 0; index < localLightCount; ++index) {
                const RayTracingLocalLightState &source =
                    rayTracingState_.localLights[index];
                RTLocalLight &destination = sceneLocalLights[index];
                const simd_float3 position = sceneCamera + sceneVector(
                    scene.worldToSceneLinear, source.cameraRelativePosition);
                destination.position = {position.x, position.y, position.z};
                destination.radius = source.radius;
                destination.color = source.color;
                destination.intensity = source.intensity;
            }
            lightingInput.localLights = {
                sceneLocalLights.data(), localLightCount};
            lightingInput.worldColor = worldColorTexture_;
            lightingInput.worldDepth = depthStencilTexture_;
            lightingInput.outputWidth = std::max<NSUInteger>(1, (targetWidth + 1) / 2);
            lightingInput.outputHeight = std::max<NSUInteger>(1, (targetHeight + 1) / 2);
            lightingInput.frameIndex = static_cast<std::uint32_t>(frameOrdinal);
            lightingInput.historyReset = accelerationResult.reanchoredScene;

            encoded = RayTracePass::shared().encodeLighting(
                lightingInput, rayTracingError) &&
                RayTracePass::shared().encodeComposite(
                    commandBuffer_, worldColorTexture_, drawable_.texture,
                    rayTracingError);
        }
        if (encoded) {
            RasterEncodeResult uiResult;
            encoded = encodeRasterPartition(
                drawable_.texture, MTLLoadActionLoad, MTLLoadActionClear,
                MTLLoadActionClear, RasterPartition::Ui,
                @"ShaderMetal UI Raster Pass", uiResult);
            if (encoded) {
                appendRasterResult(rasterResult, std::move(uiResult));
            }
        }
    } else {
        RasterEncodeResult allResult;
        encoded = encodeRasterPartition(
            drawable_.texture,
            clearColorRequested_ ? MTLLoadActionClear : MTLLoadActionLoad,
            (clearDepthStencilMask_ & 0x2U) != 0
                ? MTLLoadActionClear : MTLLoadActionLoad,
            (clearDepthStencilMask_ & 0x4U) != 0
                ? MTLLoadActionClear : MTLLoadActionLoad,
            RasterPartition::All, @"ShaderMetal Raster Pass", allResult);
        if (encoded) {
            appendRasterResult(rasterResult, std::move(allResult));
        }
    }

    RasterPass::shared().releaseEncodedTransientBuffers();
    if (!encoded) {
        discardRayTracingTransaction();
        NSLog(@"[ShaderMetal] Frame encoding failed%s%s",
              rayTracingError.empty() ? "" : ": ",
              rayTracingError.c_str());
        return false;
    }

    const std::uint64_t previousSubmittedDraws = submittedDrawCount_.fetch_add(
        rasterResult.submittedDrawCount);
    encodedDrawCount_.fetch_add(rasterResult.encodedDrawCount);
    if (rasterResult.submittedDrawCount != 0) {
        framesWithDraws_.fetch_add(1);
        if (previousSubmittedDraws == 0) {
            NSLog(@"[ShaderMetal] First raster frame with draws "
                   "(submitted=%zu, encoded=%zu, skipped=%zu, errors=%zu)",
                  rasterResult.submittedDrawCount, rasterResult.encodedDrawCount,
                  rasterResult.skippedDrawCount, rasterResult.errors.size());
        }
    }

    if (frameOrdinal == 1 || frameOrdinal % 300 == 0) {
        NSLog(@"[ShaderMetal] Raster frame %llu "
               "(submitted=%zu, encoded=%zu, skipped=%zu, errors=%zu)",
              static_cast<unsigned long long>(frameOrdinal),
              rasterResult.submittedDrawCount, rasterResult.encodedDrawCount,
              rasterResult.skippedDrawCount, rasterResult.errors.size());
        if (!rasterResult.firstSkippedReason.empty()) {
            NSLog(@"[ShaderMetal] Raster frame %llu first skip: %s",
                  static_cast<unsigned long long>(frameOrdinal),
                  rasterResult.firstSkippedReason.c_str());
        }
    }

    constexpr std::size_t kMaxLoggedRasterErrors = 8;
    const std::size_t loggedErrorCount = rasterResult.errors.size() <
            kMaxLoggedRasterErrors
        ? rasterResult.errors.size()
        : kMaxLoggedRasterErrors;
    for (std::size_t index = 0; index < loggedErrorCount; ++index) {
        const RasterError &error = rasterResult.errors[index];
        NSLog(@"[ShaderMetal] Raster draw %zu failed (code=%u): %s",
              error.drawIndex, static_cast<unsigned int>(error.code),
              error.message.c_str());
    }
    if (rasterResult.errors.size() > loggedErrorCount) {
        NSLog(@"[ShaderMetal] Suppressed %zu additional raster draw errors this frame",
              rasterResult.errors.size() - loggedErrorCount);
    }
    failedDrawCount_.fetch_add(rasterResult.errors.size());
    clearColorRequested_ = false;
    clearDepthStencilMask_ = 0;
    clearEncoded_ = true;
    return true;
}

bool FrameContext::ensureDepthStencilTextureLocked(id<MTLDevice> device,
                                                    NSUInteger width,
                                                    NSUInteger height) {
    if (depthStencilTexture_ != nil && depthStencilTexture_.device == device &&
        depthStencilTexture_.width == width && depthStencilTexture_.height == height) {
        return true;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture == nil) {
        NSLog(@"[ShaderMetal] Failed to allocate %lux%lu depth-stencil target",
              static_cast<unsigned long>(width), static_cast<unsigned long>(height));
        return false;
    }
    texture.label = @"ShaderMetal Depth Stencil";
    depthStencilTexture_ = texture;
    return true;
}

bool FrameContext::ensureWorldColorTextureLocked(id<MTLDevice> device,
                                                 NSUInteger width,
                                                 NSUInteger height) {
    if (worldColorTexture_ != nil && worldColorTexture_.device == device &&
        worldColorTexture_.width == width && worldColorTexture_.height == height) {
        return true;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture == nil) {
        NSLog(@"[ShaderMetal] Failed to allocate %lux%lu world color target",
              static_cast<unsigned long>(width),
              static_cast<unsigned long>(height));
        return false;
    }
    texture.label = @"ShaderMetal World Color";
    worldColorTexture_ = texture;
    return true;
}

void FrameContext::presentAndCommit() {
    std::lock_guard lock(mutex_);
    if (!frameActive_) {
        return;
    }
    if (!encodeStageAClearLocked()) {
        discardRayTracingTransaction();
        RasterPass::shared().discardFrame();
        resetFrameLocked();
        return;
    }

    id<MTLCommandBuffer> commandBuffer = commandBuffer_;
    id<CAMetalDrawable> drawable = drawable_;
    const std::uint64_t submittedFrame = submittedFrameCount_.fetch_add(1) + 1;
    FrameContext *context = this;

    [commandBuffer presentDrawable:drawable];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedBuffer) {
        @autoreleasepool {
            const std::uint64_t completed = context->completedFrameCount_.fetch_add(1) + 1;
            if (completedBuffer.status == MTLCommandBufferStatusError) {
                discardRayTracingTransaction();
                const std::uint64_t failed = context->failedFrameCount_.fetch_add(1) + 1;
                NSLog(@"[ShaderMetal] Metal frame %llu failed (%llu failures): %@",
                      static_cast<unsigned long long>(submittedFrame),
                      static_cast<unsigned long long>(failed), completedBuffer.error);
            } else if (completed == 1 || completed % 300 == 0) {
                NSLog(@"[ShaderMetal] Completed Metal frames: %llu",
                      static_cast<unsigned long long>(completed));
            }
        }
    }];
    [commandBuffer commit];
    resetFrameLocked();
}

void FrameContext::setClearColor(float red, float green, float blue, float alpha) {
    std::lock_guard lock(mutex_);
    configuredClearColor_ = MTLClearColorMake(red, green, blue, alpha);
    if (!clearColorCaptured_) {
        clearColor_ = configuredClearColor_;
    }
}

void FrameContext::setClearDepth(double depth) {
    std::lock_guard lock(mutex_);
    clearDepth_ = depth;
}

void FrameContext::setClearStencil(std::uint32_t stencil) {
    std::lock_guard lock(mutex_);
    clearStencil_ = stencil;
}

void FrameContext::requestClearColor() {
    std::lock_guard lock(mutex_);
    if (!clearColorCaptured_) {
        clearColor_ = configuredClearColor_;
        clearColorCaptured_ = true;
    }
    clearColorRequested_ = true;
}

void FrameContext::requestClearDepthStencil(std::uint32_t aspectMask) {
    std::lock_guard lock(mutex_);
    clearDepthStencilMask_ |= aspectMask & 0x6U;
}

void FrameContext::setShouldRenderWorld(bool renderWorld) {
    std::lock_guard lock(mutex_);
    rayTracingState_.renderWorld = renderWorld;
}

void FrameContext::resetRayTracingScene() {
    std::lock_guard lock(mutex_);
    AccelStructManager::shared().close();
    RayTracePass::shared().invalidateHistory();
}

void FrameContext::setCameraPosition(double x, double y, double z) {
    std::lock_guard lock(mutex_);
    rayTracingState_.cameraPosition = {x, y, z};
}

void FrameContext::setCameraSubmergedInWater(bool submerged) {
    std::lock_guard lock(mutex_);
    rayTracingState_.cameraSubmergedInWater = submerged;
}

void FrameContext::setLocalPlayerShadowProxy(
    bool enabled, const std::array<float, 3> &cameraRelativePosition,
    float bodyYawRadians, std::uint32_t pose, float limbPhase,
    float limbAmplitude, float handSwingProgress, float headYawRadians,
    float headPitchRadians) {
    std::lock_guard lock(mutex_);
    const bool finiteInput = std::all_of(
        cameraRelativePosition.begin(), cameraRelativePosition.end(),
        [](float value) { return std::isfinite(value); }) &&
        std::isfinite(bodyYawRadians) && std::isfinite(limbPhase) &&
        std::isfinite(limbAmplitude) && std::isfinite(handSwingProgress) &&
        std::isfinite(headYawRadians) && std::isfinite(headPitchRadians);
    rayTracingState_.localPlayerShadowProxyEnabled = enabled && finiteInput;
    rayTracingState_.localPlayerCameraRelativePosition = finiteInput
        ? cameraRelativePosition : std::array<float, 3>{};
    rayTracingState_.localPlayerBodyYawRadians = finiteInput
        ? bodyYawRadians : 0.0F;
    rayTracingState_.localPlayerPose = pose <= 2U ? pose : 0U;
    rayTracingState_.localPlayerLimbPhase = finiteInput ? limbPhase : 0.0F;
    rayTracingState_.localPlayerLimbAmplitude = finiteInput
        ? std::clamp(limbAmplitude, 0.0F, 1.0F) : 0.0F;
    rayTracingState_.localPlayerHandSwingProgress = finiteInput
        ? std::clamp(handSwingProgress, 0.0F, 1.0F) : 0.0F;
    rayTracingState_.localPlayerHeadYawRadians = finiteInput
        ? std::clamp(headYawRadians, -1.4835298F, 1.4835298F) : 0.0F;
    rayTracingState_.localPlayerHeadPitchRadians = finiteInput
        ? std::clamp(headPitchRadians, -1.3962634F, 1.3962634F) : 0.0F;
}

void FrameContext::setCelestialLighting(
    const std::array<float, 3> &sunDirection,
    const std::array<float, 3> &sunRadiance,
    const std::array<float, 3> &moonDirection,
    const std::array<float, 3> &moonRadiance,
    const std::array<float, 3> &skyRadiance,
    float weatherStrength) {
    std::lock_guard lock(mutex_);
    rayTracingState_.sunDirection = sunDirection;
    rayTracingState_.sunRadiance = sunRadiance;
    rayTracingState_.moonDirection = moonDirection;
    rayTracingState_.moonRadiance = moonRadiance;
    rayTracingState_.skyRadiance = skyRadiance;
    rayTracingState_.weatherStrength = std::isfinite(weatherStrength)
        ? std::clamp(weatherStrength, 0.0F, 1.0F) : 0.0F;
}

void FrameContext::setLocalLights(const void *source, std::size_t count) {
    std::lock_guard lock(mutex_);
    const std::size_t safeCount = std::min(count, rayTracingState_.localLights.size());
    if (safeCount != 0 && source != nullptr) {
        std::memcpy(rayTracingState_.localLights.data(), source,
                    safeCount * sizeof(RayTracingLocalLightState));
    }
    rayTracingState_.localLightCount = source == nullptr ? 0 : safeCount;
}

RayTracingFrameState FrameContext::rayTracingState() {
    std::lock_guard lock(mutex_);
    return rayTracingState_;
}

void FrameContext::close() {
    std::lock_guard lock(mutex_);
    if (closed_ && !frameActive_ && commandBuffer_ == nil && drawable_ == nil) {
        return;
    }
    closed_ = true;
    resetFrameLocked();
    depthStencilTexture_ = nil;
    worldColorTexture_ = nil;
    configuredClearColor_ = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    clearColor_ = configuredClearColor_;
    clearColorRequested_ = true;
    clearColorCaptured_ = false;
    clearDepthStencilMask_ = 0x6U;
    rayTracingState_ = {};
    RasterPass::shared().close();
    RayTracePass::shared().close();
    AccelStructManager::shared().close();
    NSLog(@"[ShaderMetal] Frame context closed "
           "(submitted=%llu, completed=%llu, failed=%llu, drawFrames=%llu, "
           "submittedDraws=%llu, encodedDraws=%llu, drawErrors=%llu)",
          static_cast<unsigned long long>(submittedFrameCount_.load()),
          static_cast<unsigned long long>(completedFrameCount_.load()),
          static_cast<unsigned long long>(failedFrameCount_.load()),
          static_cast<unsigned long long>(framesWithDraws_.load()),
          static_cast<unsigned long long>(submittedDrawCount_.load()),
          static_cast<unsigned long long>(encodedDrawCount_.load()),
          static_cast<unsigned long long>(failedDrawCount_.load()));
}

void FrameContext::resetFrameLocked() {
    clearEncoded_ = false;
    frameActive_ = false;
    commandBuffer_ = nil;
    drawable_ = nil;
}

} // namespace shadermetal
