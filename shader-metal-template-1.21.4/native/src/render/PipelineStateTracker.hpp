#pragma once

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace shadermetal {

struct FloatBits final {
    std::uint32_t bits = 0;

    static FloatBits fromFloat(float value) noexcept {
        return FloatBits{std::bit_cast<std::uint32_t>(value)};
    }

    float toFloat() const noexcept {
        return std::bit_cast<float>(bits);
    }

    bool operator==(const FloatBits &) const = default;
};

struct RectState final {
    std::int32_t x = 0;
    std::int32_t y = 0;
    std::int32_t width = 0;
    std::int32_t height = 0;

    bool operator==(const RectState &) const = default;
};

struct StencilFaceState final {
    std::int32_t compareOperation = 7; // VK_COMPARE_OP_ALWAYS
    std::uint32_t reference = 0;
    std::uint32_t compareMask = 0xFFFFFFFFU;
    std::int32_t failOperation = 0; // VK_STENCIL_OP_KEEP
    std::int32_t depthFailOperation = 0;
    std::int32_t passOperation = 0;
    std::uint32_t writeMask = 0xFFFFFFFFU;

    bool operator==(const StencilFaceState &) const = default;
};

// This is a complete, value-semantic snapshot of the Java bridge state.
// Draw encoding may consume some fields dynamically even when they do not
// affect MTLRenderPipelineDescriptor compilation.
struct PipelineKey final {
    bool scissorEnabled = false;
    RectState scissor{};
    RectState viewport{};

    bool blendEnabled = false;
    std::array<FloatBits, 4> blendConstants{};
    bool colorLogicOperationEnabled = false;
    std::int32_t sourceColorBlendFactor = 1; // VK_BLEND_FACTOR_ONE
    std::int32_t sourceAlphaBlendFactor = 1;
    std::int32_t destinationColorBlendFactor = 0; // VK_BLEND_FACTOR_ZERO
    std::int32_t destinationAlphaBlendFactor = 0;
    std::int32_t colorBlendOperation = 0; // VK_BLEND_OP_ADD
    std::int32_t alphaBlendOperation = 0;
    std::uint32_t colorWriteMask = 0xFU;
    std::int32_t colorLogicOperation = 3; // VK_LOGIC_OP_COPY

    bool depthTestEnabled = false;
    bool depthWriteEnabled = true;
    bool stencilTestEnabled = false;
    std::int32_t depthCompareOperation = 1; // VK_COMPARE_OP_LESS
    StencilFaceState frontStencil{};
    StencilFaceState backStencil{};

    FloatBits lineWidth = FloatBits::fromFloat(1.0F);
    std::int32_t polygonMode = 0; // VK_POLYGON_MODE_FILL
    std::int32_t cullMode = 0; // VK_CULL_MODE_NONE
    std::int32_t frontFace = 0; // MTLWindingCounterClockwise
    std::array<bool, 3> depthBiasEnabledByPolygonMode{};
    FloatBits depthBiasSlopeFactor{};
    FloatBits depthBiasConstantFactor{};

    bool operator==(const PipelineKey &) const = default;
};

std::uint64_t stablePipelineKeyHash(const PipelineKey &key) noexcept;

struct PipelineKeyHash final {
    std::size_t operator()(const PipelineKey &key) const noexcept;
};

class PipelineStateTracker final {
public:
    static PipelineStateTracker &shared();

    PipelineKey snapshot() const;
    void reset();

    void setScissorEnabled(bool enabled);
    void setScissor(std::int32_t x, std::int32_t y, std::int32_t width,
                    std::int32_t height);
    void setViewport(std::int32_t x, std::int32_t y, std::int32_t width,
                     std::int32_t height);

    void setBlendEnabled(bool enabled);
    void setColorBlendConstants(float red, float green, float blue, float alpha);
    void setColorLogicOperationEnabled(bool enabled);
    void setBlendFunction(std::int32_t sourceColorFactor,
                          std::int32_t sourceAlphaFactor,
                          std::int32_t destinationColorFactor,
                          std::int32_t destinationAlphaFactor);
    void setBlendOperation(std::int32_t colorOperation,
                           std::int32_t alphaOperation);
    void setColorWriteMask(std::uint32_t mask);
    void setColorLogicOperation(std::int32_t operation);

    void setDepthTestEnabled(bool enabled);
    void setDepthWriteEnabled(bool enabled);
    void setStencilTestEnabled(bool enabled);
    void setDepthCompareOperation(std::int32_t operation);
    void setStencilFrontFunction(std::int32_t compareOperation,
                                 std::uint32_t reference,
                                 std::uint32_t compareMask);
    void setStencilBackFunction(std::int32_t compareOperation,
                                std::uint32_t reference,
                                std::uint32_t compareMask);
    void setStencilFrontOperation(std::int32_t failOperation,
                                  std::int32_t depthFailOperation,
                                  std::int32_t passOperation);
    void setStencilBackOperation(std::int32_t failOperation,
                                 std::int32_t depthFailOperation,
                                 std::int32_t passOperation);
    void setStencilFrontWriteMask(std::uint32_t mask);
    void setStencilBackWriteMask(std::uint32_t mask);

    void setLineWidth(float width);
    void setPolygonMode(std::int32_t mode);
    void setCullMode(std::int32_t mode);
    void setFrontFace(std::int32_t face);
    void setDepthBiasEnabled(std::int32_t polygonMode, bool enabled);
    void setDepthBias(float slopeFactor, float constantFactor);

    PipelineStateTracker(const PipelineStateTracker &) = delete;
    PipelineStateTracker &operator=(const PipelineStateTracker &) = delete;

private:
    PipelineStateTracker() = default;

    mutable std::mutex mutex_;
    PipelineKey state_{};
};

} // namespace shadermetal
