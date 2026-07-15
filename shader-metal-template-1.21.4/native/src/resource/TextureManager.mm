#include "resource/TextureManager.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <new>

namespace shadermetal {
namespace {

constexpr int kVkFormatR8Unorm = 9;
constexpr int kVkFormatR8Srgb = 15;
constexpr int kVkFormatR8G8Unorm = 16;
constexpr int kVkFormatR8G8Srgb = 22;
constexpr int kVkFormatR8G8B8Unorm = 23;
constexpr int kVkFormatR8G8B8Srgb = 29;
constexpr int kVkFormatR8G8B8A8Unorm = 37;
constexpr int kVkFormatR8G8B8A8Srgb = 43;
constexpr int kVkFormatR16Float = 76;
constexpr int kVkFormatR16G16Float = 83;
constexpr int kVkFormatR16G16B16Float = 90;
constexpr int kVkFormatR16G16B16A16Float = 97;

void advanceRevision(std::uint64_t &revision) {
    revision = revision == std::numeric_limits<std::uint64_t>::max()
        ? 1
        : revision + 1;
}

bool checkedAdd(std::size_t left, std::size_t right, std::size_t &result) {
    if (left > std::numeric_limits<std::size_t>::max() - right) {
        return false;
    }
    result = left + right;
    return true;
}

bool checkedMultiply(std::size_t left, std::size_t right, std::size_t &result) {
    if (left != 0 && right > std::numeric_limits<std::size_t>::max() / left) {
        return false;
    }
    result = left * right;
    return true;
}

std::size_t maximumMipLevels(std::size_t width, std::size_t height) {
    std::size_t levels = 1;
    while (width > 1 || height > 1) {
        width = std::max<std::size_t>(1, width / 2);
        height = std::max<std::size_t>(1, height / 2);
        ++levels;
    }
    return levels;
}

std::size_t mipDimension(std::size_t base, std::size_t level) {
    for (std::size_t index = 0; index < level && base > 1; ++index) {
        base /= 2;
    }
    return std::max<std::size_t>(1, base);
}

void writeOne(std::byte *destination, std::size_t bytesPerComponent) {
    if (bytesPerComponent == 1) {
        destination[0] = std::byte{0xff};
        return;
    }

    const std::uint16_t halfFloatOne = 0x3c00;
    std::memcpy(destination, &halfFloatOne, sizeof(halfFloatOne));
}

} // namespace

std::size_t TextureFormatMapping::sourceBytesPerPixel() const {
    return sourceComponentCount * bytesPerComponent;
}

std::size_t TextureFormatMapping::metalBytesPerPixel() const {
    return metalComponentCount * bytesPerComponent;
}

bool TextureFormatMapping::requiresExpansion() const {
    return sourceComponentCount != metalComponentCount;
}

std::optional<TextureFormatMapping> textureFormatForVk(int vkFormat) {
    switch (vkFormat) {
    case kVkFormatR8Unorm:
        return TextureFormatMapping{MTLPixelFormatR8Unorm, 1, 1, 1};
    case kVkFormatR8Srgb:
        return TextureFormatMapping{MTLPixelFormatR8Unorm_sRGB, 1, 1, 1};
    case kVkFormatR8G8Unorm:
        return TextureFormatMapping{MTLPixelFormatRG8Unorm, 2, 2, 1};
    case kVkFormatR8G8Srgb:
        return TextureFormatMapping{MTLPixelFormatRG8Unorm_sRGB, 2, 2, 1};
    case kVkFormatR8G8B8Unorm:
        return TextureFormatMapping{MTLPixelFormatRGBA8Unorm, 3, 4, 1};
    case kVkFormatR8G8B8Srgb:
        return TextureFormatMapping{MTLPixelFormatRGBA8Unorm_sRGB, 3, 4, 1};
    case kVkFormatR8G8B8A8Unorm:
        return TextureFormatMapping{MTLPixelFormatRGBA8Unorm, 4, 4, 1};
    case kVkFormatR8G8B8A8Srgb:
        return TextureFormatMapping{MTLPixelFormatRGBA8Unorm_sRGB, 4, 4, 1};
    case kVkFormatR16Float:
        return TextureFormatMapping{MTLPixelFormatR16Float, 1, 1, 2};
    case kVkFormatR16G16Float:
        return TextureFormatMapping{MTLPixelFormatRG16Float, 2, 2, 2};
    case kVkFormatR16G16B16Float:
        return TextureFormatMapping{MTLPixelFormatRGBA16Float, 3, 4, 2};
    case kVkFormatR16G16B16A16Float:
        return TextureFormatMapping{MTLPixelFormatRGBA16Float, 4, 4, 2};
    default:
        return std::nullopt;
    }
}

TextureManager &TextureManager::shared() {
    static TextureManager manager;
    return manager;
}

TextureManager::TextureId TextureManager::allocate() {
    std::lock_guard lock(mutex_);
    if (nextId_ > std::numeric_limits<TextureId>::max()) {
        return kInvalidTextureId;
    }

    const TextureId id = static_cast<TextureId>(nextId_);
    try {
        textures_.try_emplace(id);
    } catch (const std::bad_alloc &) {
        return kInvalidTextureId;
    }
    ++nextId_;
    return id;
}

bool TextureManager::prepare(TextureId textureId, std::size_t mipLevels,
                             std::size_t width, std::size_t height, int vkFormat,
                             id<MTLDevice> device, std::string &error) {
    if (device == nil) {
        error = "cannot prepare a texture without a Metal device";
        return false;
    }
    if (width == 0 || height == 0 || mipLevels == 0) {
        error = "texture dimensions and mip level count must be greater than zero";
        return false;
    }
    if (width > std::numeric_limits<NSUInteger>::max() ||
        height > std::numeric_limits<NSUInteger>::max() ||
        mipLevels > std::numeric_limits<NSUInteger>::max()) {
        error = "texture dimensions exceed Metal's NSUInteger range";
        return false;
    }
    if (mipLevels > maximumMipLevels(width, height)) {
        error = "texture mip level count exceeds the dimensions' complete mip chain";
        return false;
    }

    const std::optional<TextureFormatMapping> format = textureFormatForVk(vkFormat);
    if (!format.has_value()) {
        error = "texture uses an unsupported VK_FORMAT value";
        return false;
    }

    {
        std::lock_guard lock(mutex_);
        if (!textures_.contains(textureId)) {
            error = "texture ID was not allocated";
            return false;
        }
    }

    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format->metalFormat
                                                          width:static_cast<NSUInteger>(width)
                                                         height:static_cast<NSUInteger>(height)
                                                      mipmapped:mipLevels > 1];
    descriptor.mipmapLevelCount = static_cast<NSUInteger>(mipLevels);
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = static_cast<MTLTextureUsage>(MTLTextureUsageShaderRead |
                                                     MTLTextureUsageShaderWrite |
                                                     MTLTextureUsageRenderTarget);
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture == nil) {
        error = "Metal failed to allocate the requested texture";
        return false;
    }
    texture.label = [NSString stringWithFormat:@"ShaderMetal Texture %d", textureId];

    std::lock_guard lock(mutex_);
    auto iterator = textures_.find(textureId);
    if (iterator == textures_.end()) {
        error = "texture ID was erased while it was being prepared";
        return false;
    }

    TextureEntry &entry = iterator->second;
    const SamplerKey sampler = entry.metadata.sampler;
    entry.texture = texture;
    entry.metadata = TextureMetadata{width, height, mipLevels, vkFormat, *format, sampler};
    entry.generation = entry.generation == std::numeric_limits<std::uint64_t>::max()
        ? 1
        : entry.generation + 1;
    advanceRevision(bindingRevision_);
    std::erase_if(pendingUploads_, [textureId](const PendingUpload &upload) {
        return upload.destinationId == textureId;
    });
    return true;
}

bool TextureManager::setFilter(TextureId id, int samplingMode, int mipmapMode,
                               std::string &error) {
    std::lock_guard lock(mutex_);
    const auto iterator = textures_.find(id);
    if (iterator == textures_.end()) {
        error = "cannot set filtering on an unknown texture ID";
        return false;
    }

    SamplerKey key = iterator->second.metadata.sampler;
    key.samplingMode = samplingMode;
    key.mipmapMode = mipmapMode;
    if (!SamplerCache::isValidKey(key)) {
        error = "texture filtering contains an unsupported Vulkan sampler value";
        return false;
    }
    if (iterator->second.metadata.sampler != key) {
        iterator->second.metadata.sampler = key;
        advanceRevision(bindingRevision_);
    }
    return true;
}

bool TextureManager::setAddressMode(TextureId id, int addressMode,
                                    std::string &error) {
    std::lock_guard lock(mutex_);
    const auto iterator = textures_.find(id);
    if (iterator == textures_.end()) {
        error = "cannot set addressing on an unknown texture ID";
        return false;
    }

    SamplerKey key = iterator->second.metadata.sampler;
    key.addressMode = addressMode;
    if (!SamplerCache::isValidKey(key)) {
        error = "texture addressing contains an unsupported Vulkan sampler value";
        return false;
    }
    if (iterator->second.metadata.sampler != key) {
        iterator->second.metadata.sampler = key;
        advanceRevision(bindingRevision_);
    }
    return true;
}

bool TextureManager::queueUpload(
    const void *source, std::size_t sourceSizeInBytes,
    std::size_t sourceRowPixels, TextureId destinationId,
    std::size_t sourceOffsetX, std::size_t sourceOffsetY,
    std::size_t destinationOffsetX, std::size_t destinationOffsetY,
    std::size_t width, std::size_t height, std::size_t level,
    std::string &error) {
    if (source == nullptr) {
        error = "texture upload source is null";
        return false;
    }
    if (width == 0 || height == 0 || sourceRowPixels == 0) {
        error = "texture upload dimensions and source row width must be greater than zero";
        return false;
    }

    TextureMetadata metadata;
    std::uint64_t generation = 0;
    {
        std::lock_guard lock(mutex_);
        const auto iterator = textures_.find(destinationId);
        if (iterator == textures_.end() || iterator->second.texture == nil) {
            error = "texture upload destination is not initialized";
            return false;
        }
        metadata = iterator->second.metadata;
        generation = iterator->second.generation;
    }

    if (level >= metadata.mipLevels) {
        error = "texture upload mip level is out of range";
        return false;
    }

    const std::size_t mipWidth = mipDimension(metadata.width, level);
    const std::size_t mipHeight = mipDimension(metadata.height, level);
    std::size_t destinationEndX = 0;
    std::size_t destinationEndY = 0;
    if (!checkedAdd(destinationOffsetX, width, destinationEndX) ||
        !checkedAdd(destinationOffsetY, height, destinationEndY) ||
        destinationEndX > mipWidth || destinationEndY > mipHeight) {
        error = "texture upload destination region is out of bounds";
        return false;
    }

    std::size_t sourceEndX = 0;
    std::size_t sourceLastY = 0;
    if (!checkedAdd(sourceOffsetX, width, sourceEndX) ||
        sourceEndX > sourceRowPixels ||
        !checkedAdd(sourceOffsetY, height - 1, sourceLastY)) {
        error = "texture upload source region is out of bounds";
        return false;
    }

    const std::size_t sourceBytesPerPixel = metadata.format.sourceBytesPerPixel();
    const std::size_t metalBytesPerPixel = metadata.format.metalBytesPerPixel();
    std::size_t sourceLastRowStartPixels = 0;
    std::size_t sourceRequiredPixels = 0;
    std::size_t sourceRequiredBytes = 0;
    if (!checkedMultiply(sourceLastY, sourceRowPixels, sourceLastRowStartPixels) ||
        !checkedAdd(sourceLastRowStartPixels, sourceEndX, sourceRequiredPixels) ||
        !checkedMultiply(sourceRequiredPixels, sourceBytesPerPixel, sourceRequiredBytes) ||
        sourceRequiredBytes > sourceSizeInBytes) {
        error = "texture upload source byte range exceeds the supplied source size";
        return false;
    }

    std::size_t bytesPerRow = 0;
    std::size_t retainedSize = 0;
    if (!checkedMultiply(width, metalBytesPerPixel, bytesPerRow) ||
        !checkedMultiply(bytesPerRow, height, retainedSize)) {
        error = "texture upload retained byte size overflows size_t";
        return false;
    }

    PendingUpload upload;
    upload.destinationId = destinationId;
    upload.generation = generation;
    upload.destinationOffsetX = destinationOffsetX;
    upload.destinationOffsetY = destinationOffsetY;
    upload.width = width;
    upload.height = height;
    upload.level = level;
    upload.bytesPerRow = bytesPerRow;
    try {
        upload.bytes.resize(retainedSize);
    } catch (const std::bad_alloc &) {
        error = "unable to retain texture upload bytes";
        return false;
    }

    const auto *sourceBytes = static_cast<const std::byte *>(source);
    for (std::size_t row = 0; row < height; ++row) {
        const std::size_t sourcePixelOffset =
            (sourceOffsetY + row) * sourceRowPixels + sourceOffsetX;
        const std::byte *sourceRow = sourceBytes + sourcePixelOffset * sourceBytesPerPixel;
        std::byte *destinationRow = upload.bytes.data() + row * bytesPerRow;

        if (!metadata.format.requiresExpansion()) {
            std::memcpy(destinationRow, sourceRow, bytesPerRow);
            continue;
        }

        for (std::size_t column = 0; column < width; ++column) {
            const std::byte *sourcePixel = sourceRow + column * sourceBytesPerPixel;
            std::byte *destinationPixel = destinationRow + column * metalBytesPerPixel;
            std::memcpy(destinationPixel, sourcePixel, sourceBytesPerPixel);
            std::memset(destinationPixel + sourceBytesPerPixel, 0,
                        metalBytesPerPixel - sourceBytesPerPixel);
            writeOne(destinationPixel +
                         (metadata.format.metalComponentCount - 1) *
                             metadata.format.bytesPerComponent,
                     metadata.format.bytesPerComponent);
        }
    }

    std::lock_guard lock(mutex_);
    const auto iterator = textures_.find(destinationId);
    if (iterator == textures_.end() || iterator->second.generation != generation) {
        error = "texture was rebuilt while its upload was being queued";
        return false;
    }
    try {
        pendingUploads_.push_back(std::move(upload));
    } catch (const std::bad_alloc &) {
        error = "unable to enqueue retained texture upload bytes";
        return false;
    }
    return true;
}

TextureManager::UploadBatchResult TextureManager::performQueuedUploads() {
    std::vector<PendingUpload> uploads;
    {
        std::lock_guard lock(mutex_);
        uploads.swap(pendingUploads_);
    }

    UploadBatchResult result;
    for (const PendingUpload &upload : uploads) {
        std::lock_guard lock(mutex_);
        const auto iterator = textures_.find(upload.destinationId);
        if (iterator == textures_.end() || iterator->second.texture == nil ||
            iterator->second.generation != upload.generation) {
            ++result.discarded;
            continue;
        }

        const MTLRegion region = MTLRegionMake2D(
            static_cast<NSUInteger>(upload.destinationOffsetX),
            static_cast<NSUInteger>(upload.destinationOffsetY),
            static_cast<NSUInteger>(upload.width),
            static_cast<NSUInteger>(upload.height));
        [iterator->second.texture replaceRegion:region
                                   mipmapLevel:static_cast<NSUInteger>(upload.level)
                                     withBytes:upload.bytes.data()
                                   bytesPerRow:upload.height == 1
                                       ? 0
                                       : static_cast<NSUInteger>(upload.bytesPerRow)];
        ++result.uploaded;
    }
    return result;
}

id<MTLTexture> TextureManager::texture(TextureId id) const {
    std::lock_guard lock(mutex_);
    const auto iterator = textures_.find(id);
    return iterator == textures_.end() ? nil : iterator->second.texture;
}

std::optional<TextureManager::TextureMetadata> TextureManager::metadata(TextureId id) const {
    std::lock_guard lock(mutex_);
    const auto iterator = textures_.find(id);
    return iterator == textures_.end()
        ? std::nullopt
        : std::optional<TextureMetadata>{iterator->second.metadata};
}

TextureManager::BindingSnapshot TextureManager::bindingSnapshot() const {
    std::lock_guard lock(mutex_);
    BindingSnapshot snapshot;
    snapshot.revision = bindingRevision_;
    snapshot.bindings.reserve(textures_.size());
    for (const auto &[textureId, entry] : textures_) {
        if (entry.texture != nil) {
            snapshot.bindings.push_back(TextureBinding{
                textureId, entry.texture, entry.metadata.sampler});
        }
    }
    std::sort(snapshot.bindings.begin(), snapshot.bindings.end(),
              [](const TextureBinding &left, const TextureBinding &right) {
                  return left.textureId < right.textureId;
              });
    return snapshot;
}

bool TextureManager::erase(TextureId id) {
    std::lock_guard lock(mutex_);
    std::erase_if(pendingUploads_, [id](const PendingUpload &upload) {
        return upload.destinationId == id;
    });
    const bool erased = textures_.erase(id) != 0;
    if (erased) {
        advanceRevision(bindingRevision_);
    }
    return erased;
}

void TextureManager::clear() {
    std::lock_guard lock(mutex_);
    pendingUploads_.clear();
    if (!textures_.empty()) {
        advanceRevision(bindingRevision_);
    }
    textures_.clear();
}

} // namespace shadermetal
