package com.example.shadermetal.mixin;

import com.example.shadermetal.render.CoreShaderBridge;
import net.minecraft.client.gl.CompiledShader;
import net.minecraft.util.Identifier;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(CompiledShader.class)
public abstract class CompiledShaderMixin {
    @Inject(method = "compile(Lnet/minecraft/util/Identifier;"
        + "Lnet/minecraft/client/gl/CompiledShader$Type;Ljava/lang/String;)"
        + "Lnet/minecraft/client/gl/CompiledShader;", at = @At("RETURN"))
    private static void shadermetal$captureSource(Identifier id, CompiledShader.Type type,
        String source, CallbackInfoReturnable<CompiledShader> callbackInfo) {
        CoreShaderBridge.captureCompiledShader(callbackInfo.getReturnValue(), id, type, source);
    }
}
