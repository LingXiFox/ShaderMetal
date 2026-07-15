#pragma once

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <atomic>
#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace shadermetal {

struct alignas(16) RayTracingLocalLightState final {
    std::array<float, 3> cameraRelativePosition{};
    float radius = 0.0F;
    std::array<float, 3> color{};
    float intensity = 0.0F;
};

static_assert(sizeof(RayTracingLocalLightState) == 32);

struct RayTracingFrameState final {
    bool renderWorld = false;
    std::array<double, 3> cameraPosition{};
    bool cameraSubmergedInWater = false;
    bool localPlayerShadowProxyEnabled = false;
    std::array<float, 3> localPlayerCameraRelativePosition{};
    float localPlayerBodyYawRadians = 0.0F;
    std::uint32_t localPlayerPose = 0;
    float localPlayerLimbPhase = 0.0F;
    float localPlayerLimbAmplitude = 0.0F;
    float localPlayerHandSwingProgress = 0.0F;
    float localPlayerHeadYawRadians = 0.0F;
    float localPlayerHeadPitchRadians = 0.0F;
    std::array<float, 3> sunDirection{0.0F, 1.0F, 0.0F};
    std::array<float, 3> sunRadiance{1.0F, 0.96F, 0.86F};
    std::array<float, 3> moonDirection{0.0F, -1.0F, 0.0F};
    std::array<float, 3> moonRadiance{};
    std::array<float, 3> skyRadiance{0.20F, 0.28F, 0.42F};
    float weatherStrength = 0.0F;
    std::array<RayTracingLocalLightState, 128> localLights{};
    std::size_t localLightCount = 0;
};

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
    void setShouldRenderWorld(bool renderWorld);
    void resetRayTracingScene();
    void setCameraPosition(double x, double y, double z);
    void setCameraSubmergedInWater(bool submerged);
    void setLocalPlayerShadowProxy(
        bool enabled, const std::array<float, 3> &cameraRelativePosition,
        float bodyYawRadians, std::uint32_t pose, float limbPhase,
        float limbAmplitude, float handSwingProgress, float headYawRadians,
        float headPitchRadians);
    void setCelestialLighting(const std::array<float, 3> &sunDirection,
                              const std::array<float, 3> &sunRadiance,
                              const std::array<float, 3> &moonDirection,
                              const std::array<float, 3> &moonRadiance,
                              const std::array<float, 3> &skyRadiance,
                              float weatherStrength);
    void setLocalLights(const void *source, std::size_t count);
    RayTracingFrameState rayTracingState();
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
    bool ensureWorldColorTextureLocked(id<MTLDevice> device,
                                       NSUInteger width,
                                       NSUInteger height);
    void resetFrameLocked();

    std::mutex mutex_;
    id<CAMetalDrawable> drawable_ = nil;
    id<MTLCommandBuffer> commandBuffer_ = nil;
    id<MTLTexture> depthStencilTexture_ = nil;
    id<MTLTexture> worldColorTexture_ = nil;
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
    RayTracingFrameState rayTracingState_{};
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
