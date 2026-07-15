package com.example.shadermetal.mixin;

import com.example.shadermetal.render.GlStateBridge;
import com.example.shadermetal.render.TextureBridge;
import com.mojang.blaze3d.platform.GlStateManager;
import java.nio.IntBuffer;
import java.util.function.Consumer;
import net.minecraft.client.texture.NativeImage;
import org.lwjgl.system.MemoryUtil;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(GlStateManager.class)
public abstract class GlStateManagerMixin {
    @Inject(method = "_upload", at = @At("HEAD"), remap = false)
    private static void shadermetal$upload(int level, int destinationX,
        int destinationY, int width, int height, NativeImage.Format format,
        IntBuffer pixels, Consumer<IntBuffer> disposer, CallbackInfo callbackInfo) {
        int textureId = GlStateBridge.boundTexture();
        if (textureId == 0) {
            return;
        }
        if (format != NativeImage.Format.RGBA || !pixels.isDirect()) {
            throw new IllegalArgumentException(
                "ShaderMetal packed texture upload requires direct RGBA pixels");
        }

        int pixelCount = Math.multiplyExact(width, height);
        if (pixels.remaining() < pixelCount) {
            throw new IllegalArgumentException("Packed texture upload source is too small");
        }
        int byteSize = Math.multiplyExact(pixelCount, Integer.BYTES);
        TextureBridge.queueUpload(textureId, MemoryUtil.memAddress(pixels), byteSize,
            width, 0, 0, destinationX, destinationY, width, height, level);
    }

    @Inject(method = "_activeTexture(I)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$activeTexture(int textureUnit,
        CallbackInfo callbackInfo) {
        GlStateBridge.activeTexture(textureUnit);
    }

    @Inject(method = "_bindTexture(I)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$bindTexture(int textureId, CallbackInfo callbackInfo) {
        GlStateBridge.bindTexture(textureId);
    }

    @Inject(method = "_enableBlend()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$enableBlend(CallbackInfo callbackInfo) {
        GlStateBridge.setBlendEnabled(true);
    }

    @Inject(method = "_disableBlend()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$disableBlend(CallbackInfo callbackInfo) {
        GlStateBridge.setBlendEnabled(false);
    }

    @Inject(method = "_blendFunc(II)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$blendFunction(int source, int destination,
        CallbackInfo callbackInfo) {
        GlStateBridge.setBlendFunction(source, destination);
    }

    @Inject(method = "_blendFuncSeparate(IIII)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$blendFunctionSeparate(int sourceColor,
        int destinationColor, int sourceAlpha, int destinationAlpha,
        CallbackInfo callbackInfo) {
        GlStateBridge.setBlendFunctionSeparate(sourceColor, destinationColor,
            sourceAlpha, destinationAlpha);
    }

    @Inject(method = "_blendEquation(I)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$blendEquation(int equation, CallbackInfo callbackInfo) {
        GlStateBridge.setBlendEquation(equation);
    }

    @Inject(method = "_colorMask(ZZZZ)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$colorMask(boolean red, boolean green, boolean blue,
        boolean alpha, CallbackInfo callbackInfo) {
        GlStateBridge.setColorMask(red, green, blue, alpha);
    }

    @Inject(method = "_enableColorLogicOp()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$enableColorLogic(CallbackInfo callbackInfo) {
        GlStateBridge.setColorLogicEnabled(true);
    }

    @Inject(method = "_disableColorLogicOp()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$disableColorLogic(CallbackInfo callbackInfo) {
        GlStateBridge.setColorLogicEnabled(false);
    }

    @Inject(method = "_logicOp(I)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$logicOperation(int operation,
        CallbackInfo callbackInfo) {
        GlStateBridge.setColorLogicOperation(operation);
    }

    @Inject(method = "_enableDepthTest()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$enableDepthTest(CallbackInfo callbackInfo) {
        GlStateBridge.setDepthTestEnabled(true);
    }

    @Inject(method = "_disableDepthTest()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$disableDepthTest(CallbackInfo callbackInfo) {
        GlStateBridge.setDepthTestEnabled(false);
    }

    @Inject(method = "_depthFunc(I)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$depthFunction(int function,
        CallbackInfo callbackInfo) {
        GlStateBridge.setDepthFunction(function);
    }

    @Inject(method = "_depthMask(Z)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$depthMask(boolean enabled, CallbackInfo callbackInfo) {
        GlStateBridge.setDepthWriteEnabled(enabled);
    }

    @Inject(method = "_stencilFunc(III)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$stencilFunction(int function, int reference, int mask,
        CallbackInfo callbackInfo) {
        GlStateBridge.setStencilFunction(function, reference, mask);
    }

    @Inject(method = "_stencilOp(III)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$stencilOperation(int stencilFail, int depthFail,
        int pass, CallbackInfo callbackInfo) {
        GlStateBridge.setStencilOperation(stencilFail, depthFail, pass);
    }

    @Inject(method = "_stencilMask(I)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$stencilMask(int mask, CallbackInfo callbackInfo) {
        GlStateBridge.setStencilWriteMask(mask);
    }

    @Inject(method = "_enableCull()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$enableCull(CallbackInfo callbackInfo) {
        GlStateBridge.setCullEnabled(true);
    }

    @Inject(method = "_disableCull()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$disableCull(CallbackInfo callbackInfo) {
        GlStateBridge.setCullEnabled(false);
    }

    @Inject(method = "_enableScissorTest()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$enableScissor(CallbackInfo callbackInfo) {
        GlStateBridge.setScissorEnabled(true);
    }

    @Inject(method = "_disableScissorTest()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$disableScissor(CallbackInfo callbackInfo) {
        GlStateBridge.setScissorEnabled(false);
    }

    @Inject(method = "_scissorBox(IIII)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$scissorBox(int x, int y, int width, int height,
        CallbackInfo callbackInfo) {
        GlStateBridge.setScissor(x, y, width, height);
    }

    @Inject(method = "_viewport(IIII)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$viewport(int x, int y, int width, int height,
        CallbackInfo callbackInfo) {
        GlStateBridge.setViewport(x, y, width, height);
    }

    @Inject(method = "_polygonMode(II)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$polygonMode(int face, int mode,
        CallbackInfo callbackInfo) {
        GlStateBridge.setPolygonMode(mode);
    }

    @Inject(method = "_enablePolygonOffset()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$enablePolygonOffset(CallbackInfo callbackInfo) {
        GlStateBridge.setPolygonOffsetEnabled(true);
    }

    @Inject(method = "_disablePolygonOffset()V", at = @At("HEAD"), remap = false)
    private static void shadermetal$disablePolygonOffset(CallbackInfo callbackInfo) {
        GlStateBridge.setPolygonOffsetEnabled(false);
    }

    @Inject(method = "_polygonOffset(FF)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$polygonOffset(float factor, float units,
        CallbackInfo callbackInfo) {
        GlStateBridge.setPolygonOffset(factor, units);
    }

    @Inject(method = "_clearColor(FFFF)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$clearColor(float red, float green, float blue,
        float alpha, CallbackInfo callbackInfo) {
        GlStateBridge.setClearColor(red, green, blue, alpha);
    }

    @Inject(method = "_clearDepth(D)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$clearDepth(double depth, CallbackInfo callbackInfo) {
        GlStateBridge.setClearDepth(depth);
    }

    @Inject(method = "_clearStencil(I)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$clearStencil(int stencil, CallbackInfo callbackInfo) {
        GlStateBridge.setClearStencil(stencil);
    }

    @Inject(method = "_clear(I)V", at = @At("HEAD"), remap = false)
    private static void shadermetal$clear(int mask, CallbackInfo callbackInfo) {
        GlStateBridge.clear(mask);
    }
}
