package com.example.shadermetal.mixin;

import com.mojang.blaze3d.systems.RenderSystem;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

@Mixin(RenderSystem.class)
public abstract class RenderSystemMixin {
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
