package com.example.shadermetal.mixin;

import com.example.shadermetal.render.CoreShaderBridge;
import net.minecraft.client.gl.VertexBuffer;
import net.minecraft.client.render.BuiltBuffer;
import net.minecraft.client.util.BufferAllocator;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(VertexBuffer.class)
public abstract class VertexBufferMixin {
    @Inject(method = "upload(Lnet/minecraft/client/render/BuiltBuffer;)V", at = @At("HEAD"))
    private void shadermetal$captureUpload(BuiltBuffer buffer, CallbackInfo callbackInfo) {
        CoreShaderBridge.captureVertexBufferUpload((VertexBuffer) (Object) this, buffer);
    }

    @Inject(method = "uploadIndexBuffer("
        + "Lnet/minecraft/client/util/BufferAllocator$CloseableBuffer;)V",
        at = @At("HEAD"))
    private void shadermetal$captureIndexUpload(BufferAllocator.CloseableBuffer buffer,
        CallbackInfo callbackInfo) {
        CoreShaderBridge.captureVertexBufferIndexUpload((VertexBuffer) (Object) this, buffer);
    }

    @Inject(method = "draw()V", at = @At("HEAD"), cancellable = true)
    private void shadermetal$draw(CallbackInfo callbackInfo) {
        CoreShaderBridge.drawVertexBuffer((VertexBuffer) (Object) this);
        callbackInfo.cancel();
    }

    @Inject(method = "close()V", at = @At("HEAD"))
    private void shadermetal$release(CallbackInfo callbackInfo) {
        CoreShaderBridge.releaseVertexBuffer((VertexBuffer) (Object) this);
    }
}
