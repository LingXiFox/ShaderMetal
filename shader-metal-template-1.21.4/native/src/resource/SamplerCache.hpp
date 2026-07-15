#pragma once

#import <Metal/Metal.h>

#include <cstddef>
#include <mutex>
#include <string>
#include <unordered_map>

namespace shadermetal {

struct SamplerKey {
    int samplingMode = 0;
    int mipmapMode = 0;
    int addressMode = 0;

    bool operator==(const SamplerKey &) const = default;
};

struct SamplerKeyHash {
    std::size_t operator()(const SamplerKey &key) const noexcept;
};

class SamplerCache final {
public:
    static SamplerCache &shared();

    static bool isValidKey(const SamplerKey &key);
    id<MTLSamplerState> sampler(id<MTLDevice> device, const SamplerKey &key,
                                std::string &error);
    std::size_t size() const;
    void clear();

    SamplerCache(const SamplerCache &) = delete;
    SamplerCache &operator=(const SamplerCache &) = delete;

private:
    SamplerCache() = default;
    ~SamplerCache() = default;

    mutable std::mutex mutex_;
    id<MTLDevice> device_ = nil;
    std::unordered_map<SamplerKey, id<MTLSamplerState>, SamplerKeyHash> samplers_;
};

} // namespace shadermetal
