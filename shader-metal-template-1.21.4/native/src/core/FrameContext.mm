#include "core/FrameContext.hpp"

#include "core/MetalDevice.hpp"

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
    if (drawable_ != nil || commandBuffer_ != nil) {
        NSLog(@"[ShaderMetal] Dropping an unfinished frame before acquiring the next drawable");
        resetFrameLocked();
    }

    // The render callback owns drawable acquisition; GLFW may invoke that callback on main.
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

    commandBuffer.label = @"ShaderMetal Stage A Frame";
    drawable_ = drawable;
    commandBuffer_ = commandBuffer;
    clearEncoded_ = false;
    return true;
}

void FrameContext::encodeStageAClear() {
    std::lock_guard lock(mutex_);
    encodeStageAClearLocked();
}

bool FrameContext::encodeStageAClearLocked() {
    if (commandBuffer_ == nil || drawable_ == nil) {
        return false;
    }
    if (clearEncoded_) {
        return true;
    }

    MTLRenderPassDescriptor *renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassColorAttachmentDescriptor *colorAttachment =
        renderPass.colorAttachments[0];
    colorAttachment.texture = drawable_.texture;
    colorAttachment.loadAction = MTLLoadActionClear;
    colorAttachment.storeAction = MTLStoreActionStore;
    colorAttachment.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer_ renderCommandEncoderWithDescriptor:renderPass];
    if (encoder == nil) {
        NSLog(@"[ShaderMetal] Failed to create the stage A clear encoder");
        return false;
    }
    encoder.label = @"ShaderMetal Black Clear";
    [encoder endEncoding];
    clearEncoded_ = true;
    return true;
}

void FrameContext::presentAndCommit() {
    std::lock_guard lock(mutex_);
    if (commandBuffer_ == nil || drawable_ == nil) {
        return;
    }
    if (!encodeStageAClearLocked()) {
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

void FrameContext::close() {
    std::lock_guard lock(mutex_);
    if (closed_ && commandBuffer_ == nil && drawable_ == nil) {
        return;
    }
    closed_ = true;
    resetFrameLocked();
    NSLog(@"[ShaderMetal] Frame context closed (submitted=%llu, completed=%llu, failed=%llu)",
          static_cast<unsigned long long>(submittedFrameCount_.load()),
          static_cast<unsigned long long>(completedFrameCount_.load()),
          static_cast<unsigned long long>(failedFrameCount_.load()));
}

void FrameContext::resetFrameLocked() {
    clearEncoded_ = false;
    commandBuffer_ = nil;
    drawable_ = nil;
}

} // namespace shadermetal
