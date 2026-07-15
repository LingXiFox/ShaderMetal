#include "com_example_shadermetal_proxy_DrawCommandProxy.h"

#include "render/RasterPass.hpp"

#include <cstddef>
#include <cstdint>
#include <exception>
#include <string>

namespace {

void throwJavaException(JNIEnv *environment, const char *className,
                        const std::string &message) noexcept {
    if (environment == nullptr || environment->ExceptionCheck()) {
        return;
    }
    jclass exceptionClass = environment->FindClass(className);
    if (exceptionClass == nullptr) {
        return;
    }
    environment->ThrowNew(exceptionClass, message.c_str());
    environment->DeleteLocalRef(exceptionClass);
}

void translateNativeException(JNIEnv *environment) noexcept {
    try {
        throw;
    } catch (const std::exception &exception) {
        throwJavaException(environment, "java/lang/IllegalStateException",
                           exception.what());
    } catch (...) {
        throwJavaException(environment, "java/lang/IllegalStateException",
                           "unexpected native draw exception");
    }
}

} // namespace

extern "C" JNIEXPORT void JNICALL
Java_com_example_shadermetal_proxy_DrawCommandProxy_draw(
    JNIEnv *environment, jclass, jint vertexId, jint indexId, jint shaderId,
    jint indexCount, jint indexType, jlong uniformData, jint uniformSize,
    jint instanceCount, jint firstIndex, jint firstVertex, jlong matrixData,
    jint textureId, jboolean worldDraw,
    jboolean transientBuffers) {
    @autoreleasepool {
        try {
            if (vertexId <= 0 || indexId <= 0 || shaderId <= 0) {
                throwJavaException(environment, "java/lang/IllegalArgumentException",
                                   "draw resource IDs must be positive");
                return;
            }
            if (indexCount < 0 || uniformSize < 0 || instanceCount < 0 ||
                firstIndex < 0) {
                throwJavaException(
                    environment, "java/lang/IllegalArgumentException",
                    "draw counts, uniform size, and first index must be nonnegative");
                return;
            }
            if (indexType != 0 && indexType != 1) {
                throwJavaException(environment, "java/lang/IllegalArgumentException",
                                   "draw index type must be 0 (uint16) or 1 (uint32)");
                return;
            }
            if (uniformSize != 0 && uniformData == 0) {
                throwJavaException(environment, "java/lang/IllegalArgumentException",
                                   "draw uniform pointer is null");
                return;
            }
            if (matrixData == 0) {
                throwJavaException(environment, "java/lang/IllegalArgumentException",
                                   "draw matrix pointer is null");
                return;
            }

            const void *uniformPointer = uniformSize == 0
                ? nullptr
                : reinterpret_cast<const void *>(
                      static_cast<std::uintptr_t>(uniformData));
            const void *matrixPointer = reinterpret_cast<const void *>(
                static_cast<std::uintptr_t>(matrixData));
            std::string error;
            if (!shadermetal::RasterPass::shared().enqueueDraw(
                    vertexId, indexId, shaderId, indexCount, indexType,
                    uniformPointer, static_cast<std::size_t>(uniformSize),
                    instanceCount, firstIndex, firstVertex,
                    matrixPointer, textureId, worldDraw != JNI_FALSE,
                    transientBuffers != JNI_FALSE, error)) {
                throwJavaException(environment, "java/lang/IllegalStateException",
                                   error.empty() ? "draw enqueue failed" : error);
            }
        } catch (...) {
            translateNativeException(environment);
        }
    }
}
