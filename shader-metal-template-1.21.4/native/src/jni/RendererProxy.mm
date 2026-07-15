#include "com_example_shadermetal_proxy_RendererProxy.h"

#include "core/FrameContext.hpp"
#include "core/GlfwBridge.hpp"
#include "core/MetalDevice.hpp"
#include "render/PipelineStateTracker.hpp"
#include "resource/BufferManager.hpp"
#include "resource/SamplerCache.hpp"
#include "resource/TextureManager.hpp"
#include "resource/UniformStorage.hpp"

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace {

void throwIllegalState(JNIEnv *environment, const std::string &message) {
    NSLog(@"[ShaderMetal] Initialization failed: %s", message.c_str());
    if (environment->ExceptionCheck()) {
        return;
    }
    jclass exceptionClass = environment->FindClass("java/lang/IllegalStateException");
    if (exceptionClass != nullptr) {
        environment->ThrowNew(exceptionClass, message.c_str());
        environment->DeleteLocalRef(exceptionClass);
    }
}

void throwIllegalArgument(JNIEnv *environment, const std::string &message) {
    if (environment->ExceptionCheck()) {
        return;
    }
    jclass exceptionClass = environment->FindClass("java/lang/IllegalArgumentException");
    if (exceptionClass != nullptr) {
        environment->ThrowNew(exceptionClass, message.c_str());
        environment->DeleteLocalRef(exceptionClass);
    }
}

void copyUniform(JNIEnv *environment, jlong source, shadermetal::UniformSlot slot,
                 std::size_t size, const char *name) {
    if (source == 0) {
        throwIllegalArgument(environment, std::string(name) + " uniform source is null");
        return;
    }

    std::string error;
    const auto *data = reinterpret_cast<const void *>(static_cast<std::uintptr_t>(source));
    if (!shadermetal::UniformStorage::shared().copy(slot, data, size, error)) {
        throwIllegalArgument(environment, std::string(name) + " uniform: " + error);
    }
}

std::vector<std::string> readLibraryCandidates(JNIEnv *environment, jobjectArray values) {
    std::vector<std::string> candidates;
    if (values == nullptr) {
        return candidates;
    }

    const jsize count = environment->GetArrayLength(values);
    candidates.reserve(static_cast<std::size_t>(count));
    for (jsize index = 0; index < count; ++index) {
        auto value = static_cast<jstring>(environment->GetObjectArrayElement(values, index));
        if (environment->ExceptionCheck()) {
            return {};
        }
        if (value == nullptr) {
            continue;
        }

        const char *utf8 = environment->GetStringUTFChars(value, nullptr);
        if (utf8 != nullptr) {
            candidates.emplace_back(utf8);
            environment->ReleaseStringUTFChars(value, utf8);
        }
        environment->DeleteLocalRef(value);
        if (environment->ExceptionCheck()) {
            return {};
        }
    }
    return candidates;
}

void logStageAStub(const char *method, std::once_flag &once) {
    std::call_once(once, [method] {
        NSLog(@"[ShaderMetal] Stage A stub: %s", method);
    });
}

#define SHADERMETAL_STAGE_A_STUB() \
    do { \
        static std::once_flag once; \
        logStageAStub(__func__, once); \
    } while (false)

} // namespace

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_initFolderPath(
    JNIEnv *environment, jclass, jstring folderPath) {
    @autoreleasepool {
        if (folderPath == nullptr) {
            NSLog(@"[ShaderMetal] Runtime folder is not set");
            return;
        }
        const char *utf8 = environment->GetStringUTFChars(folderPath, nullptr);
        if (utf8 != nullptr) {
            NSLog(@"[ShaderMetal] Runtime folder: %s", utf8);
            environment->ReleaseStringUTFChars(folderPath, utf8);
        }
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_initRenderer(
    JNIEnv *environment, jclass, jobjectArray libraryCandidates, jlong windowHandle) {
    @autoreleasepool {
        if (shadermetal::MetalDevice::shared().isInitialized()) {
            return;
        }

        const std::vector<std::string> candidates =
            readLibraryCandidates(environment, libraryCandidates);
        if (environment->ExceptionCheck()) {
            return;
        }

        std::string error;
        if (!shadermetal::GlfwBridge::shared().initialize(candidates, error)) {
            throwIllegalState(environment, error);
            return;
        }

        NSWindow *window = shadermetal::GlfwBridge::shared().cocoaWindow(
            static_cast<std::uintptr_t>(windowHandle), error);
        if (window == nil) {
            shadermetal::GlfwBridge::shared().close();
            throwIllegalState(environment, error);
            return;
        }

        if (!shadermetal::MetalDevice::shared().initialize(window, error)) {
            shadermetal::GlfwBridge::shared().close();
            throwIllegalState(environment, error);
        }
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_setVsync(
    JNIEnv *, jclass, jboolean enabled) {
    @autoreleasepool {
        shadermetal::MetalDevice::shared().setDisplaySyncEnabled(enabled == JNI_TRUE);
    }
}

JNIEXPORT jint JNICALL Java_com_example_shadermetal_proxy_RendererProxy_maxSupportedTextureSize(
    JNIEnv *, jclass) {
    id<MTLDevice> device = shadermetal::MetalDevice::shared().device();
    if (device == nil) {
        return 0;
    }
    return [device supportsFamily:MTLGPUFamilyApple10] ? 32768 : 16384;
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_acquireContext(
    JNIEnv *, jclass) {
    @autoreleasepool {
        shadermetal::FrameContext::shared().begin();
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_submitCommand(
    JNIEnv *, jclass) {
    @autoreleasepool {
        shadermetal::FrameContext::shared().encodeStageAClear();
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_present(
    JNIEnv *, jclass) {
    @autoreleasepool {
        shadermetal::FrameContext::shared().presentAndCommit();
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_fuseWorld(
    JNIEnv *, jclass) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_postBlur(
    JNIEnv *, jclass) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_close(
    JNIEnv *, jclass) {
    @autoreleasepool {
        shadermetal::FrameContext::shared().close();
        shadermetal::BufferManager::shared().clear();
        shadermetal::TextureManager::shared().clear();
        shadermetal::SamplerCache::shared().clear();
        shadermetal::UniformStorage::shared().clear();
        shadermetal::PipelineStateTracker::shared().reset();
        shadermetal::MetalDevice::shared().close();
        shadermetal::GlfwBridge::shared().close();
    }
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_shouldRenderWorld(
    JNIEnv *, jclass, jboolean) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_takeScreenshot(
    JNIEnv *, jclass, jboolean, jint, jint, jint, jlong) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_updateWorldUniform(
    JNIEnv *environment, jclass, jlong source) {
    copyUniform(environment, source, shadermetal::UniformSlot::World, 592, "world");
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_updateSkyUniform(
    JNIEnv *environment, jclass, jlong source) {
    copyUniform(environment, source, shadermetal::UniformSlot::Sky, 80, "sky");
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_updateOverlayPostUniform(
    JNIEnv *environment, jclass, jlong source) {
    copyUniform(environment, source, shadermetal::UniformSlot::OverlayPost, 96,
                "overlay post");
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_setCameraPos(
    JNIEnv *, jclass, jdouble, jdouble, jdouble) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_setClearColor(
    JNIEnv *, jclass, jfloat red, jfloat green, jfloat blue, jfloat alpha) {
    shadermetal::FrameContext::shared().setClearColor(red, green, blue, alpha);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_setClearDepth(
    JNIEnv *, jclass, jdouble depth) {
    shadermetal::FrameContext::shared().setClearDepth(depth);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_setClearStencil(
    JNIEnv *, jclass, jint stencil) {
    shadermetal::FrameContext::shared().setClearStencil(
        static_cast<std::uint32_t>(stencil));
}

JNIEXPORT void JNICALL
Java_com_example_shadermetal_proxy_RendererProxy_vkCmdClearEntireColorAttachment(
    JNIEnv *, jclass) {
    shadermetal::FrameContext::shared().requestClearColor();
}

JNIEXPORT void JNICALL
Java_com_example_shadermetal_proxy_RendererProxy_vkCmdClearEntireDepthStencilAttachment(
    JNIEnv *, jclass, jint mask) {
    shadermetal::FrameContext::shared().requestClearDepthStencil(
        static_cast<std::uint32_t>(mask));
}
