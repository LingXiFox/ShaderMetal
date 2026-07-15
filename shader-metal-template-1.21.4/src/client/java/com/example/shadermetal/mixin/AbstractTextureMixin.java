package com.example.shadermetal.mixin;

import com.example.shadermetal.render.TextureBridge;
import net.minecraft.client.texture.AbstractTexture;
import net.minecraft.util.TriState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(AbstractTexture.class)
public abstract class AbstractTextureMixin {
    @Shadow private boolean bilinear;

    @Shadow
    public abstract int getGlId();

    @Inject(method = "setFilter(ZZ)V", at = @At("TAIL"))
    private void shadermetal$setBooleanFilter(boolean bilinear, boolean mipmap,
        CallbackInfo callbackInfo) {
        TextureBridge.setFilter(getGlId(), bilinear, mipmap);
    }

    @Inject(method = "setFilter(Lnet/minecraft/util/TriState;Z)V", at = @At("TAIL"))
    private void shadermetal$setTriStateFilter(TriState bilinear, boolean mipmap,
        CallbackInfo callbackInfo) {
        TextureBridge.setFilter(getGlId(), this.bilinear, mipmap);
    }

    @Inject(method = "setClamp(Z)V", at = @At("TAIL"))
    private void shadermetal$setClamp(boolean clamp, CallbackInfo callbackInfo) {
        TextureBridge.setClamp(getGlId(), clamp);
    }
}
