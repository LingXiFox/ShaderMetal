#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace shadermetal {

enum class UniformSlot : std::uint8_t {
    World = 0,
    Sky = 1,
    OverlayPost = 2,
    TextureMapping = 3,
};

struct UniformSnapshot {
    std::vector<std::byte> bytes;
    std::uint64_t version = 0;
};

class UniformStorage final {
public:
    static UniformStorage &shared();

    bool copy(UniformSlot slot, const void *source, std::size_t explicitSize,
              std::string &error);
    std::optional<UniformSnapshot> snapshot(UniformSlot slot) const;
    std::size_t size(UniformSlot slot) const;
    void reset(UniformSlot slot);
    void clear();

    UniformStorage(const UniformStorage &) = delete;
    UniformStorage &operator=(const UniformStorage &) = delete;

private:
    struct Block {
        std::vector<std::byte> bytes;
        std::size_t fixedSize = 0;
        std::uint64_t version = 0;
    };

    static std::optional<std::size_t> indexFor(UniformSlot slot);

    UniformStorage() = default;
    ~UniformStorage() = default;

    mutable std::mutex mutex_;
    std::array<Block, 4> blocks_;
};

} // namespace shadermetal
