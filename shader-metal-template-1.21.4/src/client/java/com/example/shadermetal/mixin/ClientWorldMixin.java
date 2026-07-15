package com.example.shadermetal.mixin;

import com.example.shadermetal.render.RayTracingLightCollector;
import net.minecraft.block.BlockState;
import net.minecraft.client.world.ClientWorld;
import net.minecraft.util.math.BlockPos;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(ClientWorld.class)
public abstract class ClientWorldMixin {
    @Inject(method = "handleBlockUpdate(Lnet/minecraft/util/math/BlockPos;"
        + "Lnet/minecraft/block/BlockState;I)V", at = @At("TAIL"))
    private void shadermetal$updateRayTracingLight(BlockPos pos, BlockState state,
        int flags, CallbackInfo callbackInfo) {
        RayTracingLightCollector.handleBlockUpdate((ClientWorld) (Object) this, pos, state);
    }
}
