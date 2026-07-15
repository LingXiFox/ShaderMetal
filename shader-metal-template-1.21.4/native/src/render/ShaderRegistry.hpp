#pragma once

#import <Metal/Metal.h>

#include "render/PipelineStateTracker.hpp"

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>

namespace shadermetal {

struct ShaderRecord final {
    std::int32_t shaderId = -1;
    std::string key;
    std::int32_t vertexFormatType = -1;
    std::int32_t drawMode = -1;
    std::size_t vertexStride = 0;
    std::size_t uniformSize = 0;
    bool vertexUsesArgumentBuffer = false;
    bool fragmentUsesArgumentBuffer = false;
    bool usesArgumentBuffers = false;
    id<MTLLibrary> vertexLibrary = nil;
    id<MTLLibrary> fragmentLibrary = nil;
    id<MTLFunction> vertexFunction = nil;
    id<MTLFunction> fragmentFunction = nil;
    MTLVertexDescriptor *vertexDescriptor = nil;
};

class ShaderRegistry final {
public:
    using ShaderId = std::int32_t;
    static constexpr ShaderId kInvalidShaderId = -1;

    static ShaderRegistry &shared();

    ShaderId registerShader(std::string_view key, std::int32_t vertexFormatType,
                            std::int32_t drawMode, std::int32_t uniformSize,
                            std::string_view vertexSource,
                            std::string_view fragmentSource,
                            id<MTLDevice> device, std::string &error);
    std::optional<ShaderRecord> shader(ShaderId id) const;

    id<MTLRenderPipelineState> createRenderPipelineState(
        ShaderId shaderId, const PipelineKey &state, id<MTLDevice> device,
        std::string &error) const;

    void clear();

    ShaderRegistry(const ShaderRegistry &) = delete;
    ShaderRegistry &operator=(const ShaderRegistry &) = delete;

private:
    ShaderRegistry() = default;
    ~ShaderRegistry() = default;

    mutable std::mutex mutex_;
    std::int64_t nextId_ = 1;
    std::unordered_map<ShaderId, ShaderRecord> shaders_;
};

} // namespace shadermetal
