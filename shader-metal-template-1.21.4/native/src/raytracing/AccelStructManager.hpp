#pragma once

#import <Metal/Metal.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace shadermetal {

// Canonical, non-indexed triangle vertex consumed by RayTrace.metal. The
// user_instance_id stored in the TLAS is the first RTVertex for that instance,
// so primitive N begins at user_instance_id + N * 3.
struct RTVertex final {
    float position[3];
    std::int8_t normal[4];
    float uv[2];
    std::uint8_t color[4];
    std::int32_t textureId;
};

static_assert(sizeof(RTVertex) == 32, "RTVertex must match the Metal ABI");
static_assert(offsetof(RTVertex, normal) == 12);
static_assert(offsetof(RTVertex, uv) == 16);
static_assert(offsetof(RTVertex, color) == 24);
static_assert(offsetof(RTVertex, textureId) == 28);

// Indexed by Metal's instance_id, not user_instance_id. normalToScene stores
// three float4-padded columns of inverse-transpose(localToScene.linear):
// N * v = column0 * v.x + column1 * v.y + column2 * v.z.
struct RTInstanceMetadata final {
    float normalToScene[12];
    std::uint32_t canonicalVertexOffset;
    std::uint32_t canonicalVertexCount;
    std::int32_t textureId;
    std::uint32_t flags;
};

static_assert(sizeof(RTInstanceMetadata) == 64,
              "RTInstanceMetadata must match the Metal ABI");

inline constexpr std::uint32_t kRTInstanceFlagOpaque = 1U << 0U;
inline constexpr std::uint32_t kRTInstanceFlagDynamicVertexBuffer = 1U << 1U;
inline constexpr std::uint32_t kRTInstanceFlagTranslucent = 1U << 2U;
inline constexpr std::uint32_t kRTInstanceFlagAlphaTest = 1U << 3U;

struct WorldDrawInput final {
    std::int32_t vertexBufferId = -1;
    std::int32_t indexBufferId = -1;
    std::int32_t vertexFormatType = -1;
    std::size_t vertexStride = 0;
    std::int32_t drawMode = -1;
    std::int32_t indexCount = 0;
    std::int32_t indexType = -1;
    std::int32_t firstIndex = 0;
    std::int32_t firstVertex = 0;
    std::array<float, 16> modelView{};
    std::array<float, 16> projection{};
    std::int32_t textureId = -1;
    std::uint32_t metadataFlags = kRTInstanceFlagOpaque;
};

struct DynamicEntityDrawInput final {
    std::int32_t vertexBufferId = -1;
    std::int32_t indexBufferId = -1;
    std::int32_t vertexFormatType = -1;
    std::size_t vertexStride = 0;
    std::int32_t drawMode = -1;
    std::int32_t indexCount = 0;
    std::int32_t indexType = -1;
    std::int32_t instanceCount = 0;
    std::int32_t firstIndex = 0;
    std::int32_t firstVertex = 0;
    std::array<float, 16> modelView{};
    std::int32_t textureId = -1;
    std::uint32_t materialFlags = kRTInstanceFlagOpaque;
};

struct LocalPlayerShadowProxyInput final {
    bool enabled = false;
    std::array<float, 3> cameraRelativePosition{};
    float bodyYawRadians = 0.0F;
    // 0 = standing, 1 = crouching, 2 = swimming/gliding.
    std::uint32_t pose = 0;
    float limbPhase = 0.0F;
    float limbAmplitude = 0.0F;
    float handSwingProgress = 0.0F;
    float headYawRadians = 0.0F;
    float headPitchRadians = 0.0F;
};

struct AccelerationBuildBudget final {
    std::size_t maxNewBottomLevelBuilds = 8;
    std::size_t maxNewTriangles = 262'144;
    std::size_t maxDynamicTriangles = 65'536;
    std::size_t maxDynamicVertices = 196'608;
};

struct AccelerationUpdateResult final {
    std::size_t observedInstanceCount = 0;
    std::size_t activeInstanceCount = 0;
    std::size_t newBottomLevelBuildCount = 0;
    std::size_t pendingBottomLevelBuildCount = 0;
    std::size_t rejectedGeometryCount = 0;
    std::size_t eligibleInstanceCount = 0;
    std::size_t filteredInstanceCount = 0;
    std::size_t retainedInvisibleInstanceCount = 0;
    std::size_t observedDynamicDrawCount = 0;
    std::size_t encodedDynamicDrawCount = 0;
    std::size_t skippedDynamicDrawCount = 0;
    std::size_t dynamicTriangleCount = 0;
    std::size_t dynamicVertexCount = 0;
    std::string firstDiagnostic;
    std::string dynamicFirstDiagnostic;
    bool rebuiltTopLevel = false;
    bool refitTopLevel = false;
    bool rebuiltDynamicBottomLevel = false;
    bool refitDynamicBottomLevel = false;
    bool rebuiltLocalPlayerBottomLevel = false;
    bool refitLocalPlayerBottomLevel = false;
    bool reanchoredScene = false;
};

// A value snapshot intentionally owns every resource needed by an encoded ray
// pass. RayTracePass should declare the TLAS, canonical/metadata buffers, and
// every bottom-level AS in bottomLevels with useResource before dispatch.
struct AccelerationSceneSnapshot final {
    id<MTLAccelerationStructure> topLevel = nil;
    id<MTLBuffer> canonicalVertices = nil;
    id<MTLBuffer> dynamicCanonicalVertices = nil;
    id<MTLAccelerationStructure> dynamicBottomLevel = nil;
    id<MTLBuffer> instanceMetadata = nil;
    std::vector<id<MTLAccelerationStructure>> bottomLevels;
    std::array<float, 16> projection{};
    // Current camera view -> fixed acceleration-structure scene space.
    std::array<float, 16> viewToScene{
        1.0F, 0.0F, 0.0F, 0.0F,
        0.0F, 1.0F, 0.0F, 0.0F,
        0.0F, 0.0F, 1.0F, 0.0F,
        0.0F, 0.0F, 0.0F, 1.0F,
    };
    // Fixed world -> scene direction transform as three float4-padded columns.
    std::array<float, 12> worldToSceneLinear{
        1.0F, 0.0F, 0.0F, 0.0F,
        0.0F, 1.0F, 0.0F, 0.0F,
        0.0F, 0.0F, 1.0F, 0.0F,
    };
    std::size_t canonicalVertexCount = 0;
    std::size_t dynamicCanonicalVertexCount = 0;
    std::size_t instanceCount = 0;
    std::uint64_t generation = 0;

    bool ready() const noexcept {
        return topLevel != nil && canonicalVertices != nil &&
               instanceMetadata != nil && instanceCount != 0;
    }
};

class AccelStructManager final {
public:
    static AccelStructManager &shared();

    // beginFrame invalidates only the per-frame observation set. Cached BLASes
    // and the append-only canonical vertex allocation survive across frames.
    bool beginFrame(id<MTLDevice> device, std::string &error);

    // Call only for persistent world terrain draws after queued buffer uploads
    // have reached their shared MTLBuffers.
    bool observeWorldDraw(const WorldDrawInput &draw, std::string &error);

    // Transient entity draws are copied into a separate frame-local canonical
    // buffer. They never enter the persistent geometry cache or append-only
    // terrain canonical allocation.
    bool observeDynamicEntityDraw(const DynamicEntityDrawInput &draw,
                                  std::string &error);

    // The first-person player is absent from vanilla's raster draw stream. This
    // proxy is generated directly into a shadow-only Metal BLAS (instance mask
    // 0x02) and never submitted to the raster pass.
    bool setLocalPlayerShadowProxy(const LocalPlayerShadowProxyInput &proxy,
                                   std::string &error);

    // Encodes real BLAS/TLAS build or refit commands into commandBuffer. It
    // never commits, waits for, or otherwise synchronizes the command buffer.
    AccelerationUpdateResult encodeUpdates(
        id<MTLCommandBuffer> commandBuffer,
        const AccelerationBuildBudget &budget,
        const std::array<double, 3> &worldCameraPosition,
        std::string &error);

    AccelerationSceneSnapshot sceneSnapshot() const;
    void close();

    AccelStructManager(const AccelStructManager &) = delete;
    AccelStructManager &operator=(const AccelStructManager &) = delete;

private:
    struct Impl;

    AccelStructManager();
    ~AccelStructManager();

    std::unique_ptr<Impl> impl_;
};

} // namespace shadermetal
