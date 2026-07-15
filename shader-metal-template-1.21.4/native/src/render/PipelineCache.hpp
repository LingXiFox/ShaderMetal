#pragma once

#import <Metal/Metal.h>

#include "render/PipelineStateTracker.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace shadermetal {

struct PipelineCacheKey final {
    std::int32_t shaderId = 0;
    PipelineKey state{};

    bool operator==(const PipelineCacheKey &) const = default;
};

std::uint64_t stablePipelineCacheKeyHash(const PipelineCacheKey &key) noexcept;

struct PipelineCacheKeyHash final {
    std::size_t operator()(const PipelineCacheKey &key) const noexcept;
};

class PipelineCache final {
public:
    // The callback must build from the real shader library and vertex descriptor.
    // The cache serializes callback calls, and nil failures must include an error.
    using Factory = std::function<id<MTLRenderPipelineState>(
        std::int32_t shaderId, const PipelineKey &state, std::string &error)>;

    explicit PipelineCache(Factory factory);
    ~PipelineCache();

    id<MTLRenderPipelineState> getOrCreate(std::int32_t shaderId,
                                           const PipelineKey &state,
                                           std::string &error);
    std::size_t size() const;
    void clear();

    PipelineCache(const PipelineCache &) = delete;
    PipelineCache &operator=(const PipelineCache &) = delete;
    PipelineCache(PipelineCache &&) = delete;
    PipelineCache &operator=(PipelineCache &&) = delete;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace shadermetal
