# ShaderMetal

ShaderMetal is an experimental client-side Fabric mod that replaces Minecraft's OpenGL
presentation path with a native Apple Metal renderer on Apple Silicon.

The implementation is under active development. It is currently a research preview, not a
drop-in production renderer, and worlds should be backed up before testing.

## Status

- Stage A: native Metal frame foundation complete.
- Stage B: Metal rasterization path complete.
- Stage C: Apple Metal ray tracing integration in progress. The current path builds native
  acceleration structures, performs ray intersections through Metal, and uses MetalFX temporal
  denoising/upscaling where supported. Visual stability and performance tuning are ongoing.

The source project is in [`shader-metal-template-1.21.4`](shader-metal-template-1.21.4/).

## Requirements

- Minecraft Java Edition 1.21.4
- Fabric Loader 0.19.2 or newer and Fabric API
- Apple Silicon Mac with a Metal device that reports ray-tracing support
- Current development target: macOS 26 or newer
- JDK 21, CMake 3.20 or newer, `xxd`, and Xcode Command Line Tools

Current testing is limited to an M5 Mac on macOS 27 beta. Other Macs and mod combinations are
unverified.

## Build

```sh
git clone --recurse-submodules https://github.com/LingXiFox/ShaderMetal.git
cd ShaderMetal/shader-metal-template-1.21.4
./script/gradle_task.sh build
```

The mod JAR is written to `build/libs/`. All local Gradle invocations should go through
`script/gradle_task.sh`; it disables persistent daemons and cleans project Java/game processes
when the task exits.

To start the development client:

```sh
./script/gradle_task.sh runClient
```

## Known Limitations

- Stage C still has visible ray-tracing noise, shadow/material artifacts, and frame-time spikes.
- Geometry updates, water/transparency history, dynamic entities, and some UI/input paths remain
  under active repair.
- MetalFX frame interpolation is not implemented.
- The current renderer is hybrid: Metal rasterization supplies primary visibility and fallback
  data while Metal hardware ray tracing computes experimental lighting and shadows.
- There are no stable release binaries, compatibility guarantees, or production-world safety
  guarantees yet.

## Radiance Attribution

ShaderMetal borrows the renderer-replacement approach and the Java/Mixin/JNI proxy-contract
design from [Minecraft-Radiance/Radiance](https://github.com/Minecraft-Radiance/Radiance).
Radiance and its native [MCVR](https://github.com/Minecraft-Radiance/MCVR) backend are the
architectural references; ShaderMetal reimplements the native renderer for Apple Metal,
Objective-C++, Apple ray-tracing acceleration structures, and MetalFX.

ShaderMetal is not affiliated with or endorsed by the Radiance project, Mojang Studios,
Microsoft, or Apple. Detailed provenance and modification notes are recorded in
[`PROVENANCE.md`](PROVENANCE.md) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## License

Copyright (C) 2026 LingXiFox for ShaderMetal modifications and the original Metal implementation.

ShaderMetal's project-owned source code is distributed under the GNU General Public License
version 3 only (`GPL-3.0-only`). Third-party submodules and dependencies retain their respective
licenses. See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
