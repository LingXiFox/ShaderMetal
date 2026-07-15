#include "com_example_shadermetal_proxy_WindowProxy.h"

#include "core/MetalDevice.hpp"

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_WindowProxy_onFramebufferSizeChanged(
    JNIEnv *, jclass, jint width, jint height) {
    @autoreleasepool {
        if (width <= 0 || height <= 0) {
            return;
        }
        shadermetal::MetalDevice::shared().resize(
            static_cast<std::size_t>(width), static_cast<std::size_t>(height));
    }
}
