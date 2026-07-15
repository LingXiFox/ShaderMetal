#pragma once

#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace shadermetal {

class BufferManager final {
public:
    using BufferId = std::int32_t;
    static constexpr BufferId kInvalidBufferId = -1;

    struct UploadBatchResult {
        std::size_t uploaded = 0;
        std::size_t discarded = 0;
    };

    static BufferManager &shared();

    BufferId allocate();
    bool initialize(BufferId bufferId, std::size_t size, std::uint32_t usageFlags,
                    id<MTLDevice> device, std::string &error);
    bool queueUpload(const void *source, BufferId destinationId, std::string &error);
    UploadBatchResult performQueuedUploads();

    id<MTLBuffer> buffer(BufferId id) const;
    std::size_t size(BufferId id) const;
    std::uint32_t usageFlags(BufferId id) const;
    bool erase(BufferId id);
    void clear();

    BufferManager(const BufferManager &) = delete;
    BufferManager &operator=(const BufferManager &) = delete;

private:
    struct BufferEntry {
        id<MTLBuffer> buffer = nil;
        std::size_t size = 0;
        std::uint32_t usageFlags = 0;
        std::uint64_t generation = 0;
    };

    struct PendingUpload {
        BufferId destinationId = kInvalidBufferId;
        std::uint64_t generation = 0;
        std::vector<std::byte> bytes;
    };

    BufferManager() = default;
    ~BufferManager() = default;

    mutable std::mutex mutex_;
    std::int64_t nextId_ = 1;
    std::unordered_map<BufferId, BufferEntry> buffers_;
    std::vector<PendingUpload> pendingUploads_;
};

} // namespace shadermetal
