package com.example.shadermetal.mixin;

import com.example.shadermetal.render.GlStateBridge;
import com.example.shadermetal.render.TextureBridge;
import net.minecraft.client.texture.NativeImage;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(NativeImage.class)
public abstract class NativeImageMixin {
    @Shadow private NativeImage.Format format;
    @Shadow private int width;
    @Shadow private long pointer;
    @Shadow private long sizeBytes;

    @Inject(method = "uploadInternal(IIIIIIIZ)V", at = @At("HEAD"))
    private void shadermetal$queueUpload(int level, int destinationX, int destinationY,
        int sourceX, int sourceY, int uploadWidth, int uploadHeight,
        boolean closeAfterUpload, CallbackInfo callbackInfo) {
        int textureId = GlStateBridge.boundTexture();
        if (textureId == 0) {
            return;
        }
        int byteSize = Math.toIntExact(sizeBytes);
        if (byteSize <= 0 || pointer == 0 || format.getChannelCount() <= 0) {
            throw new IllegalStateException("NativeImage upload source is not allocated");
        }
        TextureBridge.queueUpload(textureId, pointer, byteSize, width, sourceX, sourceY,
            destinationX, destinationY, uploadWidth, uploadHeight, level);
    }
}
