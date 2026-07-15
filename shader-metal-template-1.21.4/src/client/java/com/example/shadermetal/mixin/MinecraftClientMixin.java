package com.example.shadermetal.mixin;

import com.example.shadermetal.render.RendererLifecycle;
import net.minecraft.client.MinecraftClient;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(MinecraftClient.class)
public abstract class MinecraftClientMixin {
    @Inject(method = "render(Z)V", at = @At(value = "INVOKE",
        target = "Lnet/minecraft/client/render/GameRenderer;render("
            + "Lnet/minecraft/client/render/RenderTickCounter;Z)V"), require = 1)
    private void shadermetal$beginFrame(boolean tick, CallbackInfo callbackInfo) {
        RendererLifecycle.beginFrame((MinecraftClient) (Object) this);
    }

    @Inject(method = "render(Z)V", at = @At("TAIL"))
    private void shadermetal$endFrame(boolean tick, CallbackInfo callbackInfo) {
        RendererLifecycle.endFrame();
    }

    @Inject(method = "close()V", at = @At("HEAD"))
    private void shadermetal$close(CallbackInfo callbackInfo) {
        RendererLifecycle.close();
    }
}
