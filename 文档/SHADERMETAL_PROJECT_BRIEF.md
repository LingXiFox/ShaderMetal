# ShaderMetal 项目书

> **给执行 agent（Codex / 多 subagent 编排）的构建契约。**
> 目标产物：**ShaderMetal —— 一个独立的 macOS（Apple Silicon）Metal 硬件光追光影 mod。**
> Radiance 是**参考实现**，不是移植对象。

---

## 0. 定位

**要造的东西：ShaderMetal。** 一个自成一体的 Fabric 光影 mod：Java/Mixin 拦截 Minecraft 的渲染调用，转发给一个用 **Metal** 写的 native 后端；最终画面 100% 由 Metal 生成，Minecraft 的 OpenGL 一帧都不出图。

**Radiance 的角色：参考。** 它是一个已经跑通的同类 mod（Vulkan 后端，不支持 macOS）。我们从它身上**借三样东西**：
1. JNI 接口契约的形状（native 方法有哪些、签名长什么样）；
2. Mixin 拦截 MC 渲染时序的做法；
3. 数据边界（每帧能拿到什么、顶点/uniform 布局）。

除此之外，ShaderMetal 是自己的项目、自己的代码、自己的身份。**凡是 Radiance 的实现细节，都是"可参考"，不是"必须照搬"。** license 允许时可以复用其 Java，但产出的是 ShaderMetal 的代码。

---

## 1. 架构决策

**全量替换（Metal 完整重写 native 后端），不是叠滤镜。**

| 备选 | 结论 | 原因 |
|---|---|---|
| 全量替换（本方案） | ✅ | 画面与光追正确性最高；能拿到 GBuffer/几何/材质，光追不受限 |
| IOSurface 叠加后处理 | ❌ | 只拿到最终帧，等于叠滤镜，光追质量天花板低 |

**边界：** Java/Mixin 层轻量（拦截 + 转发，参考 Radiance）；native 层是全新 Metal 实现，本项目 ~95% 工作量在这里。

---

## 2. 环境与技术栈

| 项 | 值 | 说明 |
|---|---|---|
| 平台 | macOS 13.0+ / arm64 | Metal 3 + 硬件光追下限 |
| 硬件 | Apple M3+（开发机 M5） | M3 起才有硬件 RT core |
| **MC 版本** | **1.21.4** | **刻意对齐 Radiance 的版本**，使参考契约能一一对应，减少签名/时序差异 |
| Fabric | Loader 0.19.2 · API 0.119.4+1.21.4 | 与 Radiance 参考一致 |
| Mod ID / 包名 | `shadermetal` / `com.example.shadermetal` | |
| 产物 | `libshadermetal.dylib` | 打进 jar，运行时 `System.load` |
| Metal 绑定 | Objective-C++（.mm）为主 | 需碰 AppKit（NSWindow/NSView/CAMetalLayer），见 §9 |
| 着色器工具链 | glslang + SPIRV-Cross | GLSL 460 → SPIRV → MSL |
| 超采样 | MetalFX Temporal | |
| 构建 | CMake 3.20+ + Xcode CLT | |

**第三方依赖：**

| 依赖 | 版本 | 获取 |
|---|---|---|
| SPIRV-Cross | main | `git submodule add https://github.com/KhronosGroup/SPIRV-Cross` |
| glslang | main | `git submodule add https://github.com/KhronosGroup/glslang` |
| metal-cpp | WWDC23+ | 可选，见 §9 |
| FidelityFX Denoiser | 最新 | 可选，降噪参考 |

---

## 3. 仓库结构

```
shadermetal/
├── src/client/java/com/example/shadermetal/
│   ├── ShaderMetalClient.java        # 客户端入口（OS 检测：mac → load dylib）
│   ├── proxy/                        # JNI 接口类（契约参考 Radiance，实现是自己的）
│   │   ├── RendererProxy.java  · BufferProxy.java  · TextureProxy.java
│   │   ├── ShaderProxy.java    · DrawCommandProxy.java
│   │   ├── PipelineStateProxy.java · WindowProxy.java · ChunkProxy.java
│   └── mixin/                        # 拦截 MC 渲染（做法参考 Radiance）
├── src/main/resources/
│   ├── fabric.mod.json · shadermetal.mixins.json · shadermetal.accesswidener
└── native/
    ├── CMakeLists.txt
    ├── include/                      # javac -h 生成的头文件 = 契约唯一权威
    ├── third_party/                  # SPIRV-Cross / glslang / (metal-cpp)
    ├── shaders/                      # *.metal
    └── src/
        ├── core/       MetalDevice · FrameContext · ShaderCompiler
        ├── resource/   BufferManager · TextureManager · SamplerCache · PipelineCache
        ├── render/     RasterPass · PipelineStateTracker
        ├── raytracing/ AccelStructManager · RayTracePass
        ├── postprocess/ DenoisePass · MetalFXUpscaler · TonemapPass
        └── jni/        每个 Proxy 一个 .mm，JNI 入口
```

---

## 4. 工程约束（Engineering Invariants）

这些是 Metal-on-GLFW + 硬件光追的正确写法，带一句为什么。任何阶段都得守住。

**帧循环 / 窗口**
- `nextDrawable` 只在渲染线程取，不在主线程 —— 主线程会与 UI 事件循环争用、易死锁。
- Metal layer 作为**独立 NSView 子视图**叠加到 GLFW contentView **之上**（`addSubview: positioned:NSWindowAbove`），**不替换** contentView —— 避免与 GLFW 的 GL surface 争用。
- `presentDrawable:` 在 `commit` **之前** —— present 必须先编码进 command buffer 再提交。
- 初始 `drawableSize` 用 **1280×720**，之后按 resize 放大 —— 首次直接分配 4K drawable 易失败/卡顿。
- `allowsNextDrawableTimeout = YES`；`maximumDrawableCount = 3`；layer 安装 `dispatch_sync(main)` 且只做一次。

**光追**
- 求交用 `intersector<instancing, triangle_data>` —— Metal 硬件 RT 推荐路径，配合 instancing 拿 per-instance 数据。
- 随机数用 **PCG** —— 低相关性，避免采样出条带。
- 法线索引 `user_instance_id + primitive_id * 3u` —— BLAS 内三角形顺序叠加实例偏移共同定位法线。
- 太阳方向从 `CameraData.sunDirection` uniform 读，不写死。

**MetalFX**
- 相机移动判断只看 XZ 平面（`abs(dx)+abs(dz) > 0.05` 则 `reset=YES`），忽略 Y —— 竖直抖动不该清空时间累积历史。

**Pipeline（Metal 特有）**
- `MTLRenderPipelineState` 编译期固定不可变，而 MC 大量动态切 blend/depth/stencil。
  → 所有 `set*` 只更新 `PipelineStateTracker`；`draw()` 时用 `(shaderId + 状态 key)` 去 `PipelineCache` 查/建。

**顶点布局假设（阶段 C 动手前对 Radiance 参考核对一遍）**
- stride 32 bytes：offset 0 = `float3 position`；offset 28 = `byte4 normal`（解包 `value/127.0`）。属假设，非既定事实。

---

## 5. JNI 接口契约（~54 个方法）

> **唯一权威 = ShaderMetal 自己 `javac -h` 生成的 `native/include/*.h`。**
> 契约形状**镜像自 Radiance 参考**；下表是地图，写实现以生成的头文件签名为准。

- **RendererProxy（帧循环，~20）**：`initFolderPath` · `initRenderer(String[],long)` · `maxSupportedTextureSize` · `acquireContext`（→begin）· `submitCommand` · `present`（→submit）· `fuseWorld` · `postBlur` · `close` · `shouldRenderWorld` · `takeScreenshot` · `updateWorldUniform/SkyUniform/OverlayPostUniform`（memcpy）· `setCameraPos` · `setClear{Color,Depth,Stencil}` · `vkCmdClearEntire{Color,DepthStencil}Attachment`
- **BufferProxy（~6）**：`allocateBuffer`→int · `initializeBuffer(id,size,usage)` · `queueUpload(ptr,dstId)` · `performQueuedUpload` · `buildIndexBuffer(...)` · `updateMapping(long)`
- **DrawCommandProxy（1）**：`draw(vertexId, indexId, shaderId, indexCount, instanceCount, firstIndex, firstVertex)`
- **PipelineStateProxy（~27，全部只更新 Tracker）**：blend/logicop 7 个 · depth&stencil 若干 · raster（cull/frontface/polygon/viewport/scissor/lineWidth）· `onFramebufferSizeChanged`
- **ChunkProxy（~6）**：`initNative` · `isChunkReady`→bool · `build` · `invalidateSingle` · `relocateSingle` · `updateSectionPosNative`
- **ShaderProxy（1）**：`registerShader(key, vertexFormatType, vertexSrc, fragmentSrc, uniformData)`→int
- **TextureProxy / WindowProxy**：以生成头文件为准。

---

## 6. 执行路线（四大阶段）

> 每个大阶段列出：**目标 → 可并行工作流（分派给 subagent）→ 汇合集成 → 完成判定(DoD)**。
> 大阶段之间**串行**（DoD 未过不进下一段）；大阶段**内部**尽量并行。
> **不准跳过阶段 B（光栅化）直接做 C（光追）**——没有基础画面，光追无从 debug。

### 阶段 A · 地基：能构建、能启动、能出帧
**目标**：`runClient` 不崩，Metal 能 present（黑屏正常）。

并行工作流（A-1 先落地解锁其余）：
- **A-1（前置）** 仓库骨架 + CMake + 两个 submodule + `ShaderMetalClient` 的 OS 检测 + `javac -h` 生成头文件。
- **A-2** 全部 JNI **stub**（返回空/0/-1 + `NSLog`），一个方法都不少。← 依赖 A-1 的头文件
- **A-3** `MetalDevice`（device/queue + §4 的 layer 安装）+ `FrameContext.begin/submit` + `initRenderer`（dlopen GLFW → `glfwGetCocoaWindow` → NSWindow）。

汇合：A-3 接上 `acquireContext/submitCommand/present`。
**DoD**：控制台打印 GPU 名；每帧 present 空 drawable，黑屏但帧计数在走、不死锁。

### 阶段 B · 渲染子系统：跑出正确画面（能玩）★ 首个可玩里程碑
**目标**：光栅化出地形/UI/物品栏，颜色正确，可正常玩。

高度并行——四条流几乎互不依赖，可同时分派：
- **B-1 资源层**：`BufferManager` / `TextureManager` / `SamplerCache`（三者内部可再并行）；`VK_FORMAT_*`→`MTLPixelFormat` 对照表；三个 `update*Uniform` → memcpy。
- **B-2 着色器编译**：`ShaderCompiler.glslToMsl`（glslang→SPIRV→SPIRV-Cross MSL 3.0）。**可脱离 Metal 设备独立单测**（比对输出 MSL 字符串），最先能验证。
- **B-3 管线状态**：`PipelineStateTracker`（承接 27 个 setter）+ `PipelineKey`（`operator===default`）+ `PipelineCache`。
- **B-4 光栅化 draw**：`RasterPass` + `draw()` + bindless 纹理 argument buffer。← 汇合点，依赖 B-1/B-2/B-3

汇合：B-1+B-2+B-3 汇入 B-4，打通 `registerShader` → `draw`。
**DoD**：进世界，几何/UI/颜色正确，可玩（帧率不计）。

### 阶段 C · 硬件光追
**目标**：正确的光追全局光照与阴影。

- **C-1** `AccelStructManager`：per-chunk BLAS（接 ChunkProxy 几何）+ 全局 TLAS（dirty 重建）。
- **C-2** `shaders/RayTrace.metal`：**可与 C-1 并行编写**。
- **C-3** `RayTracePass` 集成（§4 光追约束全部生效）。

**内部串行门（不可并行）**：先做 **AO**（短射线遮挡）验证整条管线通 → 再扩成**完整 GI**（路径追踪，读 `sunDirection`）。
**DoD**：AO 阶段方块缝隙变暗 → GI 阶段出现正确间接光与阴影方向（有噪点可接受）。

### 阶段 D · 画质、后处理与收尾
**目标**：清晰、MetalFX 生效、帧率达 M5 应有水准。

全部相对独立，可并行：
- **D-1** `DenoisePass`（SVGF 简化版；或参考 FidelityFX Denoiser）。
- **D-2** `MetalFXUpscaler`（`MTLFXTemporalScaler`；reset 逻辑见 §4；半分辨率渲染→全分辨率输出）。
- **D-3** `TonemapPass`（移植 tone_mapping compute，纯数学，SPIRV-Cross 基本直转）。
- **D-4** 收尾：`takeScreenshot`（blit→shared buffer→memcpy 回 Java 指针，含/不含 UI 两路）；`onFramebufferSizeChanged`（更新 layer.frame + drawableSize，重建分辨率相关 texture）；Java 枚举 `UpscalerType.METALFX`，GUI 隐藏 macOS 不支持项。

**DoD**：画面清晰无明显噪点，MetalFX 生效，截图/改窗口大小不崩。

---

## 7. 并行编排总览（给 subagent 分派用）

**依赖图（→ 表示"必须先于"）：**
```
A-1 ──► A-2
   └──► A-3 ─────────────────────────────► (阶段A DoD)
                                              │
   A(全过) ──► B-1 ┐                          │
              B-2 ┼──► B-4 ──► (阶段B DoD) ◄──┘
              B-3 ┘
                          │
              B(全过) ──► C-1 ┐
                         C-2 ┼──► C-3 ──[AO→GI 串行门]──► (阶段C DoD)
                             │
              C(全过) ──► D-1 ┐
                         D-2 ┼──► (阶段D DoD)   ← D-1/2/3/4 全并行
                         D-3 ┤
                         D-4 ┘
```

**编排建议：**
- 阶段内的每条流各起一个 subagent；**B、D 两段并行收益最大**，优先铺开。
- **B-2（着色器编译）可最早独立启动**——它连 Metal 设备都不需要，能脱离主线跑单测，让主线在 A 还没完时就先验证工具链。
- 汇合点（B-4、C-3）单独留一个集成 subagent 负责合并 + 跑 `runClient` 冒烟。
- 每条流交付时附：改了哪些文件、接口有无偏离 §5、有无违反 §4。

---

## 8. CMake 骨架

```cmake
cmake_minimum_required(VERSION 3.20)
project(shadermetal LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OSX_ARCHITECTURES "arm64")
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0")

find_package(JNI REQUIRED)
foreach(fw Metal MetalFX Foundation QuartzCore AppKit)
  find_library(${fw}_LIB ${fw} REQUIRED)
endforeach()

add_subdirectory(third_party/SPIRV-Cross)
add_subdirectory(third_party/glslang)

file(GLOB_RECURSE SOURCES "src/*.mm" "src/*.cpp")
add_library(shadermetal SHARED ${SOURCES})
target_include_directories(shadermetal PRIVATE include/ ${JNI_INCLUDE_DIRS})
target_link_libraries(shadermetal PRIVATE
  ${Metal_LIB} ${MetalFX_LIB} ${Foundation_LIB} ${QuartzCore_LIB} ${AppKit_LIB}
  spirv-cross-msl glslang)
set_target_properties(shadermetal PROPERTIES OUTPUT_NAME "shadermetal" SUFFIX ".dylib")
```

---

## 9. 需要拍板的技术决策（遇到先停，不要猜）

1. **Metal 绑定**：建议纯 Objective-C++（.mm）+ ObjC Metal 头文件——必须碰 AppKit（NSWindow/NSView），metal-cpp 覆盖不到窗口层，混用更乱。默认走 .mm；引入 metal-cpp 需明确收益。
2. **Radiance license**：已确认 Radiance 使用 GPL-3.0；ShaderMetal 以 GPL-3.0-only 接力开源，并在 README 与 THIRD_PARTY_NOTICES 中持续保留来源、参考版本和修改说明。
3. **JNI 精确签名**：以本项目 `javac -h` 生成的头文件为准；§5 数量约 54，非精确。
4. **顶点布局（§4 末）**：stride=32 / normal@28 是待核对假设，阶段 C 前对当前 Radiance 版本验证。
5. **bindless 纹理**：GLSL `sampler2D textures[]` 经 SPIRV-Cross 转 argument buffer 后的绑定索引与更新时机需实测。
6. **GL 抑制**：全量替换要求 MC 的 OpenGL 不出图——确认 Mixin 层已负责，ShaderMetal 复制后行为一致。

---

## 10. 给执行 agent 的工作协议

1. 大阶段串行（DoD 未过不进下一段）；大阶段内按 §7 并行分派 subagent。
2. 每条流开始先列**要新建/改的文件清单**，再写码。
3. 每个文件写完暂停，说明写了什么、哪里不确定；不确定就问（尤其 §9）。
4. 汇合点跑一次 `cmake --build` + `runClient` 冒烟，不崩再继续。
5. §4 是红线，违反即错，哪怕"看起来更干净"。
6. 阶段 A 的 stub 覆盖全部方法，一个不少。
7. 记住：**造的是 ShaderMetal，Radiance 只是参考。**

---

## 附：本项目书的来源

合并自三份历史计划并去冲突：主干取全量替换方案；补充其光栅化/光追/后处理技术细节；丢弃 IOSurface 叠加路线（与"全量替换、不叠滤镜"冲突）。
