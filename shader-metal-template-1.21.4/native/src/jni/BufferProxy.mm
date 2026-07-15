#include "com_example_shadermetal_proxy_BufferProxy.h"

#include "core/MetalDevice.hpp"
#include "render/RasterPass.hpp"
#include "resource/BufferManager.hpp"
#include "resource/TextureManager.hpp"
#include "resource/UniformStorage.hpp"

#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <new>
#include <string>
#include <vector>

namespace {

constexpr jint kIndexTypeUnsignedShort = 0;
constexpr jint kIndexTypeUnsignedInt = 1;
constexpr jint kDrawModeQuads = 7;
constexpr std::size_t kTextureMappingBytes = 4096U * 3U * sizeof(std::int32_t);
static_assert(kTextureMappingBytes == 49152U);

void throwJavaException(JNIEnv *environment, const char *className,
                        const char *message) noexcept {
    if (environment == nullptr || environment->ExceptionCheck()) {
        return;
    }
    jclass exceptionClass = environment->FindClass(className);
    if (exceptionClass == nullptr) {
        return;
    }
    environment->ThrowNew(exceptionClass, message);
    environment->DeleteLocalRef(exceptionClass);
}

void throwIllegalArgument(JNIEnv *environment, const char *message) noexcept {
    throwJavaException(environment, "java/lang/IllegalArgumentException", message);
}

void throwIllegalState(JNIEnv *environment, const char *message) noexcept {
    throwJavaException(environment, "java/lang/IllegalStateException", message);
}

void throwIllegalState(JNIEnv *environment, const std::string &message) noexcept {
    throwIllegalState(environment, message.c_str());
}

void translateNativeException(JNIEnv *environment) noexcept {
    try {
        throw;
    } catch (const std::exception &exception) {
        throwIllegalState(environment, exception.what());
    } catch (...) {
        throwIllegalState(environment, "unexpected native buffer exception");
    }
}

template <typename Index>
bool queueQuadIndices(shadermetal::BufferManager &manager, jint destinationId,
                      jint vertexCount, jint expectedIndexCount,
                      std::string &error) {
    std::vector<Index> indices;
    try {
        indices.resize(static_cast<std::size_t>(expectedIndexCount));
    } catch (const std::bad_alloc &) {
        error = "unable to allocate generated quad indices";
        return false;
    }

    const std::size_t quadCount = static_cast<std::size_t>(vertexCount) / 4U;
    for (std::size_t quad = 0; quad < quadCount; ++quad) {
        const std::uint32_t base = static_cast<std::uint32_t>(quad * 4U);
        const std::size_t output = quad * 6U;
        indices[output] = static_cast<Index>(base);
        indices[output + 1U] = static_cast<Index>(base + 1U);
        indices[output + 2U] = static_cast<Index>(base + 2U);
        indices[output + 3U] = static_cast<Index>(base + 2U);
        indices[output + 4U] = static_cast<Index>(base + 3U);
        indices[output + 5U] = static_cast<Index>(base);
    }
    return manager.queueUpload(indices.data(), destinationId, error);
}

} // namespace

JNIEXPORT jint JNICALL Java_com_example_shadermetal_proxy_BufferProxy_allocateBuffer(
    JNIEnv *environment, jclass) {
    try {
        const auto bufferId = shadermetal::BufferManager::shared().allocate();
        if (bufferId == shadermetal::BufferManager::kInvalidBufferId) {
            throwIllegalState(environment, "unable to allocate a native buffer ID");
        }
        return static_cast<jint>(bufferId);
    } catch (...) {
        translateNativeException(environment);
        return shadermetal::BufferManager::kInvalidBufferId;
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_releaseBuffer(
    JNIEnv *environment, jclass, jint bufferId) {
    try {
        if (bufferId <= 0) {
            throwIllegalArgument(environment, "buffer release ID must be positive");
            return;
        }

        std::string error;
        if (!shadermetal::RasterPass::shared().deferBufferRelease(bufferId, error)) {
            throwIllegalState(environment, error);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_initializeBuffer(
    JNIEnv *environment, jclass, jint bufferId, jint size, jint usageFlags) {
    try {
        if (bufferId <= 0) {
            throwIllegalArgument(environment, "buffer ID must be positive");
            return;
        }
        if (size <= 0) {
            throwIllegalArgument(environment, "buffer size must be positive");
            return;
        }

        id<MTLDevice> device = shadermetal::MetalDevice::shared().device();
        if (device == nil) {
            throwIllegalState(environment, "Metal device is not initialized");
            return;
        }

        std::string error;
        if (!shadermetal::BufferManager::shared().initialize(
                bufferId, static_cast<std::size_t>(size),
                static_cast<std::uint32_t>(usageFlags), device, error)) {
            throwIllegalState(environment, error);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_queueUpload(
    JNIEnv *environment, jclass, jlong source, jint destinationId) {
    try {
        if (source == 0) {
            throwIllegalArgument(environment, "buffer upload source pointer is null");
            return;
        }
        if (destinationId <= 0) {
            throwIllegalArgument(environment, "buffer upload destination ID must be positive");
            return;
        }

        const auto *sourceBytes = reinterpret_cast<const void *>(
            static_cast<std::uintptr_t>(source));
        std::string error;
        if (!shadermetal::BufferManager::shared().queueUpload(
                sourceBytes, destinationId, error)) {
            throwIllegalState(environment, error);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_performQueuedUpload(
    JNIEnv *environment, jclass) {
    try {
        const auto bufferResult =
            shadermetal::BufferManager::shared().performQueuedUploads();
        const auto textureResult =
            shadermetal::TextureManager::shared().performQueuedUploads();
        if (bufferResult.discarded != 0 || textureResult.discarded != 0) {
            NSLog(@"[ShaderMetal] Discarded stale uploads at frame boundary "
                   "(buffers=%zu, textures=%zu)",
                  bufferResult.discarded, textureResult.discarded);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_buildIndexBuffer(
    JNIEnv *environment, jclass, jint bufferId, jint indexType, jint drawMode,
    jint vertexCount, jint expectedIndexCount) {
    try {
        if (bufferId <= 0) {
            throwIllegalArgument(environment, "index buffer ID must be positive");
            return;
        }
        if (indexType != kIndexTypeUnsignedShort && indexType != kIndexTypeUnsignedInt) {
            throwIllegalArgument(environment, "unsupported index type");
            return;
        }
        if (drawMode != kDrawModeQuads) {
            throwIllegalArgument(environment, "generated indices only support QUADS draw mode");
            return;
        }
        if (vertexCount <= 0 || vertexCount % 4 != 0) {
            throwIllegalArgument(environment,
                                 "QUADS vertex count must be positive and divisible by four");
            return;
        }

        const std::int64_t calculatedIndexCount =
            static_cast<std::int64_t>(vertexCount / 4) * 6;
        if (calculatedIndexCount > std::numeric_limits<jint>::max() ||
            expectedIndexCount != calculatedIndexCount) {
            throwIllegalArgument(environment,
                                 "expected index count does not match the QUADS vertex count");
            return;
        }
        if (indexType == kIndexTypeUnsignedShort &&
            static_cast<std::uint64_t>(vertexCount - 1) >
                std::numeric_limits<std::uint16_t>::max()) {
            throwIllegalArgument(environment,
                                 "vertex count exceeds the unsigned-short index range");
            return;
        }

        const std::size_t indexSize = indexType == kIndexTypeUnsignedShort
            ? sizeof(std::uint16_t)
            : sizeof(std::uint32_t);
        const std::size_t requiredBytes =
            static_cast<std::size_t>(expectedIndexCount) * indexSize;
        auto &manager = shadermetal::BufferManager::shared();
        if (manager.buffer(bufferId) == nil) {
            throwIllegalState(environment, "index buffer is not initialized");
            return;
        }
        if (manager.size(bufferId) != requiredBytes) {
            throwIllegalArgument(environment,
                                 "index buffer size does not match the generated index data");
            return;
        }

        std::string error;
        const bool queued = indexType == kIndexTypeUnsignedShort
            ? queueQuadIndices<std::uint16_t>(manager, bufferId, vertexCount,
                                               expectedIndexCount, error)
            : queueQuadIndices<std::uint32_t>(manager, bufferId, vertexCount,
                                               expectedIndexCount, error);
        if (!queued) {
            throwIllegalState(environment, error);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_updateMapping(
    JNIEnv *environment, jclass, jlong source) {
    try {
        if (source == 0) {
            throwIllegalArgument(environment, "texture mapping source pointer is null");
            return;
        }

        const auto *sourceBytes = reinterpret_cast<const void *>(
            static_cast<std::uintptr_t>(source));
        std::string error;
        if (!shadermetal::UniformStorage::shared().copy(
                shadermetal::UniformSlot::TextureMapping, sourceBytes,
                kTextureMappingBytes, error)) {
            throwIllegalState(environment, error);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}
