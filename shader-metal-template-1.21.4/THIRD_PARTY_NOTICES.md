# Third-Party Notices

## Radiance

ShaderMetal borrows and adapts the renderer-replacement architecture, Java/Mixin interception
patterns, and JNI proxy-contract design from the Radiance project:

- Project: Minecraft-Radiance/Radiance
- Source: https://github.com/Minecraft-Radiance/Radiance
- Reference revision: `414d8e330a2fc6cb1e8630cc95f2302b2b97a0e8`
- License: GNU General Public License version 3
- Upstream authors/contributors: see the pinned repository history

ShaderMetal's changes include reimplementing the native Vulkan-oriented rendering design for
Apple Metal and Objective-C++, adding Apple Metal acceleration structures and ray intersections,
MetalFX integration, macOS window/input lifecycle handling, and Apple Silicon-specific build and
runtime support. These changes were made for ShaderMetal during July 2026.

## MCVR

Radiance identifies Minecraft Vulkan Renderer (MCVR) as its native backend. MCVR's JNI/native
boundary informed the corresponding ShaderMetal interface:

- Project: Minecraft-Radiance/MCVR
- Source: https://github.com/Minecraft-Radiance/MCVR
- Reference revision: `9905c81b1999f5845bf66d13501d371c16adf561`
- License: primarily GNU General Public License version 3, with upstream per-file exceptions

MCVR source files are not vendored verbatim by ShaderMetal. Refer to MCVR's `LICENSE.md` for its
complete exception list.

## Khronos Submodules

ShaderMetal uses SPIRV-Cross and glslang as Git submodules. SPIRV-Cross is distributed under
Apache-2.0. Glslang uses the BSD, MIT, Apache-2.0, and other terms enumerated in its `LICENSE.txt`
and `REUSE.toml`. Their source trees retain their original notices, and the relevant license texts
are included with ShaderMetal's binary JAR.
