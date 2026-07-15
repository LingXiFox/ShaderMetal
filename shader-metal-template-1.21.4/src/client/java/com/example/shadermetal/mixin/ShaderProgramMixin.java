package com.example.shadermetal.mixin;

import com.example.shadermetal.render.CoreShaderBridge;
import java.util.List;
import net.minecraft.client.gl.CompiledShader;
import net.minecraft.client.gl.ShaderProgram;
import net.minecraft.client.gl.ShaderProgramDefinition;
import net.minecraft.client.render.VertexFormat;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(ShaderProgram.class)
public abstract class ShaderProgramMixin {
    @Inject(method = "create(Lnet/minecraft/client/gl/CompiledShader;"
        + "Lnet/minecraft/client/gl/CompiledShader;Lnet/minecraft/client/render/VertexFormat;)"
        + "Lnet/minecraft/client/gl/ShaderProgram;", at = @At("RETURN"))
    private static void shadermetal$captureProgram(CompiledShader vertexShader,
        CompiledShader fragmentShader, VertexFormat format,
        CallbackInfoReturnable<ShaderProgram> callbackInfo) {
        CoreShaderBridge.captureProgram(callbackInfo.getReturnValue(), vertexShader,
            fragmentShader, format);
    }

    @Inject(method = "set(Ljava/util/List;Ljava/util/List;)V", at = @At("TAIL"))
    private void shadermetal$captureDefinitions(
        List<ShaderProgramDefinition.Uniform> uniforms,
        List<ShaderProgramDefinition.Sampler> samplers, CallbackInfo callbackInfo) {
        CoreShaderBridge.captureDefinitions((ShaderProgram) (Object) this, uniforms, samplers);
    }

    @Inject(method = "addSamplerTexture(Ljava/lang/String;I)V", at = @At("TAIL"))
    private void shadermetal$captureSamplerTexture(String name, int textureId,
        CallbackInfo callbackInfo) {
        CoreShaderBridge.captureSamplerTexture((ShaderProgram) (Object) this, name, textureId);
    }

    @Inject(method = "bind()V", at = @At("HEAD"))
    private void shadermetal$captureBoundProgram(CallbackInfo callbackInfo) {
        CoreShaderBridge.captureBoundProgram((ShaderProgram) (Object) this);
    }

    @Inject(method = "unbind()V", at = @At("HEAD"))
    private static void shadermetal$clearBoundProgram(CallbackInfo callbackInfo) {
        CoreShaderBridge.clearBoundProgram();
    }
}
