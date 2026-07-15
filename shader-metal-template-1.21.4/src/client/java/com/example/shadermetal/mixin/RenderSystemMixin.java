package com.example.shadermetal.mixin;

import com.example.shadermetal.render.GlStateBridge;
import com.mojang.blaze3d.systems.RenderSystem;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(RenderSystem.class)
public abstract class RenderSystemMixin {
    @Inject(method = "lineWidth(F)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$lineWidth(float width, CallbackInfo callbackInfo) {
        GlStateBridge.setLineWidth(width);
    }

    @Redirect(
        method = "flipFrame(JLnet/minecraft/client/util/tracy/TracyFrameCapturer;)V",
        at = @At(
            value = "INVOKE",
            target = "Lorg/lwjgl/glfw/GLFW;glfwSwapBuffers(J)V",
            remap = false
        )
    )
    private static void shadermetal$suppressOpenGlPresentation(long windowHandle) {
    }
}
