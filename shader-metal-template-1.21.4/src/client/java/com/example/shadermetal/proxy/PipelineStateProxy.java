package com.example.shadermetal.proxy;

public final class PipelineStateProxy {
    private PipelineStateProxy() {
    }

    public static native void setScissorEnabled(boolean enabled);

    public static native void setScissor(int x, int y, int width, int height);

    public static native void setViewport(int x, int y, int width, int height);

    public static native void setBlendEnable(boolean enabled);

    public static native void setColorBlendConstants(float red, float green, float blue,
        float alpha);

    public static native void setColorLogicOpEnable(boolean enabled);

    public static native void vkSetBlendFuncSeparate(int sourceColorFactor,
        int sourceAlphaFactor, int destinationColorFactor, int destinationAlphaFactor);

    public static native void vkSetBlendOpSeparate(int colorOperation, int alphaOperation);

    public static native void vkSetColorWriteMask(int colorWriteMask);

    public static native void vkSetColorLogicOp(int colorLogicOperation);

    public static native void setDepthTestEnable(boolean enabled);

    public static native void setDepthWriteEnable(boolean enabled);

    public static native void setStencilTestEnable(boolean enabled);

    public static native void vkSetDepthCompareOp(int depthCompareOperation);

    public static native void vkSetStencilFrontFunc(int compareOperation, int reference,
        int compareMask);

    public static native void vkSetStencilBackFunc(int compareOperation, int reference,
        int compareMask);

    public static native void vkSetStencilFrontOp(int failOperation, int depthFailOperation,
        int passOperation);

    public static native void vkSetStencilBackOp(int failOperation, int depthFailOperation,
        int passOperation);

    public static native void vkSetStencilFrontWriteMask(int writeMask);

    public static native void vkSetStencilBackWriteMask(int writeMask);

    public static native void setLineWidth(float lineWidth);

    public static native void vkSetPolygonMode(int polygonMode);

    public static native void vkSetCullMode(int cullMode);

    public static native void vkSetFrontFace(int frontFace);

    public static native void vkSetDepthBiasEnable(int polygonMode, boolean enabled);

    public static native void vkSetDepthBias(float slopeFactor, float constantFactor);
}
