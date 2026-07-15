#include "core/FrameContext.hpp"

#include "core/MetalDevice.hpp"
#include "render/RasterPass.hpp"

namespace shadermetal {

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

    MTLRenderPassDescriptor *renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassColorAttachmentDescriptor *colorAttachment =
        renderPass.colorAttachments[0];
    colorAttachment.texture = drawable_.texture;
    colorAttachment.loadAction = clearColorRequested_
        ? MTLLoadActionClear
        : MTLLoadActionLoad;
    colorAttachment.storeAction = MTLStoreActionStore;
    colorAttachment.clearColor = clearColor_;

    MTLRenderPassDepthAttachmentDescriptor *depthAttachment = renderPass.depthAttachment;
    depthAttachment.texture = depthStencilTexture_;
    depthAttachment.loadAction = (clearDepthStencilMask_ & 0x2U) != 0
        ? MTLLoadActionClear
        : MTLLoadActionLoad;
    depthAttachment.storeAction = MTLStoreActionStore;
    depthAttachment.clearDepth = clearDepth_;

    MTLRenderPassStencilAttachmentDescriptor *stencilAttachment =
        renderPass.stencilAttachment;
    stencilAttachment.texture = depthStencilTexture_;
    stencilAttachment.loadAction = (clearDepthStencilMask_ & 0x4U) != 0
        ? MTLLoadActionClear
        : MTLLoadActionLoad;
    stencilAttachment.storeAction = MTLStoreActionStore;
    stencilAttachment.clearStencil = clearStencil_;

    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer_ renderCommandEncoderWithDescriptor:renderPass];
    if (encoder == nil) {
        NSLog(@"[ShaderMetal] Failed to create the raster encoder");
        RasterPass::shared().discardFrame();
        return false;
    }
    encoder.label = @"ShaderMetal Raster Pass";
    const RasterEncodeResult rasterResult = RasterPass::shared().encodeQueuedDraws(
        encoder, targetWidth, targetHeight);
    [encoder endEncoding];
    RasterPass::shared().releaseEncodedTransientBuffers();

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

    const std::uint64_t frameOrdinal = submittedFrameCount_.load() + 1;
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
    descriptor.usage = MTLTextureUsageRenderTarget;
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

void FrameContext::presentAndCommit() {
    std::lock_guard lock(mutex_);
    if (!frameActive_) {
        return;
    }
    if (!encodeStageAClearLocked()) {
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

void FrameContext::close() {
    std::lock_guard lock(mutex_);
    if (closed_ && !frameActive_ && commandBuffer_ == nil && drawable_ == nil) {
        return;
    }
    closed_ = true;
    resetFrameLocked();
    depthStencilTexture_ = nil;
    configuredClearColor_ = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    clearColor_ = configuredClearColor_;
    clearColorRequested_ = true;
    clearColorCaptured_ = false;
    clearDepthStencilMask_ = 0x6U;
    RasterPass::shared().close();
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
