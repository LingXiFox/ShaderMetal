#include <metal_stdlib>
#include <metal_raytracing>

using namespace metal;
using namespace raytracing;

constant uint kMaterialTextureCount = 4096u;
constant uint kRTInstanceFlagOpaque = 1u << 0u;
constant uint kRTInstanceFlagDynamicVertexBuffer = 1u << 1u;
constant uint kRTInstanceFlagTranslucent = 1u << 2u;
constant uint kRTInstanceFlagAlphaTest = 1u << 3u;
constant uint kDynamicTextureIdMask = 0x00000fffu;
constant uint kDynamicTextureAlphaTestBit = 1u << 30u;
constant uint kDynamicTextureTranslucentBit = 1u << 31u;
constant uint kVisibleSceneInstanceMask = 0x01u;
constant uint kShadowCasterInstanceMask = 0x03u;
constant float3 kLuminanceWeights = float3(0.2126f, 0.7152f, 0.0722f);

struct RTVertex {
    packed_float3 position;
    char4 normal;
    float2 uv;
    uchar4 color;
    int textureId;
};

struct RTInstanceMetadata {
    float4 normalToSceneColumn0;
    float4 normalToSceneColumn1;
    float4 normalToSceneColumn2;
    uint canonicalVertexOffset;
    uint canonicalVertexCount;
    int textureId;
    uint flags;
};

struct RTLocalLight {
    packed_float3 position;
    float radius;
    packed_float3 color;
    float intensity;
};

struct MaterialTextureTable {
    array<texture2d<float>, kMaterialTextureCount> textures [[id(0)]];
    array<sampler, kMaterialTextureCount> samplers
        [[id(kMaterialTextureCount)]];
};

struct RayTraceUniforms {
    float4x4 inverseProjection;
    float4x4 viewToScene;
    float4x4 sceneToCurrentClip;
    float4x4 sceneToPreviousClip;
    float4 cameraAndMinimumDistance;
    float4 previousSceneCameraAndHistory;
    float4 sunDirectionAndAORadius;
    float4 sunRadiance;
    float4 moonDirection;
    float4 moonRadiance;
    float4 skyRadiance;
    float4 sceneUpAndTime;
    float4 sceneEast;
    float4 sceneNorth;
    float4 worldCamera;
    float4 traceParameters;
    uint4 geometryCounts;
    uint4 frameData;
};

struct SurfaceData {
    float3 normal;
    float2 uv;
    float4 vertexColor;
    int textureId;
    uint flags;
};

struct LocalLighting {
    float3 diffuse;
    float3 emissive;
};

struct TracedRadiance {
    float3 radiance;
    float distance;
    uint surfaceClass;
};

struct FullscreenVertexOutput {
    float4 position [[position]];
};

static_assert(sizeof(RTVertex) == 32, "canonical RTVertex ABI must stay 32 bytes");
static_assert(sizeof(RTInstanceMetadata) == 64,
              "RT instance metadata ABI must stay 64 bytes");
static_assert(sizeof(RTLocalLight) == 32,
              "local-light ABI must stay 32 bytes");
static_assert(sizeof(RayTraceUniforms) == 480,
              "ray-tracing uniform ABI must stay 480 bytes");

float luminance(float3 color) {
    return dot(max(color, 0.0f), kLuminanceWeights);
}

float maxChannel(float3 color) {
    return max(color.x, max(color.y, color.z));
}

float3 limitRadiancePreservingColor(float3 radiance,
                                    float maximumLuminance,
                                    float maximumChannel) {
    radiance = max(radiance, 0.0f);
    float radianceLuminance = luminance(radiance);
    float radianceMaximum = maxChannel(radiance);
    float luminanceScale = radianceLuminance > maximumLuminance
        ? maximumLuminance / radianceLuminance
        : 1.0f;
    float channelScale = radianceMaximum > maximumChannel
        ? maximumChannel / radianceMaximum
        : 1.0f;
    return radiance * min(luminanceScale, channelScale);
}

float3 safeNormalize(float3 value, float3 fallback) {
    float lengthSquared = dot(value, value);
    return all(isfinite(value)) && lengthSquared > 1.0e-10f
        ? value * rsqrt(lengthSquared)
        : fallback;
}

float srgbChannelToLinear(float value) {
    value = max(value, 0.0f);
    return value <= 0.04045f
        ? value / 12.92f
        : powr((value + 0.055f) / 1.055f, 2.4f);
}

float3 srgbToLinear(float3 color) {
    return float3(srgbChannelToLinear(color.r),
                  srgbChannelToLinear(color.g),
                  srgbChannelToLinear(color.b));
}

float linearChannelToSrgb(float value) {
    value = max(value, 0.0f);
    return value <= 0.0031308f
        ? value * 12.92f
        : 1.055f * powr(value, 1.0f / 2.4f) - 0.055f;
}

float3 linearToSrgb(float3 color) {
    return float3(linearChannelToSrgb(color.r),
                  linearChannelToSrgb(color.g),
                  linearChannelToSrgb(color.b));
}

uint pcgHash(uint state) {
    state = state * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float random01(thread uint &state) {
    state = pcgHash(state);
    return float(state) * (1.0f / 4294967296.0f);
}

float radicalInverseBase2(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) |
           ((bits & 0xaaaaaaaau) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) |
           ((bits & 0xccccccccu) >> 2u);
    bits = ((bits & 0x0f0f0f0fu) << 4u) |
           ((bits & 0xf0f0f0f0u) >> 4u);
    bits = ((bits & 0x00ff00ffu) << 8u) |
           ((bits & 0xff00ff00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10f;
}

float hashToUnitFloat(uint value) {
    return float(value >> 8u) * (1.0f / 16777216.0f);
}

float2 temporalLowDiscrepancySample(uint2 pixel,
                                    uint imageWidth,
                                    uint frameIndex,
                                    uint dimension) {
    uint sampleIndex = (frameIndex + dimension * 11u) & 31u;
    float2 hammersley = float2(
        (float(sampleIndex) + 0.5f) * (1.0f / 32.0f),
        radicalInverseBase2(sampleIndex));
    uint pixelHash = pcgHash(pixel.x + pixel.y * imageWidth ^
                             (dimension + 1u) * 0x9e3779b9u);
    float2 rotation = float2(
        hashToUnitFloat(pixelHash),
        hashToUnitFloat(pcgHash(pixelHash ^ 0x68bc21ebu)));
    return fract(hammersley + rotation);
}

float2 encodeOctahedral(float3 normal) {
    normal = safeNormalize(normal, float3(0.0f, 1.0f, 0.0f));
    normal /= abs(normal.x) + abs(normal.y) + abs(normal.z);
    float2 encoded = normal.xy;
    if (normal.z < 0.0f) {
        encoded = (1.0f - abs(encoded.yx)) *
            float2(encoded.x >= 0.0f ? 1.0f : -1.0f,
                   encoded.y >= 0.0f ? 1.0f : -1.0f);
    }
    return encoded * 0.5f + 0.5f;
}

float3 decodeOctahedral(float2 encoded) {
    float2 value = encoded * 2.0f - 1.0f;
    float3 normal = float3(value, 1.0f - abs(value.x) - abs(value.y));
    float fold = max(-normal.z, 0.0f);
    normal.x += normal.x >= 0.0f ? -fold : fold;
    normal.y += normal.y >= 0.0f ? -fold : fold;
    return safeNormalize(normal, float3(0.0f, 1.0f, 0.0f));
}

float3 cosineHemisphere(float3 normal, float2 sample) {
    sample = clamp(sample, 0.0f, 1.0f);
    float radius = sqrt(sample.x);
    float angle = 2.0f * M_PI_F * sample.y;
    float3 localDirection = float3(radius * cos(angle),
                                   radius * sin(angle),
                                   sqrt(max(0.0f, 1.0f - sample.x)));
    float3 helper = abs(normal.z) < 0.999f
        ? float3(0.0f, 0.0f, 1.0f)
        : float3(0.0f, 1.0f, 0.0f);
    float3 tangent = safeNormalize(cross(helper, normal),
                                   float3(1.0f, 0.0f, 0.0f));
    float3 bitangent = cross(normal, tangent);
    return safeNormalize(tangent * localDirection.x +
                         bitangent * localDirection.y +
                         normal * localDirection.z,
                         normal);
}

float hash21(float2 point) {
    return fract(sin(dot(point, float2(127.1f, 311.7f))) * 43758.5453f);
}

float valueNoise(float2 point) {
    float2 cell = floor(point);
    float2 fraction = fract(point);
    fraction = fraction * fraction * (3.0f - 2.0f * fraction);
    float lower = mix(hash21(cell), hash21(cell + float2(1.0f, 0.0f)),
                      fraction.x);
    float upper = mix(hash21(cell + float2(0.0f, 1.0f)),
                      hash21(cell + float2(1.0f, 1.0f)), fraction.x);
    return mix(lower, upper, fraction.y);
}

float cloudNoise(float2 point) {
    float result = valueNoise(point) * 0.53f;
    result += valueNoise(point * 2.03f + 17.2f) * 0.27f;
    result += valueNoise(point * 4.11f - 9.7f) * 0.20f;
    return result;
}

bool hasCelestialLighting(constant RayTraceUniforms &uniforms) {
    return maxChannel(uniforms.sunRadiance.xyz) > 1.0e-4f ||
        maxChannel(uniforms.moonRadiance.xyz) > 1.0e-4f;
}

float3 evaluateSky(float3 direction,
                   constant RayTraceUniforms &uniforms,
                   bool includeClouds,
                   bool includeCelestialDisks) {
    float3 up = safeNormalize(uniforms.sceneUpAndTime.xyz,
                              float3(0.0f, 1.0f, 0.0f));
    float3 east = safeNormalize(uniforms.sceneEast.xyz,
                                float3(1.0f, 0.0f, 0.0f));
    float3 north = safeNormalize(uniforms.sceneNorth.xyz,
                                 safeNormalize(cross(up, east),
                                               float3(0.0f, 0.0f, 1.0f)));
    direction = safeNormalize(direction, up);
    float elevation = dot(direction, up);
    float upperHemisphere = clamp(elevation * 6.0f + 0.25f, 0.0f, 1.0f);
    float horizon = powr(1.0f - clamp(elevation, 0.0f, 1.0f), 2.5f);
    float3 baseRadiance = max(uniforms.skyRadiance.xyz, 0.0f);

    if (!hasCelestialLighting(uniforms)) {
        return baseRadiance * mix(0.22f, 1.0f, upperHemisphere);
    }

    float3 sunDirection = safeNormalize(uniforms.sunDirectionAndAORadius.xyz, up);
    float3 moonDirection = safeNormalize(uniforms.moonDirection.xyz, -up);
    float3 sunRadiance = max(uniforms.sunRadiance.xyz, 0.0f);
    float3 moonRadiance = max(uniforms.moonRadiance.xyz, 0.0f);
    float daylight = clamp(maxChannel(sunRadiance) / 1.15f, 0.0f, 1.0f);
    float3 rayleighTint = mix(float3(0.56f, 0.68f, 1.0f),
                              float3(0.18f, 0.43f, 1.0f),
                              clamp(elevation, 0.0f, 1.0f));
    float3 sky = baseRadiance *
        (0.38f + upperHemisphere * 0.72f) *
        mix(float3(1.0f), rayleighTint * 1.46f, daylight * 0.55f);
    sky += baseRadiance * horizon * float3(1.10f, 0.82f, 0.58f) *
        daylight * 0.23f;

    float sunCosine = dot(direction, sunDirection);
    float anisotropy = 0.76f;
    float mieDenominator = max(1.0f + anisotropy * anisotropy -
                               2.0f * anisotropy * sunCosine,
                               0.02f);
    float miePhase = (1.0f - anisotropy * anisotropy) /
        powr(mieDenominator, 1.5f);
    sky += sunRadiance * miePhase * 0.0105f * upperHemisphere;
    if (includeCelestialDisks) {
        float sunDisk = smoothstep(cos(0.0080f), cos(0.0042f), sunCosine);
        float moonDisk = smoothstep(cos(0.0100f), cos(0.0050f),
                                    dot(direction, moonDirection));
        sky += sunRadiance * sunDisk * 12.0f;
        sky += moonRadiance * moonDisk * 4.0f;
    }

    if (includeClouds && elevation > 0.035f) {
        float planeDistance = 128.0f / max(elevation, 0.035f);
        float time = uniforms.sceneUpAndTime.w;
        float2 cloudWorld = uniforms.worldCamera.xz +
            float2(dot(direction, east), dot(direction, north)) * planeDistance;
        float2 cloudCoordinate = cloudWorld * 0.0026f;
        cloudCoordinate += float2(time * 0.0028f, time * 0.0011f);
        float density = smoothstep(0.67f, 0.775f, cloudNoise(cloudCoordinate));
        density *= smoothstep(0.035f, 0.18f, elevation);
        float sunFacing = clamp(dot(up, sunDirection) * 0.5f + 0.5f,
                                0.0f, 1.0f);
        float3 cloudRadiance = baseRadiance * 1.35f +
            sunRadiance * (0.10f + sunFacing * 0.22f) +
            moonRadiance * 0.16f;
        sky = mix(sky, cloudRadiance, density * 0.52f);
    }

    float horizonVisibility = smoothstep(-0.16f, 0.015f, elevation);
    sky *= mix(0.12f, 1.0f, horizonVisibility);
    return max(sky, 0.0f);
}

float3 applyAerialPerspective(float3 radiance,
                              float distance,
                              float3 viewDirection,
                              constant RayTraceUniforms &uniforms) {
    float opticalDistance = max(distance - 128.0f, 0.0f);
    float fogAmount = 1.0f - exp(-opticalDistance * 0.00030f);
    fogAmount = min(fogAmount, 0.32f);
    float3 up = safeNormalize(uniforms.sceneUpAndTime.xyz,
                              float3(0.0f, 1.0f, 0.0f));
    float elevation = dot(safeNormalize(viewDirection, up), up);
    float3 horizontal = viewDirection - up * elevation;
    horizontal = safeNormalize(horizontal, safeNormalize(
        uniforms.sceneEast.xyz, float3(1.0f, 0.0f, 0.0f)));
    float3 fogDirection = safeNormalize(
        horizontal + up * max(elevation, 0.045f), up);
    return mix(radiance, evaluateSky(fogDirection, uniforms, false, false),
               fogAmount);
}

float3 applyUnderwaterMedium(float3 radiance,
                             float distance,
                             float3 viewDirection,
                             constant RayTraceUniforms &uniforms) {
    float submersion = clamp(uniforms.worldCamera.w, 0.0f, 1.0f);
    if (submersion <= 0.0f) {
        return radiance;
    }

    float opticalDistance = min(max(distance, 0.0f), 64.0f);
    float3 absorptionCoefficient = float3(0.145f, 0.056f, 0.025f);
    float3 transmittance = exp(-absorptionCoefficient * opticalDistance);
    float3 up = safeNormalize(uniforms.sceneUpAndTime.xyz,
                              float3(0.0f, 1.0f, 0.0f));
    float upwardView = clamp(dot(safeNormalize(viewDirection, up), up) * 0.5f +
                             0.5f, 0.0f, 1.0f);
    float daylight = clamp(maxChannel(uniforms.sunRadiance.xyz) / 1.15f,
                           0.0f, 1.0f);
    float3 fogRadiance = float3(0.006f, 0.030f, 0.048f) +
        max(uniforms.skyRadiance.xyz, 0.0f) *
            float3(0.045f, 0.150f, 0.235f) +
        float3(0.005f, 0.020f, 0.026f) * daylight * upwardView;
    fogRadiance = limitRadiancePreservingColor(fogRadiance, 0.16f, 0.28f);
    float scattering = 1.0f - exp(-opticalDistance * 0.080f);
    float3 submergedRadiance = radiance * transmittance +
        fogRadiance * scattering;
    return mix(radiance, submergedRadiance, submersion);
}

bool resolveSurface(const device RTVertex *staticVertices,
                    const device RTVertex *dynamicVertices,
                    const device RTInstanceMetadata *instances,
                    uint staticVertexCount,
                    uint dynamicVertexCount,
                    uint instanceCount,
                    uint instanceId,
                    uint userInstanceId,
                    uint primitiveId,
                    float2 barycentrics,
                    thread SurfaceData &surface) {
    if (instanceId >= instanceCount || primitiveId > 0x55555555u ||
        !all(isfinite(barycentrics)) || any(barycentrics < -1.0e-4f) ||
        barycentrics.x + barycentrics.y > 1.0001f) {
        return false;
    }

    const device RTInstanceMetadata &metadata = instances[instanceId];
    bool dynamicGeometry =
        (metadata.flags & kRTInstanceFlagDynamicVertexBuffer) != 0u;
    const device RTVertex *vertices = dynamicGeometry
        ? dynamicVertices
        : staticVertices;
    uint vertexCount = dynamicGeometry ? dynamicVertexCount : staticVertexCount;
    uint localFirstVertex = primitiveId * 3u;
    if (metadata.canonicalVertexOffset != userInstanceId ||
        localFirstVertex > metadata.canonicalVertexCount ||
        metadata.canonicalVertexCount - localFirstVertex < 3u) {
        return false;
    }
    uint firstVertex = userInstanceId + localFirstVertex;
    if (firstVertex < userInstanceId || firstVertex > vertexCount ||
        vertexCount - firstVertex < 3u) {
        return false;
    }

    float3 weights = float3(1.0f - barycentrics.x - barycentrics.y,
                            barycentrics.x, barycentrics.y);
    float3 localNormal = float3(0.0f);
    float2 uv = float2(0.0f);
    float4 vertexColor = float4(0.0f);
    for (uint corner = 0; corner < 3u; ++corner) {
        const device RTVertex &rtVertex = vertices[firstVertex + corner];
        float weight = weights[corner];
        localNormal += (float3(rtVertex.normal.xyz) / 127.0f) * weight;
        uv += rtVertex.uv * weight;
        vertexColor += (float4(rtVertex.color) / 255.0f) * weight;
    }
    localNormal = safeNormalize(localNormal, float3(0.0f, 1.0f, 0.0f));
    float3 sceneNormal =
        metadata.normalToSceneColumn0.xyz * localNormal.x +
        metadata.normalToSceneColumn1.xyz * localNormal.y +
        metadata.normalToSceneColumn2.xyz * localNormal.z;
    if (!all(isfinite(sceneNormal)) || !all(isfinite(uv)) ||
        !all(isfinite(vertexColor)) || dot(sceneNormal, sceneNormal) < 1.0e-8f) {
        return false;
    }

    surface.normal = normalize(sceneNormal);
    surface.uv = uv;
    surface.vertexColor = clamp(vertexColor, 0.0f, 1.0f);
    surface.flags = metadata.flags;
    if (dynamicGeometry) {
        uint packedTextureId = uint(vertices[firstVertex].textureId);
        surface.textureId = int(packedTextureId & kDynamicTextureIdMask);
        surface.flags &= ~(kRTInstanceFlagOpaque |
                           kRTInstanceFlagAlphaTest |
                           kRTInstanceFlagTranslucent);
        if ((packedTextureId & kDynamicTextureTranslucentBit) != 0u) {
            surface.flags |= kRTInstanceFlagTranslucent;
        } else if ((packedTextureId & kDynamicTextureAlphaTestBit) != 0u) {
            surface.flags |= kRTInstanceFlagAlphaTest;
        } else {
            surface.flags |= kRTInstanceFlagOpaque;
        }
    } else {
        surface.textureId = metadata.textureId;
    }
    return true;
}

float4 sampleSurfaceMaterialAtLevel(
    thread const SurfaceData &surface,
    constant MaterialTextureTable &materialTable,
    constant uchar *materialAvailable,
    float mipLevel) {
    float3 color = srgbToLinear(surface.vertexColor.rgb);
    float alpha = surface.vertexColor.a;
    if (surface.textureId >= 0 &&
        uint(surface.textureId) < kMaterialTextureCount &&
        materialAvailable[uint(surface.textureId)] != 0) {
        uint textureId = uint(surface.textureId);
        float4 texel = materialTable.textures[textureId].sample(
            materialTable.samplers[textureId], surface.uv,
            level(clamp(mipLevel, 0.0f, 4.0f)));
        if (all(isfinite(texel))) {
            color *= srgbToLinear(clamp(texel.rgb, 0.0f, 1.0f));
            alpha *= clamp(texel.a, 0.0f, 1.0f);
        }
    }
    return float4(max(color, 0.0f), clamp(alpha, 0.0f, 1.0f));
}

float4 sampleSurfaceMaterial(
    thread const SurfaceData &surface,
    constant MaterialTextureTable &materialTable,
    constant uchar *materialAvailable) {
    return sampleSurfaceMaterialAtLevel(
        surface, materialTable, materialAvailable, 0.0f);
}

float materialMipLevel(float rayDistance) {
    return clamp(log2(max(rayDistance * (1.0f / 16.0f), 1.0f)),
                 0.0f, 4.0f);
}

uint surfaceClass(thread const SurfaceData &surface) {
    if ((surface.flags & kRTInstanceFlagDynamicVertexBuffer) != 0u) {
        return 3u;
    }
    if ((surface.flags & kRTInstanceFlagTranslucent) != 0u) {
        return 2u;
    }
    return 1u;
}

bool waterLikeMaterial(float4 material) {
    constexpr float vanillaWaterAlpha = 180.0f / 255.0f;
    bool waterAlphaSignature = abs(material.a - vanillaWaterAlpha) <= 0.055f;
    bool blueWaterSignature = material.b > material.r * 1.15f &&
        material.b > material.g * 1.02f && material.b > 0.035f;
    return waterAlphaSignature || blueWaterSignature;
}

[[intersection(triangle, triangle_data, instancing)]]
bool alphaTestIntersection(
    uint primitiveId [[primitive_id]],
    uint instanceId [[instance_id]],
    uint userInstanceId [[user_instance_id]],
    float2 barycentrics [[barycentric_coord]],
    const device RTVertex *staticVertices [[buffer(0)]],
    const device RTVertex *dynamicVertices [[buffer(1)]],
    const device RTInstanceMetadata *instances [[buffer(2)]],
    constant uint4 &geometryCounts [[buffer(3)]],
    constant MaterialTextureTable &materialTable [[buffer(4)]],
    constant uchar *materialAvailable [[buffer(5)]]) {
    SurfaceData surface;
    if (!resolveSurface(staticVertices, dynamicVertices, instances,
                        geometryCounts.x, geometryCounts.y, geometryCounts.z,
                        instanceId, userInstanceId, primitiveId, barycentrics,
                        surface)) {
        return false;
    }
    if ((surface.flags & kRTInstanceFlagTranslucent) != 0u) {
        return sampleSurfaceMaterial(
            surface, materialTable, materialAvailable).a >= 0.001f;
    }
    if ((surface.flags & kRTInstanceFlagAlphaTest) != 0u) {
        return sampleSurfaceMaterial(
            surface, materialTable, materialAvailable).a >= 0.1f;
    }
    if ((surface.flags & kRTInstanceFlagOpaque) != 0u) {
        return true;
    }
    return sampleSurfaceMaterial(surface, materialTable, materialAvailable).a >=
        0.1f;
}

float3 traceVisibility(
    instance_acceleration_structure accelerationStructure,
    intersection_function_table<instancing, triangle_data>
        intersectionFunctionTable,
    const device RTVertex *staticVertices,
    const device RTVertex *dynamicVertices,
    const device RTInstanceMetadata *instances,
    constant RayTraceUniforms &uniforms,
    constant MaterialTextureTable &materialTable,
    constant uchar *materialAvailable,
    float3 origin,
    float3 direction,
    float maximumDistance,
    float opaqueEndpointTolerance) {
    float minimumDistance = uniforms.cameraAndMinimumDistance.w;
    float remainingDistance = maximumDistance;
    float3 transmittance = float3(1.0f);
    intersector<instancing, triangle_data> visibilityIntersector;
    visibilityIntersector.assume_geometry_type(geometry_type::triangle);
    visibilityIntersector.accept_any_intersection(false);

    for (uint layer = 0u; layer < 4u && remainingDistance > minimumDistance;
         ++layer) {
        ray visibilityRay(origin, direction, minimumDistance, remainingDistance);
        intersection_result<instancing, triangle_data> hit =
            visibilityIntersector.intersect(
                visibilityRay, accelerationStructure,
                kShadowCasterInstanceMask, intersectionFunctionTable);
        if (hit.type == intersection_type::none) {
            return transmittance;
        }
        SurfaceData surface;
        if (!resolveSurface(staticVertices, dynamicVertices, instances,
                            uniforms.geometryCounts.x,
                            uniforms.geometryCounts.y,
                            uniforms.geometryCounts.z,
                            hit.instance_id, hit.user_instance_id,
                            hit.primitive_id, hit.triangle_barycentric_coord,
                            surface)) {
            // A topology update can briefly expose an AS/metadata mismatch.
            // Treat an unresolvable hit as absent instead of turning the whole
            // light path black and feeding a large invalid region to history.
            return transmittance;
        }
        if ((surface.flags & kRTInstanceFlagTranslucent) == 0u) {
            float distanceFromEndpoint = remainingDistance - hit.distance;
            return opaqueEndpointTolerance > 0.0f &&
                distanceFromEndpoint <= opaqueEndpointTolerance
                ? transmittance
                : float3(0.0f);
        }
        float4 material = sampleSurfaceMaterial(
            surface, materialTable, materialAvailable);
        float tintStrength = clamp(0.58f + material.a * 0.28f, 0.0f, 1.0f);
        float3 layerTransmission =
            mix(float3(1.0f), max(material.rgb, 0.015f), tintStrength) *
            (1.0f - material.a * 0.10f);
        transmittance *= clamp(layerTransmission, 0.0f, 1.0f);
        if (maxChannel(transmittance) < 0.004f) {
            return float3(0.0f);
        }
        float advance = hit.distance + minimumDistance * 4.0f;
        remainingDistance -= advance;
        origin += direction * advance;
    }
    return transmittance;
}

bool selectDominantCelestial(constant RayTraceUniforms &uniforms,
                             thread float3 &direction,
                             thread float3 &radiance,
                             thread float &angularRadius) {
    float3 sun = max(uniforms.sunRadiance.xyz, 0.0f);
    float3 moon = max(uniforms.moonRadiance.xyz, 0.0f);
    if (luminance(sun) >= luminance(moon) && maxChannel(sun) > 1.0e-5f) {
        direction = safeNormalize(uniforms.sunDirectionAndAORadius.xyz,
                                  float3(0.0f, 1.0f, 0.0f));
        radiance = sun;
        angularRadius = 0.0120f;
        return true;
    }
    if (maxChannel(moon) > 1.0e-5f) {
        direction = safeNormalize(uniforms.moonDirection.xyz,
                                  float3(0.0f, -1.0f, 0.0f));
        radiance = moon;
        angularRadius = 0.0080f;
        return true;
    }
    direction = float3(0.0f, 1.0f, 0.0f);
    radiance = float3(0.0f);
    angularRadius = 0.0f;
    return false;
}

float3 jitterDiskDirection(float3 direction,
                           float angularRadius,
                           float2 diskSample) {
    diskSample = clamp(diskSample, 0.0f, 1.0f);
    float radius = sqrt(diskSample.x) * angularRadius;
    float angle = diskSample.y * (2.0f * M_PI_F);
    float3 helper = abs(direction.z) < 0.999f
        ? float3(0.0f, 0.0f, 1.0f)
        : float3(0.0f, 1.0f, 0.0f);
    float3 tangent = safeNormalize(cross(helper, direction),
                                   float3(1.0f, 0.0f, 0.0f));
    float3 bitangent = cross(direction, tangent);
    return safeNormalize(direction + tangent * (cos(angle) * radius) +
                         bitangent * (sin(angle) * radius), direction);
}

float3 traceCelestialLighting(
    float3 position,
    float3 normal,
    float2 diskSample,
    instance_acceleration_structure accelerationStructure,
    intersection_function_table<instancing, triangle_data>
        intersectionFunctionTable,
    const device RTVertex *staticVertices,
    const device RTVertex *dynamicVertices,
    const device RTInstanceMetadata *instances,
    constant RayTraceUniforms &uniforms,
    constant MaterialTextureTable &materialTable,
    constant uchar *materialAvailable) {
    float3 direction;
    float3 radiance;
    float angularRadius;
    if (!selectDominantCelestial(uniforms, direction, radiance, angularRadius)) {
        return float3(0.0f);
    }
    direction = jitterDiskDirection(direction, angularRadius, diskSample);
    float normalToLight = max(dot(normal, direction), 0.0f);
    if (normalToLight <= 0.0f) {
        return float3(0.0f);
    }
    float minimumDistance = uniforms.cameraAndMinimumDistance.w;
    float3 visibility = traceVisibility(
        accelerationStructure, intersectionFunctionTable,
        staticVertices, dynamicVertices, instances, uniforms,
        materialTable, materialAvailable,
        position + normal * (minimumDistance * 2.0f), direction,
        uniforms.traceParameters.x, 0.0f);
    return radiance * visibility * normalToLight;
}

LocalLighting traceLocalLighting(
    float3 position,
    float3 normal,
    thread uint &rngState,
    instance_acceleration_structure accelerationStructure,
    intersection_function_table<instancing, triangle_data>
        intersectionFunctionTable,
    const device RTVertex *staticVertices,
    const device RTVertex *dynamicVertices,
    const device RTInstanceMetadata *instances,
    const device RTLocalLight *localLights,
    uint maximumLightCount,
    constant RayTraceUniforms &uniforms,
    constant MaterialTextureTable &materialTable,
    constant uchar *materialAvailable) {
    LocalLighting result{float3(0.0f), float3(0.0f)};
    float3 strongest = float3(0.0f);
    float3 strongestDirection = float3(0.0f, 1.0f, 0.0f);
    float strongestDistance = 0.0f;
    float strongestAngularRadius = 0.0f;
    float strongestScore = 0.0f;
    uint lightCount = min(uniforms.geometryCounts.w, maximumLightCount);
    for (uint lightIndex = 0u; lightIndex < lightCount;
         ++lightIndex) {
        const device RTLocalLight &light = localLights[lightIndex];
        float3 toLight = float3(light.position) - position;
        float distanceSquared = dot(toLight, toLight);
        if (distanceSquared <= 1.0e-8f) {
            continue;
        }
        float lightRadius = max(light.radius, 0.0f);
        float lightIntensity = max(light.intensity, 0.0f);
        float3 lightColor = max(float3(light.color), 0.0f);
        bool mineralProxy = light.intensity <= 0.25f && light.radius <= 3.01f;
        float emissiveReach = mineralProxy ? min(lightRadius, 0.78f) : 0.62f;
        float maximumReach = max(lightRadius, emissiveReach);
        if (maximumReach <= 0.0f ||
            distanceSquared >= maximumReach * maximumReach) {
            continue;
        }
        float distance = sqrt(distanceSquared);
        if (distance < emissiveReach && lightIntensity > 0.0f) {
            float proximity = clamp(1.0f - distance /
                                    max(emissiveReach, 0.1f), 0.0f, 1.0f);
            proximity = smoothstep(0.0f, 1.0f, proximity);
            float strength = mineralProxy
                ? min(lightIntensity * 0.45f, 0.12f)
                : min(0.08f + sqrt(lightIntensity) * 0.08f, 0.32f);
            result.emissive += lightColor * (strength * proximity);
        }
        if (lightRadius <= 0.0f || distanceSquared >= lightRadius * lightRadius) {
            continue;
        }
        float3 lightDirection = toLight / distance;
        float normalToLight = max(dot(normal, lightDirection), 0.0f);
        if (normalToLight <= 0.0f) {
            continue;
        }
        float range = clamp(1.0f - distance / lightRadius, 0.0f, 1.0f);
        float sourceRadius = clamp(lightRadius * 0.08f, 0.45f, 0.85f);
        float attenuation = range * range /
            max(distanceSquared, sourceRadius * sourceRadius);
        float3 contribution = lightColor * lightIntensity *
            normalToLight * attenuation;
        contribution = limitRadiancePreservingColor(contribution, 1.75f, 3.0f);
        float score = luminance(contribution);
        if (score > strongestScore && all(isfinite(contribution))) {
            strongestScore = score;
            strongest = contribution;
            strongestDirection = lightDirection;
            strongestDistance = distance;
            float emitterRadius = clamp(0.08f + sqrt(lightIntensity) * 0.045f,
                                        0.08f, 0.24f);
            strongestAngularRadius = atan(emitterRadius / max(distance, 0.05f));
        }
    }
    result.emissive = limitRadiancePreservingColor(
        result.emissive, 0.58f, 1.10f);
    if (strongestScore > 0.0f) {
        strongestDirection = jitterDiskDirection(
            strongestDirection, strongestAngularRadius,
            float2(random01(rngState), random01(rngState)));
        float minimumDistance = uniforms.cameraAndMinimumDistance.w;
        float maximumDistance = max(minimumDistance,
                                    strongestDistance - minimumDistance * 2.0f);
        float3 visibility = traceVisibility(
            accelerationStructure, intersectionFunctionTable,
            staticVertices, dynamicVertices, instances, uniforms,
            materialTable, materialAvailable,
            position + normal * (minimumDistance * 2.0f),
            strongestDirection, maximumDistance, 0.8f);
        result.diffuse = strongest * visibility;
    }
    return result;
}

TracedRadiance traceMaterialRadiance(
    float3 rayOrigin,
    float3 rayDirection,
    float maximumDistance,
    thread uint &rngState,
    instance_acceleration_structure accelerationStructure,
    intersection_function_table<instancing, triangle_data>
        intersectionFunctionTable,
    const device RTVertex *staticVertices,
    const device RTVertex *dynamicVertices,
    const device RTInstanceMetadata *instances,
    const device RTLocalLight *localLights,
    constant RayTraceUniforms &uniforms,
    constant MaterialTextureTable &materialTable,
    constant uchar *materialAvailable,
    bool evaluateHitDirectLighting,
    bool includeCelestialDisks) {
    intersector<instancing, triangle_data> materialIntersector;
    materialIntersector.assume_geometry_type(geometry_type::triangle);
    materialIntersector.accept_any_intersection(false);
    float minimumDistance = uniforms.cameraAndMinimumDistance.w;
    float remainingDistance = maximumDistance;
    float travelledDistance = 0.0f;
    float3 throughput = float3(1.0f);

    for (uint layer = 0u; layer < 2u && remainingDistance > minimumDistance;
         ++layer) {
        ray materialRay(rayOrigin, rayDirection,
                        minimumDistance, remainingDistance);
        intersection_result<instancing, triangle_data> hit =
            materialIntersector.intersect(
                materialRay, accelerationStructure,
                kVisibleSceneInstanceMask, intersectionFunctionTable);
        if (hit.type == intersection_type::none) {
            return TracedRadiance{
                throughput * evaluateSky(rayDirection, uniforms, true,
                                         includeCelestialDisks),
                travelledDistance + remainingDistance, 0u};
        }
        SurfaceData surface;
        if (!resolveSurface(staticVertices, dynamicVertices, instances,
                            uniforms.geometryCounts.x,
                            uniforms.geometryCounts.y,
                            uniforms.geometryCounts.z,
                            hit.instance_id, hit.user_instance_id,
                            hit.primitive_id, hit.triangle_barycentric_coord,
                            surface)) {
            return TracedRadiance{throughput * max(uniforms.skyRadiance.xyz, 0.0f),
                                  travelledDistance + hit.distance, 0u};
        }
        float4 material = sampleSurfaceMaterialAtLevel(
            surface, materialTable, materialAvailable,
            materialMipLevel(travelledDistance + hit.distance));
        bool translucent =
            (surface.flags & kRTInstanceFlagTranslucent) != 0u;
        if (translucent && layer == 0u) {
            throughput *= mix(float3(1.0f), max(material.rgb, 0.02f), 0.62f);
            float advance = hit.distance + minimumDistance * 4.0f;
            travelledDistance += advance;
            remainingDistance -= advance;
            rayOrigin += rayDirection * advance;
            continue;
        }

        if (dot(surface.normal, rayDirection) > 0.0f) {
            surface.normal = -surface.normal;
        }
        float3 hitPosition = rayOrigin + rayDirection * hit.distance;
        float3 celestial = float3(0.0f);
        LocalLighting local{float3(0.0f), float3(0.0f)};
        if (evaluateHitDirectLighting) {
            celestial = traceCelestialLighting(
                hitPosition, surface.normal,
                float2(random01(rngState), random01(rngState)),
                accelerationStructure, intersectionFunctionTable,
                staticVertices, dynamicVertices, instances, uniforms,
                materialTable, materialAvailable);
            local = traceLocalLighting(
                hitPosition, surface.normal, rngState,
                accelerationStructure, intersectionFunctionTable,
                staticVertices, dynamicVertices, instances, localLights,
                8u,
                uniforms, materialTable, materialAvailable);
        }
        float3 skyIrradiance = max(uniforms.skyRadiance.xyz, 0.0f) * 0.24f +
            evaluateSky(surface.normal, uniforms, false, false) * 0.09f;
        float3 outgoing = material.rgb *
            (skyIrradiance + celestial * 1.08f + local.diffuse) +
            local.emissive;
        float totalDistance = travelledDistance + hit.distance;
        outgoing = applyAerialPerspective(outgoing, totalDistance,
                                          rayDirection, uniforms);
        return TracedRadiance{throughput * max(outgoing, 0.0f),
                              totalDistance, surfaceClass(surface)};
    }
    return TracedRadiance{
        throughput * evaluateSky(rayDirection, uniforms, true,
                                 includeCelestialDisks),
        travelledDistance, 0u};
}

bool reconstructSceneRay(uint2 pixel,
                         uint2 imageSize,
                         constant RayTraceUniforms &uniforms,
                         thread float3 &origin,
                         thread float3 &direction) {
    float2 jitter = float2(uniforms.sceneEast.w, uniforms.sceneNorth.w);
    float2 ndc = ((float2(pixel) + 0.5f + jitter) /
                  float2(imageSize)) * 2.0f - 1.0f;
    ndc.y = -ndc.y;
    float4 farView = uniforms.inverseProjection * float4(ndc, 1.0f, 1.0f);
    float4 sceneOrigin = uniforms.viewToScene *
        float4(uniforms.cameraAndMinimumDistance.xyz, 1.0f);
    if (!all(isfinite(farView)) || abs(farView.w) < 1.0e-8f ||
        !all(isfinite(sceneOrigin)) || abs(sceneOrigin.w) < 1.0e-8f) {
        return false;
    }
    float3 viewDirection = safeNormalize(
        farView.xyz / farView.w - uniforms.cameraAndMinimumDistance.xyz,
        float3(0.0f, 0.0f, -1.0f));
    origin = sceneOrigin.xyz / sceneOrigin.w;
    direction = (uniforms.viewToScene * float4(viewDirection, 0.0f)).xyz;
    float lengthSquared = dot(direction, direction);
    if (!all(isfinite(direction)) || lengthSquared < 1.0e-8f) {
        return false;
    }
    direction *= rsqrt(lengthSquared);
    return true;
}

float3 waterWaveNormal(float3 baseNormal,
                       float3 scenePosition,
                       constant RayTraceUniforms &uniforms) {
    float3 east = safeNormalize(uniforms.sceneEast.xyz,
                                float3(1.0f, 0.0f, 0.0f));
    float3 north = safeNormalize(uniforms.sceneNorth.xyz,
                                 float3(0.0f, 0.0f, 1.0f));
    float4 sceneCameraH = uniforms.viewToScene *
        float4(uniforms.cameraAndMinimumDistance.xyz, 1.0f);
    float3 sceneCamera = abs(sceneCameraH.w) > 1.0e-8f
        ? sceneCameraH.xyz / sceneCameraH.w
        : float3(0.0f);
    float3 cameraRelativePosition = scenePosition - sceneCamera;
    float worldEast = uniforms.worldCamera.x +
        dot(cameraRelativePosition, east);
    float worldNorth = uniforms.worldCamera.z +
        dot(cameraRelativePosition, north);
    float time = uniforms.sceneUpAndTime.w;
    float wave0 = cos(worldEast * 0.31f + worldNorth * 0.17f + time * 0.75f);
    float wave1 = cos(worldEast * 0.73f - worldNorth * 0.29f - time * 1.10f);
    float wave2 = cos(worldEast * 0.37f + worldNorth * 0.91f + time * 1.36f);
    float slopeEast = wave0 * 0.036f + wave1 * 0.018f + wave2 * 0.008f;
    float slopeNorth = wave0 * 0.020f - wave1 * 0.013f + wave2 * 0.017f;
    float3 perturbed = safeNormalize(baseNormal + east * slopeEast +
                                     north * slopeNorth, baseNormal);
    return dot(perturbed, baseNormal) >= 0.0f ? perturbed : -perturbed;
}

float terrainWetness(float3 scenePosition,
                     float3 worldNormal,
                     constant RayTraceUniforms &uniforms) {
    float rain = clamp(uniforms.skyRadiance.w, 0.0f, 1.0f);
    float upwardExposure = smoothstep(0.18f, 0.78f, worldNormal.y);
    if (rain <= 0.001f || upwardExposure <= 0.001f) {
        return 0.0f;
    }
    float4 sceneCameraH = uniforms.viewToScene *
        float4(uniforms.cameraAndMinimumDistance.xyz, 1.0f);
    float3 sceneCamera = abs(sceneCameraH.w) > 1.0e-8f
        ? sceneCameraH.xyz / sceneCameraH.w : float3(0.0f);
    float3 cameraRelative = scenePosition - sceneCamera;
    float2 worldPosition = uniforms.worldCamera.xz + float2(
        dot(cameraRelative, uniforms.sceneEast.xyz),
        dot(cameraRelative, uniforms.sceneNorth.xyz));
    float pooling = smoothstep(0.38f, 0.78f,
                               valueNoise(worldPosition * 0.075f));
    return rain * upwardExposure * mix(0.72f, 1.0f, pooling);
}

float3 sceneNormalToWorld(float3 sceneNormal,
                          constant RayTraceUniforms &uniforms) {
    float3 worldNormal = float3(
        dot(sceneNormal, uniforms.sceneEast.xyz),
        dot(sceneNormal, uniforms.sceneUpAndTime.xyz),
        dot(sceneNormal, uniforms.sceneNorth.xyz));
    return safeNormalize(worldNormal, float3(0.0f, 1.0f, 0.0f));
}

bool projectDenoiserGuides(float3 scenePosition,
                           constant RayTraceUniforms &uniforms,
                           thread float &depth,
                           thread float2 &motion) {
    depth = 1.0f;
    motion = float2(0.0f);
    float4 currentClip = uniforms.sceneToCurrentClip *
        float4(scenePosition, 1.0f);
    if (!all(isfinite(currentClip)) || abs(currentClip.w) < 1.0e-8f) {
        return false;
    }
    float3 currentNdc = currentClip.xyz / currentClip.w;
    if (!all(isfinite(currentNdc))) {
        return false;
    }
    // Minecraft supplies an OpenGL-style projection. MetalFX consumes the
    // normalized [0, 1] depth convention used by Metal depth textures.
    depth = clamp(currentNdc.z * 0.5f + 0.5f, 0.0f, 1.0f);
    if (uniforms.frameData.y == 0u ||
        uniforms.previousSceneCameraAndHistory.w <= 0.5f) {
        return true;
    }

    float4 previousClip = uniforms.sceneToPreviousClip *
        float4(scenePosition, 1.0f);
    if (!all(isfinite(previousClip)) || abs(previousClip.w) < 1.0e-8f) {
        return false;
    }
    float3 previousNdc = previousClip.xyz / previousClip.w;
    if (!all(isfinite(previousNdc))) {
        return false;
    }
    float2 previousUv = float2(previousNdc.x * 0.5f + 0.5f,
                               0.5f - previousNdc.y * 0.5f);
    float2 currentUv = float2(currentNdc.x * 0.5f + 0.5f,
                              0.5f - currentNdc.y * 0.5f);
    motion = previousUv - currentUv;
    return all(isfinite(motion));
}

void writeDenoiserGuides(
    texture2d<float, access::write> depthTexture,
    texture2d<float, access::write> motionTexture,
    texture2d<float, access::write> normalTexture,
    texture2d<float, access::write> diffuseAlbedoTexture,
    texture2d<float, access::write> specularAlbedoTexture,
    texture2d<float, access::write> roughnessTexture,
    texture2d<float, access::write> reactiveMaskTexture,
    uint2 pixel,
    float depth,
    float2 motion,
    float3 worldNormal,
    float3 diffuseAlbedo,
    float3 specularAlbedo,
    float roughness,
    float reactive) {
    depthTexture.write(float4(clamp(depth, 0.0f, 1.0f), 0.0f, 0.0f, 1.0f),
                       pixel);
    motionTexture.write(float4(motion, 0.0f, 0.0f), pixel);
    normalTexture.write(float4(clamp(worldNormal, -1.0f, 1.0f), 1.0f), pixel);
    diffuseAlbedoTexture.write(
        float4(max(diffuseAlbedo, 0.0f), 1.0f), pixel);
    specularAlbedoTexture.write(
        float4(max(specularAlbedo, 0.0f), 1.0f), pixel);
    roughnessTexture.write(
        float4(clamp(roughness, 0.0f, 1.0f), 0.0f, 0.0f, 1.0f), pixel);
    reactiveMaskTexture.write(
        float4(clamp(reactive, 0.0f, 1.0f), 0.0f, 0.0f, 1.0f), pixel);
}

kernel void rayTraceGI(
    instance_acceleration_structure accelerationStructure [[buffer(0)]],
    const device RTVertex *vertices [[buffer(1)]],
    const device RTInstanceMetadata *instances [[buffer(2)]],
    constant RayTraceUniforms &uniforms [[buffer(3)]],
    constant MaterialTextureTable &materialTable [[buffer(4)]],
    constant uchar *materialAvailable [[buffer(5)]],
    const device RTLocalLight *localLights [[buffer(6)]],
    const device RTVertex *dynamicVertices [[buffer(7)]],
    intersection_function_table<instancing, triangle_data>
        intersectionFunctionTable [[buffer(8)]],
    texture2d<float, access::read> worldColor [[texture(0)]],
    texture2d<half, access::write> rawLighting [[texture(1)]],
    texture2d<half, access::write> currentGeometry [[texture(2)]],
    texture2d<float, access::write> denoiserDepth [[texture(3)]],
    texture2d<float, access::write> denoiserMotion [[texture(4)]],
    texture2d<float, access::write> denoiserNormal [[texture(5)]],
    texture2d<float, access::write> denoiserDiffuseAlbedo [[texture(6)]],
    texture2d<float, access::write> denoiserSpecularAlbedo [[texture(7)]],
    texture2d<float, access::write> denoiserRoughness [[texture(8)]],
    texture2d<float, access::write> denoiserReactiveMask [[texture(9)]],
    depth2d<float, access::sample> worldDepth [[texture(10)]],
    uint2 pixel [[thread_position_in_grid]]) {
    uint2 outputSize = uint2(rawLighting.get_width(), rawLighting.get_height());
    if (any(pixel >= outputSize)) {
        return;
    }
    uint2 colorSize = uint2(worldColor.get_width(), worldColor.get_height());
    uint2 colorPixel = min(uint2((float2(pixel) + 0.5f) *
                                 (float2(colorSize) / float2(outputSize))),
                           colorSize - 1u);
    float4 rasterSample = worldColor.read(colorPixel);
    float3 rasterGamma = all(isfinite(rasterSample.rgb))
        ? clamp(rasterSample.rgb, 0.0f, 1.0f)
        : float3(0.0f);
    float3 rasterLinear = srgbToLinear(rasterGamma);
    constexpr sampler depthSampler(coord::normalized,
                                   address::clamp_to_edge,
                                   filter::nearest);
    float2 rasterUv = (float2(colorPixel) + 0.5f) / float2(colorSize);
    float rasterDepth = worldDepth.sample(depthSampler, rasterUv);
    bool rasterHasGeometry = isfinite(rasterDepth) && rasterDepth < 0.999999f;
    float3 finalRadiance = rasterLinear;
    float4 geometry = float4(0.5f, 0.5f, 0.0f, 0.0f);
    float guideDepth = 1.0f;
    float2 guideMotion = float2(0.0f);
    float3 guideWorldNormal = float3(0.0f, 1.0f, 0.0f);
    float3 guideDiffuseAlbedo = float3(0.0f);
    float3 guideSpecularAlbedo = float3(0.0f);
    float guideRoughness = 1.0f;
    float guideReactive = 0.0f;

    float3 sceneOrigin;
    float3 sceneDirection;
    if (!reconstructSceneRay(pixel, outputSize, uniforms,
                             sceneOrigin, sceneDirection)) {
        rawLighting.write(half4(half3(finalRadiance), 1.0h), pixel);
        currentGeometry.write(half4(geometry), pixel);
        writeDenoiserGuides(
            denoiserDepth, denoiserMotion, denoiserNormal,
            denoiserDiffuseAlbedo, denoiserSpecularAlbedo,
            denoiserRoughness, denoiserReactiveMask, pixel,
            guideDepth, guideMotion, guideWorldNormal,
            guideDiffuseAlbedo, guideSpecularAlbedo,
            guideRoughness, 1.0f);
        return;
    }

    float minimumDistance = uniforms.cameraAndMinimumDistance.w;
    float primaryDistance = uniforms.traceParameters.x;
    ray primaryRay(sceneOrigin, sceneDirection,
                   minimumDistance, primaryDistance);
    intersector<instancing, triangle_data> primaryIntersector;
    primaryIntersector.assume_geometry_type(geometry_type::triangle);
    primaryIntersector.accept_any_intersection(false);
    intersection_result<instancing, triangle_data> primaryHit =
        primaryIntersector.intersect(primaryRay, accelerationStructure,
                                     kVisibleSceneInstanceMask,
                                     intersectionFunctionTable);

    if (primaryHit.type == intersection_type::triangle) {
        float hitDepth = 1.0f;
        float2 ignoredMotion = float2(0.0f);
        bool hitProjectionValid = projectDenoiserGuides(
            sceneOrigin + sceneDirection * primaryHit.distance,
            uniforms, hitDepth, ignoredMotion);
        float depthTolerance = mix(0.010f, 0.0035f,
                                   clamp(rasterDepth, 0.0f, 1.0f));
        bool hitMatchesRaster = rasterHasGeometry && hitProjectionValid &&
            abs(hitDepth - rasterDepth) <= depthTolerance;
        if (!hitMatchesRaster) {
            // Raster depth is the current-frame visibility authority. During a
            // chunk rebuild, a retiring BLAS may still be referenced by an
            // older in-flight frame; never let that stale hit replace the new
            // raster surface or poison temporal history.
            guideDepth = rasterHasGeometry ? rasterDepth : 1.0f;
            guideDiffuseAlbedo = rasterLinear;
            guideReactive = 1.0f;
            rawLighting.write(half4(half3(max(rasterLinear, 0.0f)), 1.0h), pixel);
            currentGeometry.write(half4(geometry), pixel);
            writeDenoiserGuides(
                denoiserDepth, denoiserMotion, denoiserNormal,
                denoiserDiffuseAlbedo, denoiserSpecularAlbedo,
                denoiserRoughness, denoiserReactiveMask, pixel,
                guideDepth, float2(0.0f), guideWorldNormal,
                guideDiffuseAlbedo, guideSpecularAlbedo,
                guideRoughness, guideReactive);
            return;
        }
    }

    if (primaryHit.type != intersection_type::triangle) {
        if (!rasterHasGeometry) {
            float3 physicalSky = evaluateSky(sceneDirection, uniforms, true, true);
            float weatherBlend = clamp(uniforms.skyRadiance.w * 0.45f,
                                       0.0f, 0.45f);
            finalRadiance = mix(physicalSky, rasterLinear, weatherBlend);
        } else {
            finalRadiance = applyAerialPerspective(
                rasterLinear, 96.0f, sceneDirection, uniforms);
        }
        finalRadiance = applyUnderwaterMedium(
            finalRadiance, primaryDistance, sceneDirection, uniforms);
        bool guideProjectionValid = projectDenoiserGuides(
            sceneOrigin + sceneDirection * primaryDistance,
            uniforms, guideDepth, guideMotion);
        guideReactive = guideProjectionValid ? 0.0f : 1.0f;
        rawLighting.write(half4(half3(max(finalRadiance, 0.0f)), 1.0h), pixel);
        currentGeometry.write(half4(geometry), pixel);
        writeDenoiserGuides(
            denoiserDepth, denoiserMotion, denoiserNormal,
            denoiserDiffuseAlbedo, denoiserSpecularAlbedo,
            denoiserRoughness, denoiserReactiveMask, pixel,
            guideDepth, guideMotion, guideWorldNormal,
            guideDiffuseAlbedo, guideSpecularAlbedo,
            guideRoughness, guideReactive);
        return;
    }

    SurfaceData primarySurface;
    if (!resolveSurface(vertices, dynamicVertices, instances,
                        uniforms.geometryCounts.x,
                        uniforms.geometryCounts.y,
                        uniforms.geometryCounts.z,
                        primaryHit.instance_id, primaryHit.user_instance_id,
                        primaryHit.primitive_id,
                        primaryHit.triangle_barycentric_coord,
                        primarySurface)) {
        float unresolvedDistance = max(primaryHit.distance, 0.0f);
        projectDenoiserGuides(
            sceneOrigin + sceneDirection * unresolvedDistance,
            uniforms, guideDepth, guideMotion);
        rawLighting.write(half4(half3(finalRadiance), 1.0h), pixel);
        currentGeometry.write(half4(geometry), pixel);
        writeDenoiserGuides(
            denoiserDepth, denoiserMotion, denoiserNormal,
            denoiserDiffuseAlbedo, denoiserSpecularAlbedo,
            denoiserRoughness, denoiserReactiveMask, pixel,
            guideDepth, float2(0.0f), guideWorldNormal,
            guideDiffuseAlbedo, guideSpecularAlbedo,
            guideRoughness, 1.0f);
        return;
    }

    float3 hitPosition = sceneOrigin + sceneDirection * primaryHit.distance;
    bool geometricFrontFace = dot(primarySurface.normal, sceneDirection) < 0.0f;
    if (!geometricFrontFace) {
        primarySurface.normal = -primarySurface.normal;
    }
    float4 material = sampleSurfaceMaterialAtLevel(
        primarySurface, materialTable, materialAvailable,
        materialMipLevel(primaryHit.distance));
    uint classification = surfaceClass(primarySurface);
    uint rngState = pcgHash(pixel.x + pixel.y * outputSize.x +
                            uniforms.frameData.x * 0x9E3779B9u);

    bool translucent =
        (primarySurface.flags & kRTInstanceFlagTranslucent) != 0u;
    bool waterLike = translucent && waterLikeMaterial(material);
    if (waterLike) {
        primarySurface.normal = waterWaveNormal(
            primarySurface.normal, hitPosition, uniforms);
        if (dot(primarySurface.normal, sceneDirection) > 0.0f) {
            primarySurface.normal = -primarySurface.normal;
        }
    }
    geometry = float4(encodeOctahedral(primarySurface.normal),
                      primaryHit.distance, float(classification));

    bool guideProjectionValid = projectDenoiserGuides(
        hitPosition, uniforms, guideDepth, guideMotion);
    bool dynamicSurface =
        (primarySurface.flags & kRTInstanceFlagDynamicVertexBuffer) != 0u;
    if (dynamicSurface) {
        // Dynamic vertices currently have no previous-object transform. Mark
        // them reactive and avoid feeding camera-only motion as object motion.
        guideMotion = float2(0.0f);
    }
    guideWorldNormal = sceneNormalToWorld(primarySurface.normal, uniforms);
    float wetness = !translucent && !dynamicSurface
        ? terrainWetness(hitPosition, guideWorldNormal, uniforms) : 0.0f;
    if (wetness > 0.0f) {
        material.rgb = powr(max(material.rgb, 0.0f),
                            float3(1.0f + wetness * 0.22f));
        material.rgb *= 1.0f - wetness * 0.06f;
    }
    float guideCosine = clamp(-dot(sceneDirection, primarySurface.normal),
                              0.0f, 1.0f);
    float guideIndexOfRefraction = waterLike ? 1.333f
        : (translucent ? 1.52f : 1.50f);
    float guideF0 = (guideIndexOfRefraction - 1.0f) /
                    (guideIndexOfRefraction + 1.0f);
    guideF0 *= guideF0;
    guideF0 = mix(guideF0, 0.065f, wetness);
    float guideFresnel = guideF0 + (1.0f - guideF0) *
        powr(1.0f - guideCosine, 5.0f);
    // Dry terrain is Lambertian in the current integrator. Advertising a
    // dielectric lobe that is not present in the noisy signal makes the
    // denoiser separate the wrong components.
    guideSpecularAlbedo = translucent
        ? float3(guideFresnel)
        : float3(guideFresnel * wetness);
    guideDiffuseAlbedo = material.rgb *
        max(float3(1.0f) - guideSpecularAlbedo, 0.0f) *
        (translucent ? 0.35f : 1.0f);
    bool alphaTested =
        (primarySurface.flags & kRTInstanceFlagAlphaTest) != 0u;
    guideRoughness = waterLike ? 0.06f
        : (translucent ? 0.12f
           : (dynamicSurface ? 0.62f : (alphaTested ? 0.86f : 0.78f)));
    guideRoughness = mix(guideRoughness, 0.20f, wetness * 0.92f);
    guideReactive = !guideProjectionValid ? 1.0f
        : (dynamicSurface ? 0.50f
           : (waterLike ? 0.38f
              : (translucent ? 0.45f : (alphaTested ? 0.10f : 0.0f))));

    if (translucent) {
        float indexOfRefraction = waterLike ? 1.333f : 1.52f;
        bool entering = waterLike
            ? uniforms.worldCamera.w <= 0.5f
            : geometricFrontFace;
        float eta = entering ? 1.0f / indexOfRefraction : indexOfRefraction;
        float cosine = clamp(-dot(sceneDirection, primarySurface.normal),
                             0.0f, 1.0f);
        float f0 = (indexOfRefraction - 1.0f) /
                   (indexOfRefraction + 1.0f);
        f0 *= f0;
        float fresnel = f0 + (1.0f - f0) * powr(1.0f - cosine, 5.0f);
        float secondaryDistance = uniforms.traceParameters.y;

        float3 reflectionDirection = safeNormalize(
            reflect(sceneDirection, primarySurface.normal),
            -sceneDirection);
        TracedRadiance reflection = traceMaterialRadiance(
            hitPosition + primarySurface.normal * (minimumDistance * 2.0f),
            reflectionDirection, secondaryDistance, rngState,
            accelerationStructure, intersectionFunctionTable,
            vertices, dynamicVertices, instances, localLights,
            uniforms, materialTable, materialAvailable, true, true);

        float3 refractionDirection = refract(
            sceneDirection, primarySurface.normal, eta);
        TracedRadiance refraction = reflection;
        float refractionLengthSquared = dot(refractionDirection,
                                             refractionDirection);
        if (all(isfinite(refractionDirection)) &&
            refractionLengthSquared > 1.0e-8f) {
            refractionDirection *= rsqrt(refractionLengthSquared);
            refraction = traceMaterialRadiance(
                hitPosition - primarySurface.normal * (minimumDistance * 2.0f),
                refractionDirection, secondaryDistance, rngState,
                accelerationStructure, intersectionFunctionTable,
                vertices, dynamicVertices, instances, localLights,
                uniforms, materialTable, materialAvailable, true, true);
        } else {
            fresnel = 1.0f;
        }

        float thickness = min(max(refraction.distance, 0.0f),
                              waterLike ? 32.0f : 12.0f);
        float3 absorptionCoefficient = waterLike
            ? float3(0.115f, 0.038f, 0.014f)
            : -log(clamp(material.rgb, 0.08f, 1.0f)) * 0.055f;
        float3 absorption = exp(-absorptionCoefficient * thickness);
        float3 transmissionTint = mix(float3(1.0f),
                                      max(material.rgb, 0.02f),
                                      waterLike ? 0.42f : 0.68f);
        LocalLighting local = traceLocalLighting(
            hitPosition, primarySurface.normal, rngState,
            accelerationStructure, intersectionFunctionTable,
            vertices, dynamicVertices, instances, localLights,
            uniforms.geometryCounts.w,
            uniforms, materialTable, materialAvailable);
        finalRadiance = reflection.radiance * fresnel +
            refraction.radiance * transmissionTint * absorption *
                (1.0f - fresnel) +
            local.diffuse * (0.08f + fresnel * 0.18f) + local.emissive;
    } else {
        float3 celestial = traceCelestialLighting(
            hitPosition, primarySurface.normal,
            temporalLowDiscrepancySample(
                pixel, outputSize.x, uniforms.frameData.x, 0u),
            accelerationStructure, intersectionFunctionTable,
            vertices, dynamicVertices, instances, uniforms,
            materialTable, materialAvailable);
        LocalLighting local = traceLocalLighting(
            hitPosition, primarySurface.normal, rngState,
            accelerationStructure, intersectionFunctionTable,
            vertices, dynamicVertices, instances, localLights,
            uniforms.geometryCounts.w,
            uniforms, materialTable, materialAvailable);
        float3 bounceDirection = cosineHemisphere(
            primarySurface.normal,
            temporalLowDiscrepancySample(
                pixel, outputSize.x, uniforms.frameData.x, 1u));
        TracedRadiance bounce = traceMaterialRadiance(
            hitPosition + primarySurface.normal * (minimumDistance * 2.0f),
            bounceDirection, uniforms.traceParameters.y, rngState,
            accelerationStructure, intersectionFunctionTable,
            vertices, dynamicVertices, instances, localLights,
            uniforms, materialTable, materialAvailable, false, false);
        float3 direct = material.rgb *
            (celestial * 1.02f + local.diffuse);
        // The cosine-weighted bounce already estimates sky visibility, GI and
        // near-field occlusion. Reusing that same binary sample as AO and then
        // multiplying sky by it again crushed recesses to roughly 3% energy.
        // A small stable term approximates untraced higher-order scattering.
        float3 multipleScattering =
            max(uniforms.skyRadiance.xyz, 0.0f) * 0.035f;
        float3 indirect = material.rgb *
            (bounce.radiance * 0.92f + multipleScattering);
        float3 reflectedDirection = safeNormalize(
            reflect(sceneDirection, primarySurface.normal), -sceneDirection);
        float viewCosine = clamp(-dot(sceneDirection, primarySurface.normal),
                                 0.0f, 1.0f);
        float wetFresnel = 0.02f + 0.98f *
            powr(1.0f - viewCosine, 5.0f);
        float3 wetReflection = evaluateSky(
            reflectedDirection, uniforms, true, true) *
            (wetness * wetFresnel * 0.72f);
        finalRadiance = direct + indirect * (1.0f - wetness * 0.32f) +
            wetReflection + local.emissive;
    }

    finalRadiance = uniforms.worldCamera.w > 0.0f
        ? applyUnderwaterMedium(max(finalRadiance, 0.0f), primaryHit.distance,
                               sceneDirection, uniforms)
        : applyAerialPerspective(max(finalRadiance, 0.0f), primaryHit.distance,
                                 sceneDirection, uniforms);
    if (!all(isfinite(finalRadiance))) {
        finalRadiance = rasterLinear;
    }
    rawLighting.write(half4(half3(min(finalRadiance, float3(65504.0f))), 1.0h),
                      pixel);
    currentGeometry.write(half4(geometry), pixel);
    writeDenoiserGuides(
        denoiserDepth, denoiserMotion, denoiserNormal,
        denoiserDiffuseAlbedo, denoiserSpecularAlbedo,
        denoiserRoughness, denoiserReactiveMask, pixel,
        guideDepth, guideMotion, guideWorldNormal,
        guideDiffuseAlbedo, guideSpecularAlbedo,
        guideRoughness, guideReactive);
}

float3 rgbToYCoCg(float3 color) {
    return float3(color.r * 0.25f + color.g * 0.50f + color.b * 0.25f,
                  color.r * 0.50f - color.b * 0.50f,
                 -color.r * 0.25f + color.g * 0.50f - color.b * 0.25f);
}

float3 yCoCgToRgb(float3 color) {
    return float3(color.x + color.y - color.z,
                  color.x + color.z,
                  color.x - color.y - color.z);
}

kernel void temporalResolve(
    constant RayTraceUniforms &uniforms [[buffer(0)]],
    texture2d<float, access::read> rawLighting [[texture(0)]],
    texture2d<float, access::read> currentGeometry [[texture(1)]],
    texture2d<float, access::read> previousRadiance [[texture(2)]],
    texture2d<float, access::read> previousGeometry [[texture(3)]],
    texture2d<half, access::write> nextHistoryRadiance [[texture(4)]],
    texture2d<half, access::write> nextHistoryGeometry [[texture(5)]],
    uint2 pixel [[thread_position_in_grid]]) {
    uint2 imageSize = uint2(nextHistoryRadiance.get_width(),
                            nextHistoryRadiance.get_height());
    if (any(pixel >= imageSize)) {
        return;
    }
    float4 raw = rawLighting.read(pixel);
    float4 geometry = currentGeometry.read(pixel);
    float3 current = all(isfinite(raw.rgb)) ? max(raw.rgb, 0.0f)
                                             : float3(0.0f);
    uint currentClass = uint(clamp(round(geometry.a), 0.0f, 3.0f));

    float3 neighborhoodMinimum = float3(65504.0f);
    float3 neighborhoodMaximum = float3(-65504.0f);
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            int2 coordinate = clamp(int2(pixel) + int2(x, y),
                                    int2(0), int2(imageSize) - 1);
            float3 sampleColor = max(rawLighting.read(uint2(coordinate)).rgb,
                                     0.0f);
            float3 encoded = rgbToYCoCg(sampleColor);
            neighborhoodMinimum = min(neighborhoodMinimum, encoded);
            neighborhoodMaximum = max(neighborhoodMaximum, encoded);
        }
    }

    bool historyValid = uniforms.frameData.y != 0u &&
        uniforms.previousSceneCameraAndHistory.w > 0.5f;
    float3 sceneOrigin;
    float3 sceneDirection;
    historyValid = historyValid && reconstructSceneRay(
        pixel, imageSize, uniforms, sceneOrigin, sceneDirection);
    float3 scenePosition = currentClass == 0u
        ? sceneOrigin + sceneDirection * uniforms.traceParameters.x
        : sceneOrigin + sceneDirection * max(geometry.b, 0.0f);
    float4 previousClip = uniforms.sceneToPreviousClip *
        float4(scenePosition, 1.0f);
    historyValid = historyValid && all(isfinite(previousClip)) &&
        abs(previousClip.w) > 1.0e-8f;
    float2 previousUv = float2(-1.0f);
    if (historyValid) {
        float3 previousNdc = previousClip.xyz / previousClip.w;
        previousUv = float2(previousNdc.x * 0.5f + 0.5f,
                            0.5f - previousNdc.y * 0.5f);
        historyValid = all(previousUv >= 0.0f) && all(previousUv < 1.0f) &&
            previousNdc.z >= -1.1f && previousNdc.z <= 1.1f;
    }

    float4 history = float4(current, 1.0f);
    if (historyValid) {
        uint2 previousSize = uint2(previousRadiance.get_width(),
                                   previousRadiance.get_height());
        int2 previousBase = clamp(
            int2(previousUv * float2(previousSize)), int2(0),
            int2(previousSize) - 1);
        float3 currentNormal = decodeOctahedral(geometry.rg);
        float expectedPreviousDistance = distance(
            scenePosition, uniforms.previousSceneCameraAndHistory.xyz);
        float distanceTolerance = max(
            0.18f, expectedPreviousDistance * 0.045f);
        float normalThreshold = currentClass == 1u
            ? 0.84f
            : (currentClass == 2u ? 0.87f : 0.90f);
        float bestScore = 1.0e30f;
        bool foundHistory = false;
        uint2 bestHistoryPixel = uint2(previousBase);
        int searchRadius = currentClass == 0u ? 0 : 1;
        for (int y = -searchRadius; y <= searchRadius; ++y) {
            for (int x = -searchRadius; x <= searchRadius; ++x) {
                int2 candidateCoordinate = clamp(
                    previousBase + int2(x, y), int2(0),
                    int2(previousSize) - 1);
                uint2 candidatePixel = uint2(candidateCoordinate);
                float4 candidateGeometry = previousGeometry.read(candidatePixel);
                uint candidateClass = uint(clamp(
                    round(candidateGeometry.a), 0.0f, 3.0f));
                if (candidateClass != currentClass) {
                    continue;
                }
                float score = float(x * x + y * y) * 0.025f;
                if (currentClass != 0u) {
                    float3 candidateNormal = decodeOctahedral(
                        candidateGeometry.rg);
                    float normalAgreement = dot(currentNormal, candidateNormal);
                    float distanceError = abs(
                        candidateGeometry.b - expectedPreviousDistance);
                    if (normalAgreement < normalThreshold ||
                        distanceError > distanceTolerance) {
                        continue;
                    }
                    score += distanceError / distanceTolerance +
                        (1.0f - normalAgreement) * 2.0f;
                }
                if (score < bestScore) {
                    bestScore = score;
                    bestHistoryPixel = candidatePixel;
                    foundHistory = true;
                }
            }
        }
        if (foundHistory) {
            history = previousRadiance.read(bestHistoryPixel);
        }
        historyValid = foundHistory && all(isfinite(history)) &&
            history.a >= 1.0f;
    }

    float currentWeight = 1.0f;
    float historyLength = 1.0f;
    if (historyValid) {
        float3 clippedHistory = clamp(rgbToYCoCg(max(history.rgb, 0.0f)),
                                      neighborhoodMinimum,
                                      neighborhoodMaximum);
        history.rgb = max(yCoCgToRgb(clippedHistory), 0.0f);
        currentWeight = max(1.0f / (history.a + 1.0f), 0.05f);
        if (currentClass == 2u) {
            currentWeight = max(currentWeight, 0.20f);
        } else if (currentClass == 3u) {
            currentWeight = max(currentWeight, 0.34f);
        } else if (currentClass == 0u) {
            currentWeight = max(currentWeight, 0.06f);
        }
        historyLength = min(history.a + 1.0f, 40.0f);
    }
    float3 resolved = mix(history.rgb, current, currentWeight);
    nextHistoryRadiance.write(
        half4(half3(min(max(resolved, 0.0f), float3(65504.0f))),
              half(historyLength)), pixel);
    nextHistoryGeometry.write(half4(geometry), pixel);
}

kernel void spatialFilter(
    constant int2 &axis [[buffer(0)]],
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> currentGeometry [[texture(1)]],
    texture2d<half, access::write> destination [[texture(2)]],
    uint2 pixel [[thread_position_in_grid]]) {
    uint2 imageSize = uint2(destination.get_width(), destination.get_height());
    if (any(pixel >= imageSize)) {
        return;
    }
    constexpr float kernelWeights[5] = {
        0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f
    };
    int2 filterAxis = any(axis != int2(0)) ? axis : int2(1, 0);
    float4 centerGeometry = currentGeometry.read(pixel);
    uint centerClass = uint(clamp(round(centerGeometry.a), 0.0f, 3.0f));
    float3 centerNormal = decodeOctahedral(centerGeometry.rg);
    float4 center = source.read(pixel);
    float3 centerColor = max(center.rgb, 0.0f);
    float3 centerEncoded = rgbToYCoCg(centerColor);
    float historyStability = clamp((center.a - 1.0f) / 15.0f, 0.0f, 1.0f);
    float3 accumulated = float3(0.0f);
    float weightSum = 0.0f;
    for (int tap = -2; tap <= 2; ++tap) {
        int2 coordinate = clamp(int2(pixel) + filterAxis * tap,
                                int2(0), int2(imageSize) - 1);
        float4 sampleGeometry = currentGeometry.read(uint2(coordinate));
        uint sampleClass = uint(clamp(round(sampleGeometry.a), 0.0f, 3.0f));
        if (sampleClass != centerClass) {
            continue;
        }
        float3 sampleColor = max(source.read(uint2(coordinate)).rgb, 0.0f);
        float weight = kernelWeights[tap + 2];
        if (tap != 0) {
            weight *= mix(1.0f, 0.55f, historyStability);
        }
        if (centerClass != 0u) {
            float3 sampleNormal = decodeOctahedral(sampleGeometry.rg);
            float normalPower = centerClass == 1u
                ? mix(18.0f, 28.0f, historyStability)
                : mix(36.0f, 54.0f, historyStability);
            weight *= powr(max(dot(centerNormal, sampleNormal), 0.0f),
                           normalPower);
            float distanceScale = max(
                mix(0.12f, 0.08f, historyStability),
                centerGeometry.b * mix(0.025f, 0.016f, historyStability));
            weight *= exp(-abs(sampleGeometry.b - centerGeometry.b) /
                          distanceScale);
        }
        float2 chromaDelta = rgbToYCoCg(sampleColor).yz - centerEncoded.yz;
        float chromaScale = max(0.08f, centerEncoded.x * 0.30f);
        weight *= exp(-length(chromaDelta) / chromaScale);
        accumulated += sampleColor * weight;
        weightSum += weight;
    }
    float3 filtered = weightSum > 1.0e-5f
        ? accumulated / weightSum
        : centerColor;
    destination.write(half4(half3(min(filtered, float3(65504.0f))),
                                half(center.a)), pixel);
}

vertex FullscreenVertexOutput fullscreenTriangle(uint vertexId [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f)
    };
    FullscreenVertexOutput output;
    output.position = float4(positions[vertexId], 0.0f, 1.0f);
    return output;
}

float3 neutralDisplayCurve(float3 color) {
    color = max(color, 0.0f);
    float3 mapped = color * (1.65f * color + 0.12f) /
        (color * (1.55f * color + 0.65f) + 0.14f);
    constexpr float whitePoint = 16.0f;
    constexpr float whiteScale =
        (whitePoint * (1.65f * whitePoint + 0.12f)) /
        (whitePoint * (1.55f * whitePoint + 0.65f) + 0.14f);
    return clamp(mapped / whiteScale, 0.0f, 1.0f);
}

fragment half4 compositeRayTracedLighting(
    FullscreenVertexOutput input [[stage_in]],
    texture2d<float> worldColor [[texture(0)]],
    texture2d<half> filteredLighting [[texture(1)]],
    constant float4 &displayParameters [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear);
    uint2 colorSize = uint2(worldColor.get_width(), worldColor.get_height());
    uint2 colorPixel = min(uint2(input.position.xy), colorSize - 1u);
    float2 uv = (float2(colorPixel) + 0.5f) / float2(colorSize);
    float3 fallback = srgbToLinear(
        clamp(worldColor.read(colorPixel).rgb, 0.0f, 1.0f));
    float3 hdr = float3(filteredLighting.sample(linearSampler, uv).rgb);
    if (!all(isfinite(hdr))) {
        hdr = fallback;
    }

    float2 texel = 1.0f / float2(filteredLighting.get_width(),
                                 filteredLighting.get_height());
    float day = clamp(displayParameters.z, 0.0f, 1.0f);
    float bloomThreshold = mix(0.75f, 1.25f, day);
    float3 bloom = float3(0.0f);
    bloom += max(float3(filteredLighting.sample(
        linearSampler, uv + float2(texel.x, 0.0f)).rgb) - bloomThreshold, 0.0f);
    bloom += max(float3(filteredLighting.sample(
        linearSampler, uv - float2(texel.x, 0.0f)).rgb) - bloomThreshold, 0.0f);
    bloom += max(float3(filteredLighting.sample(
        linearSampler, uv + float2(0.0f, texel.y)).rgb) - bloomThreshold, 0.0f);
    bloom += max(float3(filteredLighting.sample(
        linearSampler, uv - float2(0.0f, texel.y)).rgb) - bloomThreshold, 0.0f);
    bloom *= 0.25f * max(displayParameters.y, 0.0f);

    float exposure = max(displayParameters.x, 0.001f) * mix(1.06f, 1.00f, day);
    float3 balancedHdr = (hdr + bloom) * exposure;
    float balancedLuminance = luminance(balancedHdr);
    float highlightCompression = smoothstep(
        0.70f, 2.0f, maxChannel(balancedHdr));
    float saturation = mix(0.95f, 0.88f, highlightCompression);
    balancedHdr = mix(float3(balancedLuminance), balancedHdr, saturation);
    float3 displayLinear = neutralDisplayCurve(balancedHdr);
    float3 displaySrgb = linearToSrgb(displayLinear);
    return half4(half3(clamp(displaySrgb, 0.0f, 1.0f)), 1.0h);
}
