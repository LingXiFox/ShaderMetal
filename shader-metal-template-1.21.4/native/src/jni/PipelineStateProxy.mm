#include "com_example_shadermetal_proxy_PipelineStateProxy.h"
#include "render/PipelineStateTracker.hpp"

namespace {

shadermetal::PipelineStateTracker &tracker() {
    return shadermetal::PipelineStateTracker::shared();
}

bool toBool(jboolean value) {
    return value != JNI_FALSE;
}

} // namespace

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setScissorEnabled(
    JNIEnv *, jclass, jboolean enabled) {
    tracker().setScissorEnabled(toBool(enabled));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setScissor(
    JNIEnv *, jclass, jint x, jint y, jint width, jint height) {
    tracker().setScissor(x, y, width, height);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setViewport(
    JNIEnv *, jclass, jint x, jint y, jint width, jint height) {
    tracker().setViewport(x, y, width, height);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setBlendEnable(
    JNIEnv *, jclass, jboolean enabled) {
    tracker().setBlendEnabled(toBool(enabled));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setColorBlendConstants(
    JNIEnv *, jclass, jfloat red, jfloat green, jfloat blue, jfloat alpha) {
    tracker().setColorBlendConstants(red, green, blue, alpha);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setColorLogicOpEnable(
    JNIEnv *, jclass, jboolean enabled) {
    tracker().setColorLogicOperationEnabled(toBool(enabled));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetBlendFuncSeparate(
    JNIEnv *, jclass, jint sourceColorFactor, jint sourceAlphaFactor,
    jint destinationColorFactor, jint destinationAlphaFactor) {
    tracker().setBlendFunction(sourceColorFactor, sourceAlphaFactor,
                               destinationColorFactor, destinationAlphaFactor);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetBlendOpSeparate(
    JNIEnv *, jclass, jint colorOperation, jint alphaOperation) {
    tracker().setBlendOperation(colorOperation, alphaOperation);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetColorWriteMask(
    JNIEnv *, jclass, jint mask) {
    tracker().setColorWriteMask(static_cast<std::uint32_t>(mask));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetColorLogicOp(
    JNIEnv *, jclass, jint operation) {
    tracker().setColorLogicOperation(operation);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setDepthTestEnable(
    JNIEnv *, jclass, jboolean enabled) {
    tracker().setDepthTestEnabled(toBool(enabled));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setDepthWriteEnable(
    JNIEnv *, jclass, jboolean enabled) {
    tracker().setDepthWriteEnabled(toBool(enabled));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setStencilTestEnable(
    JNIEnv *, jclass, jboolean enabled) {
    tracker().setStencilTestEnabled(toBool(enabled));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetDepthCompareOp(
    JNIEnv *, jclass, jint operation) {
    tracker().setDepthCompareOperation(operation);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetStencilFrontFunc(
    JNIEnv *, jclass, jint compareOperation, jint reference, jint compareMask) {
    tracker().setStencilFrontFunction(compareOperation,
        static_cast<std::uint32_t>(reference), static_cast<std::uint32_t>(compareMask));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetStencilBackFunc(
    JNIEnv *, jclass, jint compareOperation, jint reference, jint compareMask) {
    tracker().setStencilBackFunction(compareOperation,
        static_cast<std::uint32_t>(reference), static_cast<std::uint32_t>(compareMask));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetStencilFrontOp(
    JNIEnv *, jclass, jint failOperation, jint depthFailOperation, jint passOperation) {
    tracker().setStencilFrontOperation(failOperation, depthFailOperation, passOperation);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetStencilBackOp(
    JNIEnv *, jclass, jint failOperation, jint depthFailOperation, jint passOperation) {
    tracker().setStencilBackOperation(failOperation, depthFailOperation, passOperation);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetStencilFrontWriteMask(
    JNIEnv *, jclass, jint mask) {
    tracker().setStencilFrontWriteMask(static_cast<std::uint32_t>(mask));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetStencilBackWriteMask(
    JNIEnv *, jclass, jint mask) {
    tracker().setStencilBackWriteMask(static_cast<std::uint32_t>(mask));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_setLineWidth(
    JNIEnv *, jclass, jfloat width) {
    tracker().setLineWidth(width);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetPolygonMode(
    JNIEnv *, jclass, jint mode) {
    tracker().setPolygonMode(mode);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetCullMode(
    JNIEnv *, jclass, jint mode) {
    tracker().setCullMode(mode);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetFrontFace(
    JNIEnv *, jclass, jint face) {
    tracker().setFrontFace(face);
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetDepthBiasEnable(
    JNIEnv *, jclass, jint polygonMode, jboolean enabled) {
    tracker().setDepthBiasEnabled(polygonMode, toBool(enabled));
}

JNIEXPORT void JNICALL Java_com_example_shadermetal_proxy_PipelineStateProxy_vkSetDepthBias(
    JNIEnv *, jclass, jfloat slopeFactor, jfloat constantFactor) {
    tracker().setDepthBias(slopeFactor, constantFactor);
}
