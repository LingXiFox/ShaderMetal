package com.example.shadermetal.proxy;

public final class RendererProxy {
    private RendererProxy() {
    }

    public static native void initFolderPath(String folderPath);

    public static native void initRenderer(String[] glfwLibraryCandidates, long windowHandle);

    public static native void setVsync(boolean enabled);

    public static native int maxSupportedTextureSize();

    public static native void acquireContext();

    public static native void submitCommand();

    public static native void present();

    public static native void fuseWorld();

    public static native void postBlur();

    public static native void close();

    public static native void resetRayTracingScene();

    public static native void shouldRenderWorld(boolean renderWorld);

    public static native void takeScreenshot(boolean withUi, int width, int height, int channels,
        long destination);

    public static native void updateWorldUniform(long source);

    public static native void updateSkyUniform(long source);

    public static native void updateOverlayPostUniform(long source);

    public static native void setCameraPos(double x, double y, double z);

    public static native void setCameraSubmergedInWater(boolean submerged);

    public static native void setLocalPlayerShadowProxy(
        boolean enabled, float relativeX, float relativeY, float relativeZ,
        float bodyYawRadians, int pose, float limbPhase, float limbAmplitude,
        float handSwingProgress, float headYawRadians, float headPitchRadians);

    public static native void setCelestialLighting(
        float sunX, float sunY, float sunZ,
        float sunRed, float sunGreen, float sunBlue,
        float moonX, float moonY, float moonZ,
        float moonRed, float moonGreen, float moonBlue,
        float skyRed, float skyGreen, float skyBlue,
        float weatherStrength);

    public static native void setLocalLights(long source, int count);

    public static native void setClearColor(float red, float green, float blue, float alpha);

    public static native void setClearDepth(double depth);

    public static native void setClearStencil(int stencil);

    public static native void vkCmdClearEntireColorAttachment();

    public static native void vkCmdClearEntireDepthStencilAttachment(int mask);
}
