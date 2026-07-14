#include "com_example_shadermetal_proxy_TextureProxy.h"

JNIEXPORT jint JNICALL Java_com_example_shadermetal_proxy_TextureProxy_generateTextureId(
    JNIEnv *, jclass) {
    return -1;
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_prepareImage(
    JNIEnv *, jclass, jint, jint, jint, jint, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_setFilter(
    JNIEnv *, jclass, jint, jint, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_setClamp(
    JNIEnv *, jclass, jint, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_queueUpload(
    JNIEnv *, jclass, jlong, jint, jint, jint, jint, jint, jint, jint, jint, jint, jint) {}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_TextureProxy_uploadEmissionTile(
    JNIEnv *, jclass, jint, jlong, jlong, jint) {}
