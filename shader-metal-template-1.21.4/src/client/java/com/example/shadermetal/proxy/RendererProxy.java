package com.example.shadermetal.proxy;

public final class RendererProxy {
    private RendererProxy() {
    }

    public static native void initFolderPath(String folderPath);

    public static native void initRenderer(String[] glfwLibraryCandidates, long windowHandle);

    public static native int maxSupportedTextureSize();

    public static native void acquireContext();

    public static native void submitCommand();

    public static native void present();

    public static native void fuseWorld();

    public static native void postBlur();

    public static native void close();

    public static native void shouldRenderWorld(boolean renderWorld);

    public static native void takeScreenshot(boolean withUi, int width, int height, int channels,
        long destination);

    public static native void updateWorldUniform(long source);

    public static native void updateSkyUniform(long source);

    public static native void updateOverlayPostUniform(long source);

    public static native void setCameraPos(double x, double y, double z);

    public static native void setClearColor(float red, float green, float blue, float alpha);

    public static native void setClearDepth(double depth);

    public static native void setClearStencil(int stencil);

    public static native void vkCmdClearEntireColorAttachment();

    public static native void vkCmdClearEntireDepthStencilAttachment(int mask);
}
