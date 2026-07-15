#pragma once

#import <Metal/Metal.h>

#include "resource/SamplerCache.hpp"

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace shadermetal {

struct TextureFormatMapping {
    MTLPixelFormat metalFormat = MTLPixelFormatInvalid;
    std::size_t sourceComponentCount = 0;
    std::size_t metalComponentCount = 0;
    std::size_t bytesPerComponent = 0;

    std::size_t sourceBytesPerPixel() const;
    std::size_t metalBytesPerPixel() const;
    bool requiresExpansion() const;
};

std::optional<TextureFormatMapping> textureFormatForVk(int vkFormat);

class TextureManager final {
public:
    using TextureId = std::int32_t;
    static constexpr TextureId kInvalidTextureId = -1;

    struct TextureMetadata {
        std::size_t width = 0;
        std::size_t height = 0;
        std::size_t mipLevels = 0;
        int vkFormat = 0;
        TextureFormatMapping format;
        SamplerKey sampler;
    };

    struct UploadBatchResult {
        std::size_t uploaded = 0;
        std::size_t discarded = 0;
    };

    struct TextureBinding {
        TextureId textureId = kInvalidTextureId;
        id<MTLTexture> texture = nil;
        SamplerKey sampler;
    };

    struct BindingSnapshot {
        std::uint64_t revision = 0;
        std::vector<TextureBinding> bindings;
    };

    static TextureManager &shared();

    TextureId allocate();
    bool prepare(TextureId textureId, std::size_t mipLevels, std::size_t width,
                 std::size_t height, int vkFormat, id<MTLDevice> device,
                 std::string &error);
    bool setFilter(TextureId id, int samplingMode, int mipmapMode,
                   std::string &error);
    bool setAddressMode(TextureId id, int addressMode, std::string &error);
    bool queueUpload(const void *source, std::size_t sourceSizeInBytes,
                     std::size_t sourceRowPixels, TextureId destinationId,
                     std::size_t sourceOffsetX, std::size_t sourceOffsetY,
                     std::size_t destinationOffsetX, std::size_t destinationOffsetY,
                     std::size_t width, std::size_t height, std::size_t level,
                     std::string &error);
    UploadBatchResult performQueuedUploads();

    id<MTLTexture> texture(TextureId id) const;
    std::optional<TextureMetadata> metadata(TextureId id) const;
    BindingSnapshot bindingSnapshot() const;
    bool erase(TextureId id);
    void clear();

    TextureManager(const TextureManager &) = delete;
    TextureManager &operator=(const TextureManager &) = delete;

private:
    struct TextureEntry {
        id<MTLTexture> texture = nil;
        TextureMetadata metadata;
        std::uint64_t generation = 0;
    };

    struct PendingUpload {
        TextureId destinationId = kInvalidTextureId;
        std::uint64_t generation = 0;
        std::size_t destinationOffsetX = 0;
        std::size_t destinationOffsetY = 0;
        std::size_t width = 0;
        std::size_t height = 0;
        std::size_t level = 0;
        std::size_t bytesPerRow = 0;
        std::vector<std::byte> bytes;
    };

    TextureManager() = default;
    ~TextureManager() = default;

    mutable std::mutex mutex_;
    std::int64_t nextId_ = 1;
    std::uint64_t bindingRevision_ = 1;
    std::unordered_map<TextureId, TextureEntry> textures_;
    std::vector<PendingUpload> pendingUploads_;
};

} // namespace shadermetal
