#include "com_example_shadermetal_proxy_ChunkProxy.h"

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_ChunkProxy_initNative(
    JNIEnv *, jclass, jint, jint, jint, jint, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_ChunkProxy_updateSectionPosNative(
    JNIEnv *, jclass, jint, jint, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_ChunkProxy_build(
    JNIEnv *, jclass, jint, jint, jint, jlong, jint, jlong, jlong, jlong, jlong, jlong, jlong,
    jboolean) {}

JNIEXPORT jboolean JNICALL Java_com_example_shadermetal_proxy_ChunkProxy_isChunkReady(
    JNIEnv *, jclass, jlong) {
    return JNI_FALSE;
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_ChunkProxy_relocateSingle(
    JNIEnv *, jclass, jlong, jint, jint, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_ChunkProxy_invalidateSingle(
    JNIEnv *, jclass, jlong) {}
