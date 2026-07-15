package com.example.shadermetal.mixin;

import com.mojang.blaze3d.systems.RenderSystem;
import net.minecraft.client.MinecraftClient;
import net.minecraft.client.network.ClientPlayerEntity;
import net.minecraft.client.render.GameRenderer;
import net.minecraft.client.render.LightmapTextureManager;
import net.minecraft.client.texture.NativeImage;
import net.minecraft.client.texture.NativeImageBackedTexture;
import net.minecraft.client.world.ClientWorld;
import net.minecraft.entity.LivingEntity;
import net.minecraft.entity.effect.StatusEffects;
import net.minecraft.util.Identifier;
import net.minecraft.util.math.MathHelper;
import net.minecraft.util.profiler.Profiler;
import net.minecraft.util.profiler.Profilers;
import org.joml.Vector3f;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(LightmapTextureManager.class)
public abstract class LightmapTextureManagerMixin {
    @Unique private NativeImageBackedTexture shadermetal$texture;
    @Unique private NativeImage shadermetal$image;
    @Unique private Identifier shadermetal$textureIdentifier;

    @Shadow private boolean dirty;
    @Shadow private float flickerIntensity;
    @Final @Shadow private GameRenderer renderer;
    @Final @Shadow private MinecraftClient client;

    @Shadow
    private float getDarknessFactor(float delta) {
        throw new AssertionError();
    }

    @Shadow
    private float getDarkness(LivingEntity entity, float factor, float delta) {
        throw new AssertionError();
    }

    @Inject(method = "<init>(Lnet/minecraft/client/render/GameRenderer;"
        + "Lnet/minecraft/client/MinecraftClient;)V", at = @At("TAIL"))
    private void shadermetal$initializeTexture(GameRenderer renderer, MinecraftClient client,
        CallbackInfo callbackInfo) {
        shadermetal$texture = new NativeImageBackedTexture(16, 16, false);
        shadermetal$textureIdentifier = Identifier.of("shadermetal", "dynamic/light_map");
        client.getTextureManager().registerTexture(shadermetal$textureIdentifier,
            shadermetal$texture);
        shadermetal$image = shadermetal$texture.getImage();
        if (shadermetal$image == null) {
            throw new IllegalStateException("Lightmap texture image was not initialized");
        }

        for (int y = 0; y < 16; y++) {
            for (int x = 0; x < 16; x++) {
                shadermetal$image.setColorArgb(x, y, 0xFFFFFFFF);
            }
        }

        shadermetal$texture.setClamp(true);
        shadermetal$texture.setFilter(true, false);
        shadermetal$texture.upload();
    }

    @Inject(method = "close()V", at = @At("HEAD"))
    private void shadermetal$closeTexture(CallbackInfo callbackInfo) {
        if (shadermetal$textureIdentifier != null) {
            client.getTextureManager().destroyTexture(shadermetal$textureIdentifier);
        } else if (shadermetal$texture != null) {
            shadermetal$texture.close();
        }
        shadermetal$texture = null;
        shadermetal$image = null;
        shadermetal$textureIdentifier = null;
    }

    @Inject(method = "disable()V", at = @At("HEAD"), cancellable = true)
    private void shadermetal$disable(CallbackInfo callbackInfo) {
        RenderSystem.setShaderTexture(2, 0);
        callbackInfo.cancel();
    }

    @Inject(method = "enable()V", at = @At("HEAD"), cancellable = true)
    private void shadermetal$enable(CallbackInfo callbackInfo) {
        if (shadermetal$textureIdentifier != null) {
            RenderSystem.setShaderTexture(2, shadermetal$textureIdentifier);
        } else {
            RenderSystem.setShaderTexture(2, 0);
        }
        callbackInfo.cancel();
    }

    @Inject(method = "update(F)V", at = @At("HEAD"), cancellable = true)
    private void shadermetal$update(float delta, CallbackInfo callbackInfo) {
        if (!dirty) {
            callbackInfo.cancel();
            return;
        }

        dirty = false;
        Profiler profiler = Profilers.get();
        profiler.push("lightTex");
        try {
            ClientWorld world = client.world;
            ClientPlayerEntity player = client.player;
            if (world == null || player == null || shadermetal$image == null
                || shadermetal$texture == null) {
                return;
            }

            float skyBrightness = world.getSkyBrightness(1.0F);
            float skyFactor = world.getLightningTicksLeft() > 0
                ? 1.0F : skyBrightness * 0.95F + 0.05F;
            float darknessEffect = client.options.getDarknessEffectScale()
                .getValue().floatValue();
            float darknessFactor = getDarknessFactor(delta) * darknessEffect;
            float darkness = getDarkness(player, darknessFactor, delta) * darknessEffect;
            float underwaterVisibility = player.getUnderwaterVisibility();
            float nightVision;
            if (player.hasStatusEffect(StatusEffects.NIGHT_VISION)) {
                nightVision = GameRenderer.getNightVisionStrength(player, delta);
            } else if (underwaterVisibility > 0.0F
                && player.hasStatusEffect(StatusEffects.CONDUIT_POWER)) {
                nightVision = underwaterVisibility;
            } else {
                nightVision = 0.0F;
            }

            Vector3f skyColor = new Vector3f(skyBrightness, skyBrightness, 1.0F)
                .lerp(new Vector3f(1.0F, 1.0F, 1.0F), 0.35F);
            float blockFactor = flickerIntensity + 1.5F;
            boolean brightLightmap = world.getDimensionEffects().shouldBrightenLighting();
            float worldDarkness = renderer.getSkyDarkness(delta);
            Vector3f color = new Vector3f();

            for (int sky = 0; sky < 16; sky++) {
                for (int block = 0; block < 16; block++) {
                    float skyLevel = LightmapTextureManager.getBrightness(world.getDimension(), sky)
                        * skyFactor;
                    float blockLevel = LightmapTextureManager.getBrightness(
                        world.getDimension(), block) * blockFactor;
                    float green = blockLevel
                        * ((blockLevel * 0.6F + 0.4F) * 0.6F + 0.4F);
                    float blue = blockLevel * (blockLevel * blockLevel * 0.6F + 0.4F);
                    color.set(blockLevel, green, blue);

                    if (brightLightmap) {
                        color.lerp(new Vector3f(0.99F, 1.12F, 1.0F), 0.25F);
                        shadermetal$clamp(color);
                    } else {
                        color.add(new Vector3f(skyColor).mul(skyLevel));
                        color.lerp(new Vector3f(0.75F, 0.75F, 0.75F), 0.04F);
                        if (worldDarkness > 0.0F) {
                            color.lerp(new Vector3f(color).mul(0.7F, 0.6F, 0.6F),
                                worldDarkness);
                        }
                    }

                    if (nightVision > 0.0F) {
                        float max = Math.max(color.x(), Math.max(color.y(), color.z()));
                        if (max > 0.0F && max < 1.0F) {
                            color.lerp(new Vector3f(color).mul(1.0F / max), nightVision);
                        }
                    }

                    if (!brightLightmap) {
                        if (darkness > 0.0F) {
                            color.add(-darkness, -darkness, -darkness);
                        }
                        shadermetal$clamp(color);
                    }

                    float gamma = client.options.getGamma().getValue().floatValue();
                    Vector3f eased = new Vector3f(shadermetal$easeOutQuart(color.x()),
                        shadermetal$easeOutQuart(color.y()),
                        shadermetal$easeOutQuart(color.z()));
                    color.lerp(eased, Math.max(0.0F, gamma - darknessFactor));
                    color.lerp(new Vector3f(0.75F, 0.75F, 0.75F), 0.04F);
                    shadermetal$clamp(color);
                    color.mul(255.0F);

                    int red = (int) color.x();
                    int greenInt = (int) color.y();
                    int blueInt = (int) color.z();
                    shadermetal$image.setColorArgb(block, sky,
                        0xFF000000 | red << 16 | greenInt << 8 | blueInt);
                }
            }
            shadermetal$texture.upload();
        } finally {
            profiler.pop();
            callbackInfo.cancel();
        }
    }

    @Unique
    private static void shadermetal$clamp(Vector3f color) {
        color.set(MathHelper.clamp(color.x(), 0.0F, 1.0F),
            MathHelper.clamp(color.y(), 0.0F, 1.0F),
            MathHelper.clamp(color.z(), 0.0F, 1.0F));
    }

    @Unique
    private static float shadermetal$easeOutQuart(float value) {
        float inverse = 1.0F - value;
        return 1.0F - inverse * inverse * inverse * inverse;
    }
}
