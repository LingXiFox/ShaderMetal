#include "com_example_shadermetal_proxy_WindowProxy.h"

#include "core/MetalDevice.hpp"

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_WindowProxy_onFramebufferSizeChanged(
    JNIEnv *, jclass) {
    @autoreleasepool {
        shadermetal::MetalDevice::shared().resize();
    }
}
