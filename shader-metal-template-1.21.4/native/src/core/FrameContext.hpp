#pragma once

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <atomic>
#include <cstdint>
#include <mutex>

namespace shadermetal {

class FrameContext final {
public:
    static FrameContext &shared();

    bool begin();
    void encodeStageAClear();
    void presentAndCommit();
    void setClearColor(float red, float green, float blue, float alpha);
    void setClearDepth(double depth);
    void setClearStencil(std::uint32_t stencil);
    void requestClearColor();
    void requestClearDepthStencil(std::uint32_t aspectMask);
    void close();

    FrameContext(const FrameContext &) = delete;
    FrameContext &operator=(const FrameContext &) = delete;

private:
    FrameContext() = default;
    ~FrameContext() = default;

    bool acquireDrawableLocked();
    bool encodeStageAClearLocked();
    bool ensureDepthStencilTextureLocked(id<MTLDevice> device,
                                         NSUInteger width,
                                         NSUInteger height);
    void resetFrameLocked();

    std::mutex mutex_;
    id<CAMetalDrawable> drawable_ = nil;
    id<MTLCommandBuffer> commandBuffer_ = nil;
    id<MTLTexture> depthStencilTexture_ = nil;
    MTLClearColor configuredClearColor_ = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    MTLClearColor clearColor_ = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    double clearDepth_ = 1.0;
    std::uint32_t clearStencil_ = 0;
    bool clearColorRequested_ = true;
    bool clearColorCaptured_ = false;
    std::uint32_t clearDepthStencilMask_ = 0x6U;
    bool clearEncoded_ = false;
    bool frameActive_ = false;
    bool closed_ = true;
    std::atomic<std::uint64_t> submittedFrameCount_{0};
    std::atomic<std::uint64_t> completedFrameCount_{0};
    std::atomic<std::uint64_t> failedFrameCount_{0};
    std::atomic<std::uint64_t> submittedDrawCount_{0};
    std::atomic<std::uint64_t> encodedDrawCount_{0};
    std::atomic<std::uint64_t> framesWithDraws_{0};
    std::atomic<std::uint64_t> failedDrawCount_{0};
    std::atomic<std::uint64_t> unavailableDrawableCount_{0};
};

} // namespace shadermetal
