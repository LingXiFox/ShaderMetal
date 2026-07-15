package com.example.shadermetal.mixin;

import com.example.shadermetal.render.TextureBridge;
import com.mojang.blaze3d.platform.TextureUtil;
import net.minecraft.client.texture.NativeImage;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(TextureUtil.class)
public abstract class TextureUtilMixin {
    @Inject(method = "generateTextureId()I", at = @At("RETURN"), remap = false)
    private static void shadermetal$registerTextureId(
        CallbackInfoReturnable<Integer> callbackInfo) {
        TextureBridge.registerGeneratedTexture(callbackInfo.getReturnValue());
    }

    @Inject(method = "releaseTextureId(I)V", at = @At("TAIL"), remap = false)
    private static void shadermetal$releaseTextureId(int textureId,
        CallbackInfo callbackInfo) {
        TextureBridge.releaseTexture(textureId);
    }

    @Inject(method = "prepareImage(Lnet/minecraft/client/texture/NativeImage$InternalFormat;"
        + "IIII)V", at = @At("TAIL"))
    private static void shadermetal$prepareImage(NativeImage.InternalFormat format,
        int textureId, int maxLevel, int width, int height, CallbackInfo callbackInfo) {
        TextureBridge.prepareImage(textureId, format, maxLevel, width, height);
    }
}
