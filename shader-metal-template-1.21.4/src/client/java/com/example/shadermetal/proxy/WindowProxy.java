package com.example.shadermetal.proxy;

public final class WindowProxy {
    private WindowProxy() {
    }

    public static native void onFramebufferSizeChanged(int width, int height);
}
