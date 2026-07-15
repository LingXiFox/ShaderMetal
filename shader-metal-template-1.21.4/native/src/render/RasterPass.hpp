#pragma once

#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>
#include <array>
#include <functional>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace shadermetal {

enum class RasterErrorCode : std::uint8_t {
    InvalidCommand,
    MissingShader,
    MissingVertexBuffer,
    MissingIndexBuffer,
    BufferRange,
    UniformMismatch,
    MissingResourceBinder,
    UnsupportedState,
    PipelineCreation,
    DepthStencilCreation,
    ResourceBinding,
};

struct RasterError final {
    RasterErrorCode code = RasterErrorCode::InvalidCommand;
    std::size_t drawIndex = 0;
    std::string message;
};

struct RasterEncodeResult final {
    std::size_t submittedDrawCount = 0;
    std::size_t encodedDrawCount = 0;
    std::size_t skippedDrawCount = 0;
    std::string firstSkippedReason;
    std::vector<RasterError> errors;

    bool success() const noexcept {
        return errors.empty();
    }
};

struct DrawUniformBindings final {
    std::span<const std::byte> perDraw;
    std::span<const std::byte> world;
    std::span<const std::byte> sky;
    std::span<const std::byte> overlayPost;
};

enum class RasterPartition : std::uint8_t {
    All,
    World,
    Ui,
};

struct RayTracingDraw final {
    std::int32_t vertexId = -1;
    std::int32_t indexId = -1;
    std::int32_t shaderId = -1;
    std::int32_t indexCount = 0;
    std::int32_t indexType = -1;
    std::int32_t firstIndex = 0;
    std::int32_t firstVertex = 0;
    std::int32_t textureId = 0;
    std::array<float, 16> modelView{};
    std::array<float, 16> projection{};
    std::int32_t instanceCount = 0;
    bool worldDraw = false;
    bool transientBuffers = true;
    bool translucent = false;
};

class RasterPass final {
public:
    static constexpr NSUInteger kTextureArgumentBufferIndex = 0;
    static constexpr NSUInteger kPerDrawUniformBufferIndex = 1;
    static constexpr NSUInteger kWorldUniformBufferIndex = 2;
    static constexpr NSUInteger kSkyUniformBufferIndex = 3;
    static constexpr NSUInteger kOverlayPostUniformBufferIndex = 4;
    static constexpr NSUInteger kVertexBufferIndex = 30;
    static constexpr NSUInteger kTextureTableSize = 4096;

    using ResourceBinder = std::function<bool(
        id<MTLRenderCommandEncoder> encoder, std::int32_t shaderId,
        const DrawUniformBindings &uniforms, std::string &error)>;

    static RasterPass &shared();

    void beginFrame();
    bool enqueueDraw(std::int32_t vertexId, std::int32_t indexId,
                     std::int32_t shaderId, std::int32_t indexCount,
                     std::int32_t indexType, const void *uniformData,
                     std::size_t uniformSize, std::int32_t instanceCount,
                     std::int32_t firstIndex, std::int32_t firstVertex,
                     const void *matrixData, std::int32_t textureId,
                     bool worldDraw, bool transientBuffers, std::string &error);
    bool deferBufferRelease(std::int32_t bufferId, std::string &error);
    void sealWorld();
    std::vector<RayTracingDraw> rayTracingDraws() const;
    RasterEncodeResult encodeQueuedDraws(id<MTLRenderCommandEncoder> encoder,
                                         NSUInteger targetWidth,
                                         NSUInteger targetHeight,
                                         RasterPartition partition = RasterPartition::All);
    void releaseEncodedTransientBuffers();
    void discardFrame();
    void close();

    void setResourceBinder(ResourceBinder binder);
    std::size_t queuedDrawCount() const;

    RasterPass(const RasterPass &) = delete;
    RasterPass &operator=(const RasterPass &) = delete;

private:
    struct Impl;

    RasterPass();
    ~RasterPass();

    std::unique_ptr<Impl> impl_;
};

} // namespace shadermetal
