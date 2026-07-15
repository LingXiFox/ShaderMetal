package com.example.shadermetal.mixin;

import com.example.shadermetal.render.RendererLifecycle;
import net.minecraft.client.util.Window;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Window.class)
public abstract class WindowMixin {
    @Inject(method = "setVsync(Z)V", at = @At("TAIL"))
    private void shadermetal$setVsync(boolean enabled, CallbackInfo callbackInfo) {
        RendererLifecycle.setVsync(enabled);
    }

    @Inject(method = "onFramebufferSizeChanged(JII)V", at = @At("TAIL"))
    private void shadermetal$framebufferSizeChanged(long windowHandle, int width, int height,
        CallbackInfo callbackInfo) {
        RendererLifecycle.framebufferSizeChanged(width, height);
    }
}
