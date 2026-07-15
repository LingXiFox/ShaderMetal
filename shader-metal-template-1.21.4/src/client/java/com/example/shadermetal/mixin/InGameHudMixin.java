package com.example.shadermetal.mixin;

import net.minecraft.client.MinecraftClient;
import net.minecraft.client.gui.DrawContext;
import net.minecraft.client.gui.hud.InGameHud;
import net.minecraft.client.gui.screen.Screen;
import net.minecraft.client.gui.screen.option.GameOptionsScreen;
import net.minecraft.client.gui.screen.option.OptionsScreen;
import net.minecraft.client.render.RenderTickCounter;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(InGameHud.class)
public abstract class InGameHudMixin {
    @Final @Shadow private MinecraftClient client;

    @Inject(method = "renderMainHud(Lnet/minecraft/client/gui/DrawContext;"
        + "Lnet/minecraft/client/render/RenderTickCounter;)V",
        at = @At("HEAD"), cancellable = true)
    private void shadermetal$hideMainHudBehindOptions(DrawContext context,
        RenderTickCounter tickCounter, CallbackInfo callbackInfo) {
        Screen screen = client.currentScreen;
        if (screen instanceof OptionsScreen || screen instanceof GameOptionsScreen) {
            callbackInfo.cancel();
        }
    }
}
