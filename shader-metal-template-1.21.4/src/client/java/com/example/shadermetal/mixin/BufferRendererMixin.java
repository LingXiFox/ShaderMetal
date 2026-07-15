package com.example.shadermetal.mixin;

import com.example.shadermetal.render.CoreShaderBridge;
import net.minecraft.client.render.BufferRenderer;
import net.minecraft.client.render.BuiltBuffer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(BufferRenderer.class)
public abstract class BufferRendererMixin {
    @Inject(method = "drawWithGlobalProgram(Lnet/minecraft/client/render/BuiltBuffer;)V",
        at = @At("HEAD"), cancellable = true)
    private static void shadermetal$drawWithGlobalProgram(BuiltBuffer buffer,
        CallbackInfo callbackInfo) {
        CoreShaderBridge.drawWithGlobalProgram(buffer);
        callbackInfo.cancel();
    }

    @Inject(method = "draw(Lnet/minecraft/client/render/BuiltBuffer;)V",
        at = @At("HEAD"), cancellable = true)
    private static void shadermetal$drawBoundProgram(BuiltBuffer buffer,
        CallbackInfo callbackInfo) {
        CoreShaderBridge.drawBoundProgram(buffer);
        callbackInfo.cancel();
    }
}
