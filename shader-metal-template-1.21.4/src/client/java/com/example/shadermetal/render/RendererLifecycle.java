package com.example.shadermetal.render;

import com.example.shadermetal.ShaderMetalClient;
import com.example.shadermetal.proxy.BufferProxy;
import com.example.shadermetal.proxy.RendererProxy;
import com.example.shadermetal.proxy.WindowProxy;
import java.util.concurrent.atomic.AtomicBoolean;
import net.minecraft.client.MinecraftClient;

public final class RendererLifecycle {
    private static final String[] GLFW_LIBRARY_CANDIDATES = {
        "libglfw.dylib",
        "libglfw_async.dylib",
        "libglfw.3.dylib"
    };
    private static final AtomicBoolean INITIALIZED = new AtomicBoolean();
    private static volatile boolean vsyncEnabled = true;

    private RendererLifecycle() {
    }

    public static void beginFrame(MinecraftClient client) {
        if (!ShaderMetalClient.isLibraryLoaded()) {
            return;
        }

        if (INITIALIZED.compareAndSet(false, true)) {
            try {
                long windowHandle = client.getWindow().getHandle();
                vsyncEnabled = client.options.getEnableVsync().getValue();
                RendererProxy.setVsync(vsyncEnabled);
                RendererProxy.initRenderer(GLFW_LIBRARY_CANDIDATES, windowHandle);
                RendererProxy.setVsync(vsyncEnabled);
            } catch (RuntimeException | Error exception) {
                INITIALIZED.set(false);
                throw exception;
            }
        }
        RendererProxy.acquireContext();
    }

    public static void endFrame() {
        if (!INITIALIZED.get()) {
            return;
        }
        TextureBridge.flushPending();
        BufferProxy.performQueuedUpload();
        RendererProxy.submitCommand();
        RendererProxy.present();
    }

    public static void framebufferSizeChanged() {
        if (INITIALIZED.get()) {
            WindowProxy.onFramebufferSizeChanged();
        }
    }

    public static void setVsync(boolean enabled) {
        vsyncEnabled = enabled;
        if (INITIALIZED.get()) {
            RendererProxy.setVsync(enabled);
        }
    }

    public static void close() {
        if (INITIALIZED.compareAndSet(true, false)) {
            try {
                CoreShaderBridge.close();
            } finally {
                RendererProxy.close();
            }
        } else {
            CoreShaderBridge.close();
        }
    }
}
