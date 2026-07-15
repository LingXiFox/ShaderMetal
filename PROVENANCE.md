# Provenance And Modifications

This document records the upstream implementation references used by ShaderMetal and the
material changes made for this project. It complements `THIRD_PARTY_NOTICES.md`.

## Pinned Upstream Revisions

- Radiance: https://github.com/Minecraft-Radiance/Radiance/tree/414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8
- MCVR: https://github.com/Minecraft-Radiance/MCVR/tree/9905c81b1999f5845bf66d13501d371c16adf561

## Adapted Contracts And Integration Patterns

The following ShaderMetal areas borrow or adapt the interface shape, interception points, and
renderer-replacement flow of Radiance. They were renamed, updated for Minecraft 1.21.4 mappings,
and modified for ShaderMetal during July 2026.

| ShaderMetal | Upstream reference | Relationship |
| --- | --- | --- |
| `src/client/java/com/example/shadermetal/proxy/` | [`com/radiance/client/proxy/`](https://github.com/Minecraft-Radiance/Radiance/tree/414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8/src/main/java/com/radiance/client/proxy) | JNI proxy contract and responsibility split adapted for Metal |
| `src/client/java/com/example/shadermetal/mixin/` | [`com/radiance/mixins/vulkan_render_integration/`](https://github.com/Minecraft-Radiance/Radiance/tree/414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8/src/main/java/com/radiance/mixins/vulkan_render_integration) | Render interception points and lifecycle sequencing adapted for ShaderMetal |
| `src/client/java/com/example/shadermetal/render/` | [`com/radiance/client/shader/`](https://github.com/Minecraft-Radiance/Radiance/tree/414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8/src/main/java/com/radiance/client/shader) and [`client/texture/`](https://github.com/Minecraft-Radiance/Radiance/tree/414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8/src/main/java/com/radiance/client/texture) | Shader, texture, and resource-transfer boundaries informed by Radiance |
| `native/src/jni/` | [`MCVR/src/core/middleware/`](https://github.com/Minecraft-Radiance/MCVR/tree/9905c81b1999f5845bf66d13501d371c16adf561/src/core/middleware) | Native JNI boundary follows the corresponding proxy surface; bodies are reimplemented in Objective-C++ |

## ShaderMetal Metal Implementation

The native implementation under `native/src/core/`, `native/src/render/`, `native/src/resource/`,
`native/src/raytracing/`, and `native/shaders/` replaces the Vulkan implementation with Apple
Metal and Objective-C++. ShaderMetal-specific work includes:

- `CAMetalLayer` and AppKit/GLFW window integration on macOS.
- GLSL to SPIR-V to MSL translation and Metal pipeline/resource management.
- Metal bottom-level and top-level acceleration structures, refit/rebuild scheduling, and native
  ray intersections.
- Metal ray-traced lighting, emissive/local lights, terrain/entity proxies, water/transparency,
  temporal history, and MetalFX denoising/upscaling integration.
- Apple Silicon build, Game Mode development launcher, Metal HUD, and runtime cleanup tooling.

No Radiance or MCVR source tree is vendored in this repository. The pinned repositories above
remain the authoritative source for their code and history. If future changes copy an upstream
file or a third-party exception-covered component, that file must retain its original notices and
license in addition to being recorded here.
