#include "com_example_shadermetal_proxy_ShaderProxy.h"

#include "core/MetalDevice.hpp"
#include "render/ShaderRegistry.hpp"

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

class UtfChars final {
public:
    UtfChars(JNIEnv *environment, jstring value)
        : environment_(environment), value_(value), chars_(
              value == nullptr ? nullptr
                               : environment->GetStringUTFChars(value, nullptr)) {}

    ~UtfChars() {
        if (chars_ != nullptr) {
            environment_->ReleaseStringUTFChars(value_, chars_);
        }
    }

    const char *get() const noexcept {
        return chars_;
    }

    UtfChars(const UtfChars &) = delete;
    UtfChars &operator=(const UtfChars &) = delete;

private:
    JNIEnv *environment_;
    jstring value_;
    const char *chars_;
};

void translateNativeException(JNIEnv *environment) noexcept {
    try {
        throw;
    } catch (const std::exception &exception) {
        throwJavaException(environment, "java/lang/IllegalStateException",
                           exception.what());
    } catch (...) {
        throwJavaException(environment, "java/lang/IllegalStateException",
                           "unexpected native shader exception");
    }
}

} // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_example_shadermetal_proxy_ShaderProxy_registerShader(
    JNIEnv *environment, jclass, jstring key, jint vertexFormatType,
    jint drawMode, jint uniformSize, jstring vertexSource,
    jstring fragmentSource) {
    @autoreleasepool {
        try {
            if (key == nullptr || vertexSource == nullptr || fragmentSource == nullptr) {
                throwJavaException(environment, "java/lang/NullPointerException",
                                   "shader key and sources must not be null");
                return shadermetal::ShaderRegistry::kInvalidShaderId;
            }
            if (uniformSize < 0) {
                throwJavaException(environment, "java/lang/IllegalArgumentException",
                                   "shader uniform size must be nonnegative");
                return shadermetal::ShaderRegistry::kInvalidShaderId;
            }

            UtfChars keyChars(environment, key);
            UtfChars vertexChars(environment, vertexSource);
            UtfChars fragmentChars(environment, fragmentSource);
            if (keyChars.get() == nullptr || vertexChars.get() == nullptr ||
                fragmentChars.get() == nullptr) {
                return shadermetal::ShaderRegistry::kInvalidShaderId;
            }

            id<MTLDevice> device = shadermetal::MetalDevice::shared().device();
            if (device == nil) {
                throwJavaException(environment, "java/lang/IllegalStateException",
                                   "Metal device is not initialized");
                return shadermetal::ShaderRegistry::kInvalidShaderId;
            }

            std::string error;
            const auto shaderId = shadermetal::ShaderRegistry::shared().registerShader(
                keyChars.get(), vertexFormatType, drawMode, uniformSize,
                vertexChars.get(), fragmentChars.get(), device, error);
            if (shaderId == shadermetal::ShaderRegistry::kInvalidShaderId) {
                throwJavaException(environment, "java/lang/IllegalArgumentException",
                                   error.empty() ? "shader registration failed" : error);
            }
            return static_cast<jint>(shaderId);
        } catch (...) {
            translateNativeException(environment);
            return shadermetal::ShaderRegistry::kInvalidShaderId;
        }
    }
}
