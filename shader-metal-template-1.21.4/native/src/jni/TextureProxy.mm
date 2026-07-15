#include "com_example_shadermetal_proxy_TextureProxy.h"

#include "core/MetalDevice.hpp"
#include "resource/TextureManager.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <mutex>
#include <string>

namespace {

std::once_flag emissionTileWarning;

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

void throwIllegalArgument(JNIEnv *environment, const std::string &message) noexcept {
    throwIllegalArgument(environment, message.c_str());
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
        throwIllegalState(environment, "unexpected native texture exception");
    }
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

} // namespace

JNIEXPORT jint JNICALL Java_com_example_shadermetal_proxy_TextureProxy_generateTextureId(
    JNIEnv *environment, jclass) {
    try {
        const auto textureId = shadermetal::TextureManager::shared().allocate();
        if (textureId == shadermetal::TextureManager::kInvalidTextureId) {
            throwIllegalState(environment, "unable to allocate a native texture ID");
        }
        return static_cast<jint>(textureId);
    } catch (...) {
        translateNativeException(environment);
        return shadermetal::TextureManager::kInvalidTextureId;
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_prepareImage(
    JNIEnv *environment, jclass, jint textureId, jint mipLevels, jint width,
    jint height, jint format) {
    try {
        if (textureId <= 0) {
            throwIllegalArgument(environment, "texture ID must be positive");
            return;
        }
        if (mipLevels <= 0 || width <= 0 || height <= 0) {
            throwIllegalArgument(
                environment, "texture dimensions and mip level count must be positive");
            return;
        }
        if (!shadermetal::textureFormatForVk(format).has_value()) {
            throwIllegalArgument(environment, "unsupported VK_FORMAT value");
            return;
        }

        const auto widthValue = static_cast<std::size_t>(width);
        const auto heightValue = static_cast<std::size_t>(height);
        const auto mipLevelValue = static_cast<std::size_t>(mipLevels);
        if (mipLevelValue > maximumMipLevels(widthValue, heightValue)) {
            throwIllegalArgument(environment,
                                 "mip level count exceeds the texture's complete mip chain");
            return;
        }

        auto &manager = shadermetal::TextureManager::shared();
        if (!manager.metadata(textureId).has_value()) {
            throwIllegalArgument(environment, "texture ID was not allocated");
            return;
        }
        id<MTLDevice> device = shadermetal::MetalDevice::shared().device();
        if (device == nil) {
            throwIllegalState(environment, "Metal device is not initialized");
            return;
        }

        std::string error;
        if (!manager.prepare(textureId, mipLevelValue, widthValue, heightValue,
                             format, device, error)) {
            throwIllegalState(environment, error);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_setFilter(
    JNIEnv *environment, jclass, jint textureId, jint samplingMode, jint mipmapMode) {
    try {
        if (textureId <= 0) {
            throwIllegalArgument(environment, "texture ID must be positive");
            return;
        }
        if ((samplingMode != 0 && samplingMode != 1) ||
            (mipmapMode != 0 && mipmapMode != 1)) {
            throwIllegalArgument(environment, "unsupported texture filter mode");
            return;
        }

        std::string error;
        if (!shadermetal::TextureManager::shared().setFilter(
                textureId, samplingMode, mipmapMode, error)) {
            throwIllegalState(environment, error);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_setClamp(
    JNIEnv *environment, jclass, jint textureId, jint addressMode) {
    try {
        if (textureId <= 0) {
            throwIllegalArgument(environment, "texture ID must be positive");
            return;
        }
        if (addressMode != 0 && addressMode != 2) {
            throwIllegalArgument(environment, "unsupported texture address mode");
            return;
        }

        std::string error;
        if (!shadermetal::TextureManager::shared().setAddressMode(
                textureId, addressMode, error)) {
            throwIllegalState(environment, error);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_queueUpload(
    JNIEnv *environment, jclass, jlong source, jint sourceSizeInBytes,
    jint sourceRowPixels, jint destinationId, jint sourceOffsetX,
    jint sourceOffsetY, jint destinationOffsetX, jint destinationOffsetY,
    jint width, jint height, jint level) {
    try {
        if (source == 0) {
            throwIllegalArgument(environment, "texture upload source pointer is null");
            return;
        }
        if (sourceSizeInBytes <= 0 || sourceRowPixels <= 0 || destinationId <= 0 ||
            sourceOffsetX < 0 || sourceOffsetY < 0 || destinationOffsetX < 0 ||
            destinationOffsetY < 0 || width <= 0 || height <= 0 || level < 0) {
            throwIllegalArgument(environment, "texture upload parameters are out of range");
            return;
        }

        auto &manager = shadermetal::TextureManager::shared();
        if (manager.texture(destinationId) == nil) {
            throwIllegalState(environment, "texture upload destination is not initialized");
            return;
        }

        const auto *sourceBytes = reinterpret_cast<const void *>(
            static_cast<std::uintptr_t>(source));
        std::string error;
        if (!manager.queueUpload(
                sourceBytes, static_cast<std::size_t>(sourceSizeInBytes),
                static_cast<std::size_t>(sourceRowPixels), destinationId,
                static_cast<std::size_t>(sourceOffsetX),
                static_cast<std::size_t>(sourceOffsetY),
                static_cast<std::size_t>(destinationOffsetX),
                static_cast<std::size_t>(destinationOffsetY),
                static_cast<std::size_t>(width), static_cast<std::size_t>(height),
                static_cast<std::size_t>(level), error)) {
            throwIllegalArgument(environment, error);
        }
    } catch (...) {
        translateNativeException(environment);
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_uploadEmissionTile(
    JNIEnv *environment, jclass, jint textureId, jlong tileKey, jlong cells,
    jint cellCount) {
    try {
        (void)environment;
        (void)textureId;
        (void)tileKey;
        (void)cells;
        (void)cellCount;
        std::call_once(emissionTileWarning, [] {
            NSLog(@"[ShaderMetal] Texture emission tile upload is not supported in stage B; "
                   "the request is ignored until the ray-tracing emission path is implemented");
        });
    } catch (...) {
        translateNativeException(environment);
    }
}
