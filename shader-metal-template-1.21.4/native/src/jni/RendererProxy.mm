#include "com_example_shadermetal_proxy_RendererProxy.h"

#include "core/FrameContext.hpp"
#include "core/GlfwBridge.hpp"
#include "core/MetalDevice.hpp"

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

JNIEXPORT jint JNICALL Java_com_example_shadermetal_proxy_RendererProxy_maxSupportedTextureSize(
    JNIEnv *, jclass) {
    SHADERMETAL_STAGE_A_STUB();
    return 0;
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
    JNIEnv *, jclass, jlong) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_updateSkyUniform(
    JNIEnv *, jclass, jlong) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_updateOverlayPostUniform(
    JNIEnv *, jclass, jlong) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_setCameraPos(
    JNIEnv *, jclass, jdouble, jdouble, jdouble) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_setClearColor(
    JNIEnv *, jclass, jfloat, jfloat, jfloat, jfloat) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_setClearDepth(
    JNIEnv *, jclass, jdouble) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_RendererProxy_setClearStencil(
    JNIEnv *, jclass, jint) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL
Java_com_example_shadermetal_proxy_RendererProxy_vkCmdClearEntireColorAttachment(
    JNIEnv *, jclass) {
    SHADERMETAL_STAGE_A_STUB();
}

JNIEXPORT void JNICALL
Java_com_example_shadermetal_proxy_RendererProxy_vkCmdClearEntireDepthStencilAttachment(
    JNIEnv *, jclass, jint) {
    SHADERMETAL_STAGE_A_STUB();
}
