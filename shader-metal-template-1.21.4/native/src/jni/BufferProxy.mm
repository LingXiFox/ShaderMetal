#include "com_example_shadermetal_proxy_BufferProxy.h"

JNIEXPORT jint JNICALL Java_com_example_shadermetal_proxy_BufferProxy_allocateBuffer(
    JNIEnv *, jclass) {
    return -1;
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_initializeBuffer(
    JNIEnv *, jclass, jint, jint, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_queueUpload(
    JNIEnv *, jclass, jlong, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_performQueuedUpload(
    JNIEnv *, jclass) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_buildIndexBuffer(
    JNIEnv *, jclass, jint, jint, jint, jint, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_BufferProxy_updateMapping(
    JNIEnv *, jclass, jlong) {}
