#include "resource/UniformStorage.hpp"

#include <cstring>
#include <limits>
#include <new>

namespace shadermetal {

UniformStorage &UniformStorage::shared() {
    static UniformStorage storage;
    return storage;
}

std::optional<std::size_t> UniformStorage::indexFor(UniformSlot slot) {
    switch (slot) {
    case UniformSlot::World:
        return 0;
    case UniformSlot::Sky:
        return 1;
    case UniformSlot::OverlayPost:
        return 2;
    case UniformSlot::TextureMapping:
        return 3;
    }
    return std::nullopt;
}

bool UniformStorage::copy(UniformSlot slot, const void *source,
                          std::size_t explicitSize, std::string &error) {
    const std::optional<std::size_t> index = indexFor(slot);
    if (!index.has_value()) {
        error = "uniform slot is invalid";
        return false;
    }
    if (source == nullptr) {
        error = "uniform source is null";
        return false;
    }
    if (explicitSize == 0) {
        error = "uniform size must be provided explicitly and be greater than zero";
        return false;
    }

    std::lock_guard lock(mutex_);
    Block &block = blocks_[*index];
    if (block.fixedSize != 0 && block.fixedSize != explicitSize) {
        error = "uniform size differs from the fixed size established for this slot";
        return false;
    }

    try {
        if (block.fixedSize == 0) {
            block.bytes.resize(explicitSize);
            block.fixedSize = explicitSize;
        }
    } catch (const std::bad_alloc &) {
        error = "unable to allocate uniform storage";
        return false;
    }

    std::memcpy(block.bytes.data(), source, explicitSize);
    block.version = block.version == std::numeric_limits<std::uint64_t>::max()
        ? 1
        : block.version + 1;
    return true;
}

std::optional<UniformSnapshot> UniformStorage::snapshot(UniformSlot slot) const {
    const std::optional<std::size_t> index = indexFor(slot);
    if (!index.has_value()) {
        return std::nullopt;
    }

    std::lock_guard lock(mutex_);
    const Block &block = blocks_[*index];
    if (block.fixedSize == 0) {
        return std::nullopt;
    }

    try {
        return UniformSnapshot{block.bytes, block.version};
    } catch (const std::bad_alloc &) {
        return std::nullopt;
    }
}

std::size_t UniformStorage::size(UniformSlot slot) const {
    const std::optional<std::size_t> index = indexFor(slot);
    if (!index.has_value()) {
        return 0;
    }

    std::lock_guard lock(mutex_);
    return blocks_[*index].fixedSize;
}

void UniformStorage::reset(UniformSlot slot) {
    const std::optional<std::size_t> index = indexFor(slot);
    if (!index.has_value()) {
        return;
    }

    std::lock_guard lock(mutex_);
    blocks_[*index] = {};
}

void UniformStorage::clear() {
    std::lock_guard lock(mutex_);
    for (Block &block : blocks_) {
        block = {};
    }
}

} // namespace shadermetal
