#include "resource/SamplerCache.hpp"

#include <functional>
#include <new>

namespace shadermetal {
namespace {

bool metalFilter(int value, MTLSamplerMinMagFilter &filter) {
    switch (value) {
    case 0:
        filter = MTLSamplerMinMagFilterNearest;
        return true;
    case 1:
        filter = MTLSamplerMinMagFilterLinear;
        return true;
    default:
        return false;
    }
}

bool metalMipFilter(int value, MTLSamplerMipFilter &filter) {
    switch (value) {
    case 0:
        filter = MTLSamplerMipFilterNearest;
        return true;
    case 1:
        filter = MTLSamplerMipFilterLinear;
        return true;
    default:
        return false;
    }
}

bool metalAddressMode(int value, MTLSamplerAddressMode &mode) {
    switch (value) {
    case 0:
        mode = MTLSamplerAddressModeRepeat;
        return true;
    case 2:
        mode = MTLSamplerAddressModeClampToEdge;
        return true;
    default:
        return false;
    }
}

void hashCombine(std::size_t &seed, int value) {
    seed ^= std::hash<int>{}(value) + 0x9e3779b9U + (seed << 6U) + (seed >> 2U);
}

} // namespace

std::size_t SamplerKeyHash::operator()(const SamplerKey &key) const noexcept {
    std::size_t seed = 0;
    hashCombine(seed, key.samplingMode);
    hashCombine(seed, key.mipmapMode);
    hashCombine(seed, key.addressMode);
    return seed;
}

SamplerCache &SamplerCache::shared() {
    static SamplerCache cache;
    return cache;
}

bool SamplerCache::isValidKey(const SamplerKey &key) {
    MTLSamplerMinMagFilter filter;
    MTLSamplerMipFilter mipFilter;
    MTLSamplerAddressMode addressMode;
    return metalFilter(key.samplingMode, filter) &&
        metalMipFilter(key.mipmapMode, mipFilter) &&
        metalAddressMode(key.addressMode, addressMode);
}

id<MTLSamplerState> SamplerCache::sampler(id<MTLDevice> device,
                                          const SamplerKey &key,
                                          std::string &error) {
    if (device == nil) {
        error = "cannot create a sampler without a Metal device";
        return nil;
    }

    MTLSamplerMinMagFilter filter;
    MTLSamplerMipFilter mipFilter;
    MTLSamplerAddressMode addressMode;
    if (!metalFilter(key.samplingMode, filter) ||
        !metalMipFilter(key.mipmapMode, mipFilter) ||
        !metalAddressMode(key.addressMode, addressMode)) {
        error = "sampler key contains an unsupported Vulkan sampler value";
        return nil;
    }

    std::lock_guard lock(mutex_);
    if (device_ != device) {
        samplers_.clear();
        device_ = device;
    }

    const auto cached = samplers_.find(key);
    if (cached != samplers_.end()) {
        return cached->second;
    }

    MTLSamplerDescriptor *descriptor = [[MTLSamplerDescriptor alloc] init];
    descriptor.minFilter = filter;
    descriptor.magFilter = filter;
    descriptor.mipFilter = mipFilter;
    descriptor.sAddressMode = addressMode;
    descriptor.tAddressMode = addressMode;
    descriptor.rAddressMode = addressMode;
    descriptor.normalizedCoordinates = YES;
    descriptor.supportArgumentBuffers = YES;
    descriptor.label = [NSString stringWithFormat:@"ShaderMetal Sampler %d:%d:%d",
                        key.samplingMode, key.mipmapMode, key.addressMode];

    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:descriptor];
    if (sampler == nil) {
        error = "Metal failed to create the requested sampler state";
        return nil;
    }
    try {
        samplers_.emplace(key, sampler);
    } catch (const std::bad_alloc &) {
        error = "unable to retain the sampler in the cache";
        return nil;
    }
    return sampler;
}

std::size_t SamplerCache::size() const {
    std::lock_guard lock(mutex_);
    return samplers_.size();
}

void SamplerCache::clear() {
    std::lock_guard lock(mutex_);
    samplers_.clear();
    device_ = nil;
}

} // namespace shadermetal
