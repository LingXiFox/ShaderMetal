#include "render/PipelineCache.hpp"

#include <condition_variable>
#include <exception>
#include <mutex>
#include <stdexcept>
#include <unordered_map>
#include <utility>

namespace shadermetal {
namespace {

constexpr std::uint64_t kFnvOffsetBasis = 14695981039346656037ULL;
constexpr std::uint64_t kFnvPrime = 1099511628211ULL;

void appendByte(std::uint64_t &hash, std::uint8_t value) noexcept {
    hash ^= value;
    hash *= kFnvPrime;
}

void appendWord(std::uint64_t &hash, std::uint32_t value) noexcept {
    for (unsigned int shift = 0; shift < 32; shift += 8) {
        appendByte(hash, static_cast<std::uint8_t>((value >> shift) & 0xFFU));
    }
}

void appendDoubleWord(std::uint64_t &hash, std::uint64_t value) noexcept {
    for (unsigned int shift = 0; shift < 64; shift += 8) {
        appendByte(hash, static_cast<std::uint8_t>((value >> shift) & 0xFFU));
    }
}

} // namespace

std::uint64_t stablePipelineCacheKeyHash(const PipelineCacheKey &key) noexcept {
    std::uint64_t hash = kFnvOffsetBasis;
    appendWord(hash, std::bit_cast<std::uint32_t>(key.shaderId));
    appendDoubleWord(hash, stablePipelineKeyHash(key.state));
    return hash;
}

std::size_t PipelineCacheKeyHash::operator()(const PipelineCacheKey &key) const noexcept {
    return static_cast<std::size_t>(stablePipelineCacheKeyHash(key));
}

struct PipelineCache::Impl final {
    struct Entry final {
        std::condition_variable ready;
        bool building = true;
        id<MTLRenderPipelineState> pipelineState = nil;
        std::string error;
    };

    explicit Impl(Factory pipelineFactory) : factory(std::move(pipelineFactory)) {
        if (!factory) {
            throw std::invalid_argument("PipelineCache requires a pipeline factory");
        }
    }

    Factory factory;
    mutable std::mutex mutex;
    std::mutex factoryMutex;
    std::unordered_map<PipelineCacheKey, std::shared_ptr<Entry>, PipelineCacheKeyHash>
        entries;
};

PipelineCache::PipelineCache(Factory factory)
    : impl_(std::make_unique<Impl>(std::move(factory))) {}

PipelineCache::~PipelineCache() = default;

id<MTLRenderPipelineState> PipelineCache::getOrCreate(std::int32_t shaderId,
                                                       const PipelineKey &state,
                                                       std::string &error) {
    error.clear();
    const PipelineCacheKey key{shaderId, state};
    std::shared_ptr<Impl::Entry> entry;

    {
        std::unique_lock lock(impl_->mutex);
        const auto existing = impl_->entries.find(key);
        if (existing != impl_->entries.end()) {
            entry = existing->second;
            entry->ready.wait(lock, [&entry] { return !entry->building; });
            error = entry->error;
            return entry->pipelineState;
        }
        entry = std::make_shared<Impl::Entry>();
        impl_->entries.emplace(key, entry);
    }

    id<MTLRenderPipelineState> pipelineState = nil;
    std::string factoryError;
    try {
        // Serialize the injected callback so cache callers do not impose a
        // thread-safety requirement on the future shader registry.
        std::lock_guard factoryLock(impl_->factoryMutex);
        pipelineState = impl_->factory(shaderId, state, factoryError);
    } catch (const std::exception &exception) {
        factoryError = exception.what();
    } catch (...) {
        factoryError = "pipeline factory threw an unknown exception";
    }

    if (pipelineState == nil && factoryError.empty()) {
        factoryError = "pipeline factory returned nil without an error";
    }

    {
        std::lock_guard lock(impl_->mutex);
        entry->pipelineState = pipelineState;
        entry->error = factoryError;
        entry->building = false;
    }
    entry->ready.notify_all();

    error = factoryError;
    return pipelineState;
}

std::size_t PipelineCache::size() const {
    std::lock_guard lock(impl_->mutex);
    return impl_->entries.size();
}

void PipelineCache::clear() {
    std::lock_guard lock(impl_->mutex);
    impl_->entries.clear();
}

} // namespace shadermetal
