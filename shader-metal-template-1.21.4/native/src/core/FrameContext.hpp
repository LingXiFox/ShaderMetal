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
    void close();

    FrameContext(const FrameContext &) = delete;
    FrameContext &operator=(const FrameContext &) = delete;

private:
    FrameContext() = default;
    ~FrameContext() = default;

    bool encodeStageAClearLocked();
    void resetFrameLocked();

    std::mutex mutex_;
    id<CAMetalDrawable> drawable_ = nil;
    id<MTLCommandBuffer> commandBuffer_ = nil;
    bool clearEncoded_ = false;
    bool closed_ = true;
    std::atomic<std::uint64_t> submittedFrameCount_{0};
    std::atomic<std::uint64_t> completedFrameCount_{0};
    std::atomic<std::uint64_t> failedFrameCount_{0};
    std::atomic<std::uint64_t> unavailableDrawableCount_{0};
};

} // namespace shadermetal
