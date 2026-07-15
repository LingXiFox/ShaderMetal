package com.example.shadermetal.mixin;

import com.example.shadermetal.proxy.RendererProxy;
import com.example.shadermetal.render.CoreShaderBridge;
import com.example.shadermetal.render.RayTracingLightCollector;
import net.minecraft.block.enums.CameraSubmersionType;
import net.minecraft.client.MinecraftClient;
import net.minecraft.client.render.Camera;
import net.minecraft.client.render.GameRenderer;
import net.minecraft.client.render.RenderTickCounter;
import net.minecraft.client.world.ClientWorld;
import net.minecraft.entity.EntityPose;
import net.minecraft.util.math.MathHelper;
import net.minecraft.util.math.Vec3d;
import net.minecraft.world.World;
import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(GameRenderer.class)
public abstract class GameRendererMixin {
    @Final @Shadow private MinecraftClient client;
    @Final @Shadow private Camera camera;
    @Unique private ClientWorld shadermetal$rayTracingWorld;

    @Inject(method = "renderWorld(Lnet/minecraft/client/render/RenderTickCounter;)V",
        at = @At("HEAD"))
    private void shadermetal$beginWorld(RenderTickCounter tickCounter,
        CallbackInfo callbackInfo) {
        if (client.world != shadermetal$rayTracingWorld) {
            RendererProxy.resetRayTracingScene();
            shadermetal$rayTracingWorld = client.world;
        }
        CoreShaderBridge.beginWorldPass();
        RendererProxy.shouldRenderWorld(client.world != null);
    }

    @Inject(method = "renderWorld(Lnet/minecraft/client/render/RenderTickCounter;)V",
        at = @At("TAIL"))
    private void shadermetal$fuseWorld(RenderTickCounter tickCounter,
        CallbackInfo callbackInfo) {
        CoreShaderBridge.endWorldPass();
        if (client.world != null) {
            double x = camera.getPos().getX();
            double y = camera.getPos().getY();
            double z = camera.getPos().getZ();
            RendererProxy.setCameraPos(x, y, z);
            RendererProxy.setCameraSubmergedInWater(
                camera.getSubmersionType() == CameraSubmersionType.WATER);

            float tickDelta = tickCounter.getTickDelta(false);
            boolean localPlayerProxyEnabled = client.player != null &&
                camera.getFocusedEntity() == client.player &&
                client.options.getPerspective().isFirstPerson();
            if (localPlayerProxyEnabled) {
                Vec3d playerPosition = client.player.getLerpedPos(tickDelta);
                EntityPose playerPose = client.player.getPose();
                int shadowPose = playerPose == EntityPose.SWIMMING ||
                    playerPose == EntityPose.GLIDING ||
                    playerPose == EntityPose.SPIN_ATTACK ? 2 :
                    playerPose == EntityPose.CROUCHING ? 1 : 0;
                RendererProxy.setLocalPlayerShadowProxy(
                    true,
                    (float) (playerPosition.x - x),
                    (float) (playerPosition.y - y),
                    (float) (playerPosition.z - z),
                    (float) Math.toRadians(MathHelper.lerpAngleDegrees(
                        tickDelta, client.player.prevBodyYaw, client.player.bodyYaw)),
                    shadowPose,
                    client.player.limbAnimator.getPos(tickDelta),
                    Math.min(client.player.limbAnimator.getSpeed(tickDelta), 1.0F),
                    client.player.getHandSwingProgress(tickDelta),
                    (float) Math.toRadians(MathHelper.wrapDegrees(
                        MathHelper.lerpAngleDegrees(tickDelta,
                            client.player.prevHeadYaw, client.player.headYaw)
                        - MathHelper.lerpAngleDegrees(tickDelta,
                            client.player.prevBodyYaw, client.player.bodyYaw))),
                    (float) Math.toRadians(client.player.getPitch(tickDelta)));
            } else {
                RendererProxy.setLocalPlayerShadowProxy(
                    false, 0.0F, 0.0F, 0.0F, 0.0F, 0,
                    0.0F, 0.0F, 0.0F, 0.0F, 0.0F);
            }
            float skyAngle = client.world.getSkyAngle(tickDelta);
            Vector3f sunDirection = new Matrix4f()
                .rotationY((float) (-Math.PI * 0.5))
                .rotateX(skyAngle * (float) (Math.PI * 2.0))
                .transformDirection(new Vector3f(0.0F, 1.0F, 0.0F))
                .normalize();
            Vector3f moonDirection = new Vector3f(sunDirection).negate();

            boolean hasSkyLight = client.world.getDimension().hasSkyLight();
            float daylight = hasSkyLight
                ? clamp01((sunDirection.y + 0.10F) / 0.30F) : 0.0F;
            float moonlight = hasSkyLight
                ? clamp01((-sunDirection.y + 0.04F) / 0.30F) : 0.0F;
            float rain = clamp01(client.world.getRainGradient(tickDelta));
            float thunder = clamp01(client.world.getThunderGradient(tickDelta));
            float directWeather = clamp01(1.0F - rain * 0.65F - thunder * 0.25F);
            float skyWeather = clamp01(1.0F - rain * 0.45F - thunder * 0.35F);

            float horizon = 1.0F - clamp01(Math.abs(sunDirection.y) / 0.35F);
            float sunIntensity = 1.15F * daylight * directWeather;
            float sunRed = sunIntensity;
            float sunGreen = sunIntensity * (0.96F - horizon * 0.24F);
            float sunBlue = sunIntensity * (0.86F - horizon * 0.42F);

            float moonPhaseLight = clamp01(client.world.getMoonSize());
            float moonIntensity = 0.16F * moonlight * moonPhaseLight * directWeather;

            float skyBrightness = hasSkyLight
                ? clamp01(client.world.getSkyBrightness(tickDelta)) : 0.0F;
            boolean nether = client.world.getRegistryKey().equals(World.NETHER);
            boolean end = client.world.getRegistryKey().equals(World.END);
            float fallbackSkyRed = nether ? 0.070F : end ? 0.035F : 0.040F;
            float fallbackSkyGreen = nether ? 0.025F : end ? 0.030F : 0.040F;
            float fallbackSkyBlue = nether ? 0.015F : end ? 0.070F : 0.040F;
            float skyRed = hasSkyLight
                ? skyWeather * (0.025F + daylight * 0.17F
                    + horizon * daylight * 0.035F + skyBrightness * 0.025F)
                : fallbackSkyRed;
            float skyGreen = hasSkyLight
                ? skyWeather * (0.040F + daylight * 0.22F
                    + horizon * daylight * 0.012F + skyBrightness * 0.020F)
                : fallbackSkyGreen;
            float skyBlue = hasSkyLight
                ? skyWeather * (0.085F + daylight * 0.29F
                    + skyBrightness * 0.015F)
                : fallbackSkyBlue;

            RendererProxy.setCelestialLighting(
                sunDirection.x, sunDirection.y, sunDirection.z,
                sunRed, sunGreen, sunBlue,
                moonDirection.x, moonDirection.y, moonDirection.z,
                moonIntensity * 0.42F, moonIntensity * 0.56F,
                moonIntensity * 0.82F,
                skyRed, skyGreen, skyBlue,
                clamp01(Math.max(rain, thunder)));
            RayTracingLightCollector.upload(x, y, z);
        }
        RendererProxy.fuseWorld();
    }

    private static float clamp01(float value) {
        return Math.max(0.0F, Math.min(1.0F, value));
    }

    @Inject(method = "renderHand(Lnet/minecraft/client/render/Camera;F"
        + "Lorg/joml/Matrix4f;)V", at = @At("HEAD"))
    private void shadermetal$beginViewModel(Camera camera, float tickDelta,
        Matrix4f projection, CallbackInfo callbackInfo) {
        CoreShaderBridge.beginViewModelPass();
    }

    @Inject(method = "renderHand(Lnet/minecraft/client/render/Camera;F"
        + "Lorg/joml/Matrix4f;)V", at = @At("TAIL"))
    private void shadermetal$endViewModel(Camera camera, float tickDelta,
        Matrix4f projection, CallbackInfo callbackInfo) {
        CoreShaderBridge.endViewModelPass();
    }

    @Inject(method = "renderBlur()V", at = @At("HEAD"), cancellable = true)
    private void shadermetal$renderBlur(CallbackInfo callbackInfo) {
        if (client.options.getMenuBackgroundBlurrinessValue() >= 1.0F) {
            RendererProxy.postBlur();
        }
        callbackInfo.cancel();
    }
}
