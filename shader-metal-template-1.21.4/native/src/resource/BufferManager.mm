#include "resource/BufferManager.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <new>

namespace shadermetal {

BufferManager &BufferManager::shared() {
    static BufferManager manager;
    return manager;
}

BufferManager::BufferId BufferManager::allocate() {
    std::lock_guard lock(mutex_);
    if (nextId_ > std::numeric_limits<BufferId>::max()) {
        return kInvalidBufferId;
    }

    const BufferId id = static_cast<BufferId>(nextId_);
    try {
        buffers_.try_emplace(id);
    } catch (const std::bad_alloc &) {
        return kInvalidBufferId;
    }
    ++nextId_;
    return id;
}

bool BufferManager::initialize(BufferId bufferId, std::size_t size,
                               std::uint32_t usageFlags, id<MTLDevice> device,
                               std::string &error) {
    if (device == nil) {
        error = "cannot initialize a buffer without a Metal device";
        return false;
    }
    if (size == 0) {
        error = "buffer size must be greater than zero";
        return false;
    }
    if (size > std::numeric_limits<NSUInteger>::max()) {
        error = "buffer size exceeds Metal's NSUInteger range";
        return false;
    }

    {
        std::lock_guard lock(mutex_);
        if (!buffers_.contains(bufferId)) {
            error = "buffer ID was not allocated";
            return false;
        }
    }

    id<MTLBuffer> buffer = [device newBufferWithLength:static_cast<NSUInteger>(size)
                                               options:MTLResourceStorageModeShared];
    if (buffer == nil) {
        error = "Metal failed to allocate the requested buffer";
        return false;
    }
    buffer.label = [NSString stringWithFormat:@"ShaderMetal Buffer %d", bufferId];

    std::lock_guard lock(mutex_);
    auto iterator = buffers_.find(bufferId);
    if (iterator == buffers_.end()) {
        error = "buffer ID was not allocated";
        return false;
    }

    BufferEntry &entry = iterator->second;
    entry.buffer = buffer;
    entry.size = size;
    entry.usageFlags = usageFlags;
    entry.generation = entry.generation == std::numeric_limits<std::uint64_t>::max()
        ? 1
        : entry.generation + 1;
    std::erase_if(pendingUploads_, [bufferId](const PendingUpload &upload) {
        return upload.destinationId == bufferId;
    });
    return true;
}

bool BufferManager::queueUpload(const void *source, BufferId destinationId,
                                std::string &error) {
    if (source == nullptr) {
        error = "buffer upload source is null";
        return false;
    }

    std::lock_guard lock(mutex_);
    const auto iterator = buffers_.find(destinationId);
    if (iterator == buffers_.end() || iterator->second.buffer == nil) {
        error = "buffer upload destination is not initialized";
        return false;
    }

    const BufferEntry &entry = iterator->second;
    try {
        PendingUpload upload;
        upload.destinationId = destinationId;
        upload.generation = entry.generation;
        upload.bytes.resize(entry.size);
        std::memcpy(upload.bytes.data(), source, entry.size);
        pendingUploads_.push_back(std::move(upload));
    } catch (const std::bad_alloc &) {
        error = "unable to retain buffer upload bytes";
        return false;
    }
    return true;
}

BufferManager::UploadBatchResult BufferManager::performQueuedUploads() {
    std::vector<PendingUpload> uploads;
    {
        std::lock_guard lock(mutex_);
        uploads.swap(pendingUploads_);
    }

    UploadBatchResult result;
    for (const PendingUpload &upload : uploads) {
        std::lock_guard lock(mutex_);
        const auto iterator = buffers_.find(upload.destinationId);
        if (iterator == buffers_.end() || iterator->second.buffer == nil ||
            iterator->second.generation != upload.generation ||
            iterator->second.size != upload.bytes.size()) {
            ++result.discarded;
            continue;
        }

        void *destination = iterator->second.buffer.contents;
        if (destination == nullptr) {
            ++result.discarded;
            continue;
        }
        std::memcpy(destination, upload.bytes.data(), upload.bytes.size());
        ++result.uploaded;
    }
    return result;
}

id<MTLBuffer> BufferManager::buffer(BufferId id) const {
    std::lock_guard lock(mutex_);
    const auto iterator = buffers_.find(id);
    return iterator == buffers_.end() ? nil : iterator->second.buffer;
}

std::size_t BufferManager::size(BufferId id) const {
    std::lock_guard lock(mutex_);
    const auto iterator = buffers_.find(id);
    return iterator == buffers_.end() ? 0 : iterator->second.size;
}

std::uint32_t BufferManager::usageFlags(BufferId id) const {
    std::lock_guard lock(mutex_);
    const auto iterator = buffers_.find(id);
    return iterator == buffers_.end() ? 0 : iterator->second.usageFlags;
}

bool BufferManager::erase(BufferId id) {
    std::lock_guard lock(mutex_);
    std::erase_if(pendingUploads_, [id](const PendingUpload &upload) {
        return upload.destinationId == id;
    });
    return buffers_.erase(id) != 0;
}

void BufferManager::clear() {
    std::lock_guard lock(mutex_);
    pendingUploads_.clear();
    buffers_.clear();
}

} // namespace shadermetal
