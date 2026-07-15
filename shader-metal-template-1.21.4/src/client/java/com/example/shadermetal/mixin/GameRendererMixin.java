package com.example.shadermetal.mixin;

import com.example.shadermetal.proxy.RendererProxy;
import net.minecraft.client.MinecraftClient;
import net.minecraft.client.render.GameRenderer;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(GameRenderer.class)
public abstract class GameRendererMixin {
    @Final @Shadow private MinecraftClient client;

    @Inject(method = "renderBlur()V", at = @At("HEAD"), cancellable = true)
    private void shadermetal$renderBlur(CallbackInfo callbackInfo) {
        if (client.options.getMenuBackgroundBlurrinessValue() >= 1.0F) {
            RendererProxy.postBlur();
        }
        callbackInfo.cancel();
    }
}
