# ShaderMetal

ShaderMetal is a client-only Fabric mod that replaces Minecraft presentation with a native
Metal renderer on Apple Silicon. Radiance is a behavioral reference; ShaderMetal's Java,
Mixin, JNI, and Objective-C++ code are independently implemented.

## Requirements

- macOS 13.0 or newer on Apple Silicon
- JDK 21
- Xcode Command Line Tools with the macOS SDK
- CMake 3.20 or newer
- Git submodules initialized from the workspace root

```sh
git submodule update --init
```

## Build And Run

All Gradle invocations go through a guard that selects JDK 21, disables persistent daemons,
stops project Java processes on exit, and verifies cleanup.

```sh
./script/build_and_run.sh build
./script/build_and_run.sh
```

Generate the authoritative JNI headers and verify the dylib exports with:

```sh
./script/build_and_run.sh headers
./script/check_jni_contract.sh
```

## Stage A

Stage A creates an independent `CAMetalLayer` view above GLFW's content view, suppresses
OpenGL buffer presentation, and submits a black Metal clear every frame. Resource translation,
raster draw replacement, ray tracing, and post-processing belong to later stages.

## License

ShaderMetal's project-owned sources use CC0-1.0. Third-party submodules retain their own
licenses.
