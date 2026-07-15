#include "render/PipelineStateTracker.hpp"

namespace shadermetal {
namespace {

constexpr std::uint64_t kFnvOffsetBasis = 14695981039346656037ULL;
constexpr std::uint64_t kFnvPrime = 1099511628211ULL;

void appendByte(std::uint64_t &hash, std::uint8_t value) noexcept {
    hash ^= value;
    hash *= kFnvPrime;
}

void appendBool(std::uint64_t &hash, bool value) noexcept {
    appendByte(hash, value ? 1U : 0U);
}

void appendWord(std::uint64_t &hash, std::uint32_t value) noexcept {
    for (unsigned int shift = 0; shift < 32; shift += 8) {
        appendByte(hash, static_cast<std::uint8_t>((value >> shift) & 0xFFU));
    }
}

void appendSignedWord(std::uint64_t &hash, std::int32_t value) noexcept {
    appendWord(hash, std::bit_cast<std::uint32_t>(value));
}

void appendRect(std::uint64_t &hash, const RectState &rect) noexcept {
    appendSignedWord(hash, rect.x);
    appendSignedWord(hash, rect.y);
    appendSignedWord(hash, rect.width);
    appendSignedWord(hash, rect.height);
}

void appendStencilFace(std::uint64_t &hash, const StencilFaceState &state) noexcept {
    appendSignedWord(hash, state.compareOperation);
    appendWord(hash, state.reference);
    appendWord(hash, state.compareMask);
    appendSignedWord(hash, state.failOperation);
    appendSignedWord(hash, state.depthFailOperation);
    appendSignedWord(hash, state.passOperation);
    appendWord(hash, state.writeMask);
}

} // namespace

std::uint64_t stablePipelineKeyHash(const PipelineKey &key) noexcept {
    std::uint64_t hash = kFnvOffsetBasis;

    appendBool(hash, key.scissorEnabled);
    appendRect(hash, key.scissor);
    appendRect(hash, key.viewport);

    appendBool(hash, key.blendEnabled);
    for (const FloatBits value : key.blendConstants) {
        appendWord(hash, value.bits);
    }
    appendBool(hash, key.colorLogicOperationEnabled);
    appendSignedWord(hash, key.sourceColorBlendFactor);
    appendSignedWord(hash, key.sourceAlphaBlendFactor);
    appendSignedWord(hash, key.destinationColorBlendFactor);
    appendSignedWord(hash, key.destinationAlphaBlendFactor);
    appendSignedWord(hash, key.colorBlendOperation);
    appendSignedWord(hash, key.alphaBlendOperation);
    appendWord(hash, key.colorWriteMask);
    appendSignedWord(hash, key.colorLogicOperation);

    appendBool(hash, key.depthTestEnabled);
    appendBool(hash, key.depthWriteEnabled);
    appendBool(hash, key.stencilTestEnabled);
    appendSignedWord(hash, key.depthCompareOperation);
    appendStencilFace(hash, key.frontStencil);
    appendStencilFace(hash, key.backStencil);

    appendWord(hash, key.lineWidth.bits);
    appendSignedWord(hash, key.polygonMode);
    appendSignedWord(hash, key.cullMode);
    appendSignedWord(hash, key.frontFace);
    for (const bool enabled : key.depthBiasEnabledByPolygonMode) {
        appendBool(hash, enabled);
    }
    appendWord(hash, key.depthBiasSlopeFactor.bits);
    appendWord(hash, key.depthBiasConstantFactor.bits);

    return hash;
}

std::size_t PipelineKeyHash::operator()(const PipelineKey &key) const noexcept {
    return static_cast<std::size_t>(stablePipelineKeyHash(key));
}

PipelineStateTracker &PipelineStateTracker::shared() {
    static PipelineStateTracker tracker;
    return tracker;
}

PipelineKey PipelineStateTracker::snapshot() const {
    std::lock_guard lock(mutex_);
    return state_;
}

void PipelineStateTracker::reset() {
    std::lock_guard lock(mutex_);
    state_ = PipelineKey{};
}

void PipelineStateTracker::setScissorEnabled(bool enabled) {
    std::lock_guard lock(mutex_);
    state_.scissorEnabled = enabled;
}

void PipelineStateTracker::setScissor(std::int32_t x, std::int32_t y,
                                      std::int32_t width, std::int32_t height) {
    std::lock_guard lock(mutex_);
    state_.scissor = RectState{x, y, width, height};
}

void PipelineStateTracker::setViewport(std::int32_t x, std::int32_t y,
                                       std::int32_t width, std::int32_t height) {
    std::lock_guard lock(mutex_);
    state_.viewport = RectState{x, y, width, height};
}

void PipelineStateTracker::setBlendEnabled(bool enabled) {
    std::lock_guard lock(mutex_);
    state_.blendEnabled = enabled;
}

void PipelineStateTracker::setColorBlendConstants(float red, float green, float blue,
                                                   float alpha) {
    std::lock_guard lock(mutex_);
    state_.blendConstants = {
        FloatBits::fromFloat(red), FloatBits::fromFloat(green),
        FloatBits::fromFloat(blue), FloatBits::fromFloat(alpha)};
}

void PipelineStateTracker::setColorLogicOperationEnabled(bool enabled) {
    std::lock_guard lock(mutex_);
    state_.colorLogicOperationEnabled = enabled;
}

void PipelineStateTracker::setBlendFunction(std::int32_t sourceColorFactor,
                                            std::int32_t sourceAlphaFactor,
                                            std::int32_t destinationColorFactor,
                                            std::int32_t destinationAlphaFactor) {
    std::lock_guard lock(mutex_);
    state_.sourceColorBlendFactor = sourceColorFactor;
    state_.sourceAlphaBlendFactor = sourceAlphaFactor;
    state_.destinationColorBlendFactor = destinationColorFactor;
    state_.destinationAlphaBlendFactor = destinationAlphaFactor;
}

void PipelineStateTracker::setBlendOperation(std::int32_t colorOperation,
                                             std::int32_t alphaOperation) {
    std::lock_guard lock(mutex_);
    state_.colorBlendOperation = colorOperation;
    state_.alphaBlendOperation = alphaOperation;
}

void PipelineStateTracker::setColorWriteMask(std::uint32_t mask) {
    std::lock_guard lock(mutex_);
    state_.colorWriteMask = mask;
}

void PipelineStateTracker::setColorLogicOperation(std::int32_t operation) {
    std::lock_guard lock(mutex_);
    state_.colorLogicOperation = operation;
}

void PipelineStateTracker::setDepthTestEnabled(bool enabled) {
    std::lock_guard lock(mutex_);
    state_.depthTestEnabled = enabled;
}

void PipelineStateTracker::setDepthWriteEnabled(bool enabled) {
    std::lock_guard lock(mutex_);
    state_.depthWriteEnabled = enabled;
}

void PipelineStateTracker::setStencilTestEnabled(bool enabled) {
    std::lock_guard lock(mutex_);
    state_.stencilTestEnabled = enabled;
}

void PipelineStateTracker::setDepthCompareOperation(std::int32_t operation) {
    std::lock_guard lock(mutex_);
    state_.depthCompareOperation = operation;
}

void PipelineStateTracker::setStencilFrontFunction(std::int32_t compareOperation,
                                                   std::uint32_t reference,
                                                   std::uint32_t compareMask) {
    std::lock_guard lock(mutex_);
    state_.frontStencil.compareOperation = compareOperation;
    state_.frontStencil.reference = reference;
    state_.frontStencil.compareMask = compareMask;
}

void PipelineStateTracker::setStencilBackFunction(std::int32_t compareOperation,
                                                  std::uint32_t reference,
                                                  std::uint32_t compareMask) {
    std::lock_guard lock(mutex_);
    state_.backStencil.compareOperation = compareOperation;
    state_.backStencil.reference = reference;
    state_.backStencil.compareMask = compareMask;
}

void PipelineStateTracker::setStencilFrontOperation(std::int32_t failOperation,
                                                    std::int32_t depthFailOperation,
                                                    std::int32_t passOperation) {
    std::lock_guard lock(mutex_);
    state_.frontStencil.failOperation = failOperation;
    state_.frontStencil.depthFailOperation = depthFailOperation;
    state_.frontStencil.passOperation = passOperation;
}

void PipelineStateTracker::setStencilBackOperation(std::int32_t failOperation,
                                                   std::int32_t depthFailOperation,
                                                   std::int32_t passOperation) {
    std::lock_guard lock(mutex_);
    state_.backStencil.failOperation = failOperation;
    state_.backStencil.depthFailOperation = depthFailOperation;
    state_.backStencil.passOperation = passOperation;
}

void PipelineStateTracker::setStencilFrontWriteMask(std::uint32_t mask) {
    std::lock_guard lock(mutex_);
    state_.frontStencil.writeMask = mask;
}

void PipelineStateTracker::setStencilBackWriteMask(std::uint32_t mask) {
    std::lock_guard lock(mutex_);
    state_.backStencil.writeMask = mask;
}

void PipelineStateTracker::setLineWidth(float width) {
    std::lock_guard lock(mutex_);
    state_.lineWidth = FloatBits::fromFloat(width);
}

void PipelineStateTracker::setPolygonMode(std::int32_t mode) {
    std::lock_guard lock(mutex_);
    state_.polygonMode = mode;
}

void PipelineStateTracker::setCullMode(std::int32_t mode) {
    std::lock_guard lock(mutex_);
    state_.cullMode = mode;
}

void PipelineStateTracker::setFrontFace(std::int32_t face) {
    std::lock_guard lock(mutex_);
    state_.frontFace = face;
}

void PipelineStateTracker::setDepthBiasEnabled(std::int32_t polygonMode, bool enabled) {
    const auto index = static_cast<std::size_t>(polygonMode);
    std::lock_guard lock(mutex_);
    if (index < state_.depthBiasEnabledByPolygonMode.size()) {
        state_.depthBiasEnabledByPolygonMode[index] = enabled;
    }
}

void PipelineStateTracker::setDepthBias(float slopeFactor, float constantFactor) {
    std::lock_guard lock(mutex_);
    state_.depthBiasSlopeFactor = FloatBits::fromFloat(slopeFactor);
    state_.depthBiasConstantFactor = FloatBits::fromFloat(constantFactor);
}

} // namespace shadermetal
