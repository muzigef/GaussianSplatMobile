<!-- generated-by: gsd-doc-writer -->
# 开发指南

本文面向需要修改 GaussianSplatMobile 的开发者。项目是一个 iOS 18+ 的 SwiftUI + Metal 应用，应用代码与本地 vendored Swift Package 共同构成完整渲染路径。系统数据流和线程模型见 [ARCHITECTURE.md](ARCHITECTURE.md)，构建期配置见 [CONFIGURATION.md](CONFIGURATION.md)。

## 本地开发设置

### 前置条件

- 能解析 `swift-tools-version: 6.1`、带 iOS 18 SDK 的 Xcode。当前工程已在 Xcode 26.0.1、Apple Swift 6.2 下完成命令行构建验证。
- 一台 iOS 18 或更高版本的 iPhone，用于真实性能和 Metal 行为验证。模拟器适合编译与基本界面检查，不应作为帧率结论。
- 如需重新生成样例模型，还需要 `curl`、Python 3、Node.js/npm 和网络连接；普通构建不需要联网。

### 获取与打开工程

当前源码快照不含 Git 元数据，无法从仓库内容核实远程 URL 或默认分支。先在托管平台 fork 项目，再把占位符替换为实际地址：

```bash
git clone <仓库地址>
cd GaussianSplatMobile
open GaussianSplatMobile.xcodeproj
```

工程通过 `GaussianSplatMobile.xcodeproj` 引用本地包 `Vendor/MetalSplatter`，没有需要下载的远程 Swift Package。首次真机运行前，在 Target → Signing & Capabilities 中选择开发团队，并把默认的 `com.example.GaussianSplatMobile` 改为自己的唯一 Bundle Identifier。

当前 Resources build phase 直接引用 `ValidationAssets/drjohnson_full_sh3.ply`。如果获取的源码不带这个约 752 MiB 文件，构建前要么运行 `./Scripts/download_validation_scene.sh`，要么在 Xcode Target → Build Phases → Copy Bundle Resources 中删除它的引用。仅依赖 `ContentView` 的运行时 fallback 不能修复“build phase 引用的源文件已缺失”的构建错误。

共享 Scheme 的 Run 与 Profile 都使用 Release 配置。大型 PLY 在 Debug 下解析明显更慢；开发 UI 时可以使用 Debug 构建，但加载和渲染性能应在 Release 真机包上测量。若要排除调试器开销，安装后停止 Xcode 调试，再从手机主屏幕启动 App。

## 构建命令

| 命令或操作 | 说明 |
| --- | --- |
| `xcodebuild -list -project GaussianSplatMobile.xcodeproj` | 列出工程 target、配置与 scheme；可见 App scheme 以及本地包的 `MetalSplatter`、`PLYIO`、`SplatIO` scheme。 |
| `xcodebuild -project GaussianSplatMobile.xcodeproj -scheme GaussianSplatMobile -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/GaussianSplatMobile-DerivedData CODE_SIGNING_ALLOWED=NO build` | 无签名编译 App 与全部本地包依赖。本命令已在当前源码上执行并得到 `BUILD SUCCEEDED`。 |
| Xcode 中选择 `GaussianSplatMobile` scheme 后按 `⌘R` | 使用共享 scheme 的 Release Run 配置启动 App。真机需要先完成签名设置。 |
| Xcode 中选择 Product → Profile | 使用共享 scheme 的 Release Profile 配置启动 Instruments。 |
| `./Scripts/download_sample.sh` | 重新下载、校验并覆盖轻量 SH0 回退资源 `GaussianSplatMobile/Resources/sample_scene.ply`。脚本会联网并用固定版本 `@playcanvas/splat-transform@3.3.0` 转换数据。 |
| `./Scripts/download_validation_scene.sh` | 下载或复用已下载的 3,177,554 点 SH3 Dr Johnson 完整压力资源，校验点数、PLY header/schema、顶点 stride 与精确文件大小，并计算当前文件的 SHA-256 写入 manifest；它不与固定可信摘要比对。输出位于 `ValidationAssets/`。 |

当前 [Vendor/MetalSplatter/Package.swift](../Vendor/MetalSplatter/Package.swift) 只声明三个 library target，没有声明 `.testTarget`；虽然三个模块目录中保留了 XCTest 源文件，`swift test` 目前不会把它们作为包测试运行。新增功能若依赖这些测试，先在 [Vendor/MetalSplatter/Package.swift](../Vendor/MetalSplatter/Package.swift) 中显式接入相应 test target 和 fixture 资源。

## 模块所有权与修改边界

| 区域 | 当前职责 | 适合放置的改动 |
| --- | --- | --- |
| `GaussianSplatMobile/App/` | App 入口、可观察加载与性能状态 | 产品级状态、错误展示、指标发布 |
| `GaussianSplatMobile/UI/ContentView.swift` | 单屏 UI、手势、四向旋转/缩放按钮、bundle 模型优先级 | 模型选择器、面板、用户偏好 |
| `GaussianSplatMobile/Renderer/MetalSplatView.swift` | `UIViewRepresentable` 与 `MTKView` 生命周期、加载任务取消/重启 | SwiftUI/Metal 桥接、URL 切换策略 |
| `GaussianSplatMobile/Renderer/GaussianSplatRenderer.swift` | MTKView 配置、场景加载编排、候选预算反馈、相机取景、逐帧 command buffer 提交 | App 级渲染策略、深度纹理接线、性能采样 |
| `GaussianSplatMobile/Renderer/SceneChunkLoader.swift` | 65,536 点显式 pending 批次、SH 一致性校验、在线场景统计、编码和 chunk 内 Morton 重排 | 大文件加载策略、批次大小、取消点和场景统计；上游 stream 仍无有界背压 |
| `GaussianSplatMobile/Renderer/OrbitCamera.swift` 与 `Math/` | 相机状态、裁剪面、视图和投影矩阵 | 导航模式、投影策略、坐标校准 |
| `GaussianSplatMobile/Resources/` | 随包模型资源 | 离线准备好的 App 资源；不要放运行时缓存 |
| `Vendor/MetalSplatter/SplatIO/` 与 `PLYIO/` | 文件识别、流式语法解析、`SplatPoint` 领域表示 | 可复用格式读取器、格式验证和转换 |
| `Vendor/MetalSplatter/MetalSplatter/Sources/` | 点编码、chunk、全局排序和绘制器 | 可复用 CPU/GPU 渲染能力、并发与缓冲区协议 |
| `Vendor/MetalSplatter/MetalSplatter/Resources/` | Metal shader 与 Swift 共享布局 | 投影、SH 求色、混合和深度算法 |

判断原则是：用户流程和产品策略留在 App；可被其他 MetalSplatter 客户端复用的解析、编码、排序或 shader 能力进入 `Vendor/MetalSplatter`。修改 vendor 等同于维护本地 fork，应同步更新测试和 `THIRD_PARTY_NOTICES.md` 中需要变化的来源/许可信息，不要在 App 中复制一份略有差异的解析器或 shader。

跨边界时只依赖公开抽象：`SplatSceneReader`/`SplatPoint`、`SplatChunk`、`SplatRenderer` 和 `ChunkID`。`MetalBuffer` 裸指针、排序索引与 Swift/Metal 对齐结构属于引擎内部时序的一部分；新增原地写入必须经过 `SplatRenderer.withChunkAccess`，并让排序索引失效或重建。`SplatChunk`、`SplatRenderer` 使用 `@unchecked Sendable`，这不是任意并发访问的许可。

## 安全扩展手册

以下各节先说明当前能力，再给出安全扩展方法；“模型选择、渐进显示、空间 LOD 和深度输出”等建议不代表当前 App 已经提供这些产品功能。

### 添加模型选择器

当前 `ContentView` 从 `Bundle.main` 优先按 basename `drjohnson_full_sh3` 与扩展名 `ply` 查找 [ValidationAssets/drjohnson_full_sh3.ply](../ValidationAssets/drjohnson_full_sh3.ply)，缺失时回退到 [GaussianSplatMobile/Resources/sample_scene.ply](../GaussianSplatMobile/Resources/sample_scene.ply)；`MetalSplatView.Coordinator` 观察 `modelURL`，URL 变化时取消旧任务并调用 `GaussianSplatRenderer.load(url:)`。因此最小改动应留在 App 层：

1. 在 `ContentView` 增加所选 URL 和选择器展示状态，使用 SwiftUI `fileImporter` 限定 PLY 与 `.splat` 文件。
2. 把“已选择 URL，若无则使用 bundle URL”的结果传给现有 `MetalSplatView(modelURL:camera:status:)`。
3. 对文件提供器返回的 security-scoped URL，在整个异步读取期间保持访问权限；若要跨启动保留模型，优先把文件协调后复制到 App 自己的 Application Support，而不是长期保存临时 URL。
4. 切换时继续复用 Coordinator 的取消逻辑，并加入显式 reload 标识或失败后清空 `loadedURL`。当前实现先记录 URL 再加载，所以同一个 URL 加载失败后不会自动重试。
5. 对扩展名、文件大小和空场景先做用户可读的校验；解析器错误仍由 `RenderStatus.fail` 展示。

架构影响：只增加“模型来源”状态，不改变 `SplatIO → SceneChunkLoader → SplatChunk → SplatRenderer` 数据路径。当前 loader 不调用 `readAll()`，会把自身的 `pendingPoints` 限制为 65,536 点并编码多个 chunk；但 reader 的 `AsyncThrowingStream` 没有有界 buffering/backpressure，排队 batch 的端到端峰值仍需实测或改造，而且全部已编码属性仍会常驻。把用户文件复制进 Application Support 能提高权限与持久性可靠性，代价是额外磁盘空间和导入进度 UI。

### 支持新的文件格式

格式能力属于 `SplatIO`，而不是 `ContentView`。一个完整格式接入至少包括：

1. 在 `Vendor/MetalSplatter/SplatIO/Sources/SplatFileFormat.swift` 增加扩展名映射。
2. 新建实现 `SplatSceneReader` 的 reader；`read()` 应产生 `AsyncThrowingStream<[SplatPoint], Error>`，并把外部坐标、颜色、透明度、尺度和四元数语义明确转换成 `SplatPoint`。
3. 在 `AutodetectSceneReader` 中分派新 reader。若 reader 引入第三方库，还要在 `Vendor/MetalSplatter/Package.swift` 声明依赖；仅把源文件放进目录不等于依赖已经接好。
4. 为有效、截断、非法属性、空文件和批次边界添加 fixture 测试，并把现有 Tests 目录正式声明为 package test target。
5. 更新模型选择器允许的类型；固定 bundle 模型方案还需同步 Xcode Resources 引用和 `ContentView` 的资源扩展名。

不要把“能解析”与“能安全渲染”等同起来。新 reader 应拒绝 NaN/无穷位置、非正线性尺度、不可归一化四元数和不一致的 SH degree，防止坏值进入协方差编码或排序。当前 PLY reader 可读 PLY 与完整 `.splat` reader；`SplatFileFormat` 虽有 `.spz`，但 [Vendor/MetalSplatter/Package.swift](../Vendor/MetalSplatter/Package.swift) 排除了 SPZ reader/writer，autodetect 会拒绝它。恢复 SPZ 需要恢复对应 package 依赖和测试，不能只删除一个 `switch` 分支。

架构影响：理想情况下只扩展 I/O 层和 App 的类型过滤，渲染层继续消费统一 `SplatPoint`。取舍是统一表示简化渲染，但每个批次仍要先形成 `[SplatPoint]` 再编码，所以一个批次内会短暂同时存在语义点与最终 Metal buffer。`SceneChunkLoader` 已直接消费 reader 批次，不会主动建立全场景数组；它限制了自己的 pending 数组，却因上游 stream 无背压而尚未形成严格的端到端有界解析。这也不是边读边显示或按视点淘汰的运行时流式渲染。

### 继续优化后台分批编码

当前解析、Welford 场景统计、`SplatChunk(device:from:)` 协方差/Float16 编码和 chunk 内 Morton 重排，已经全部在 `Task.detached(priority: .userInitiated)` 中按 65,536 点批次顺序执行。返回主 actor 的 `LoadedScene` 只保留最终 `[SplatChunk]` 和场景元数据，然后通过一次 `addChunks(..., sortByLocality: false)` 注册，避免重复 Morton 排序和逐 chunk 独占同步。

这不意味着“永远只有一份数据”：在某个 chunk 构造期间，它的 `[SplatPoint]` 与新分配的 Metal 基础/SH buffer 会短暂共存；Morton 排序还会创建该 chunk 的索引和 visited 临时结构。这些显式 chunk 临时结构受单 chunk 限制，完成后当前 pending 批次会释放；但无界 stream 仍可能持有多个尚未消费的 `[SplatPoint]` batch，所以不能把单 chunk 上限当成整个读取链路的硬内存上界。

继续优化时，可以为 reader/encoder 增加“直接填充预分配 Metal buffer”的受控 API，减少批内共存；但必须同时保留属性语义转换、SH 一致性检查、记录边界处理、取消、部分分配失败回收和 Morton 重排时的属性对应。不要用更多 `@unchecked Sendable` 代替这些所有权证明。

保留当前发布顺序：全部批次编码成功 → 批量 `addChunks` 完成 → 相机取景 → 替换公开 renderer → 发布 `.ready`。这使失败或取消不会展示半初始化场景，代价是不能渐进出图。若改为渐进发布，必须新增 loading/partial-ready 状态，并定义旧 URL 任务与新 URL 任务之间的世代隔离。

### 分块与 LOD

底层 `SplatRenderer` 支持多个 `SplatChunk`，可用 `addChunk`、`addChunks`、`removeChunk`、`removeAllChunks`、`setChunkEnabled` 和 `afterNextSort` 管理。当前 App 会把文件每 65,536 点编码为一个 chunk，例如 3,177,554 点验证场景产生 49 个 chunk；然而这些只是文件顺序上的加载工作集边界，每个 chunk 内再做 Morton 重排，并不等于可独立寻址的空间 tile。排序器从所有已登记 chunk 的展平序列中做确定性等距候选抽样，再对候选集生成一个由远到近的全局索引。

安全的第一步是离线把场景切成带包围体与误差指标的空间块，并让 App 维护“已加载、可见、当前 LOD”状态。切换时先加入新 chunk，等待 `afterNextSort` 后再展示，最后移除旧 chunk；相机变化应使用滞回阈值，避免 LOD 在边界来回抖动。所有增删继续走公开 chunk API，不直接改 `orderedChunkIDs` 或索引 buffer。

注意两个当前限制：

- disabled chunk 仍参与 CPU 候选抽样/排序，并出现在每帧 GPU 索引与 chunk 表处理中；同时保留多级 LOD 再只切 `enabled`，切换快但不会节省常驻属性，对有界候选集的核心排序/顶点成本也没有本质改善。
- 当前已避免 `readAll()`，但 loader 仍要读完整个源文件、建立全部 Metal chunk，才会发布 renderer。真正的 chunk/LOD streaming 需要可独立寻址的分块文件或索引格式，并增加加载、驻留、淘汰与渐进发布策略。

架构影响：App 新增可见性/驻留策略，I/O 新增可寻址块元数据；若要让 disabled chunk 不参与候选集，还必须修改 vendor 的 sorter 与索引失效协议。取舍是可控制内存与远景点数，但会引入加载抖动、边界接缝、更多 I/O、LOD 生成工具链和更复杂的取消/淘汰逻辑。当前多 chunk 移除了显式整场语义数组并限制逐 chunk 编码/Morton 临时规模，但 reader stream 无背压、全部属性仍常驻；仅“多建几个 chunk”不会自动得到严格峰值上界，也不会带来视锥剔除、遮挡剔除或 LOD。

### 启用深度输出

当前三处配置一致地关闭深度：`MTKView.depthStencilPixelFormat = .invalid`、`SplatRenderer(depthFormat: .invalid, highQualityDepth: false)`，以及 `render(..., depthTexture: nil)`。启用时必须同时修改这三处，建议统一使用 `.depth32Float`，并把 `view.depthStencilTexture` 传入 renderer；只改其中一处会造成 pipeline 与 render attachment 不匹配。

MetalSplatter 提供两种语义：

- `highQualityDepth: false` 使用单阶段管线，写入靠近相机的 splat 深度；低透明度 splat 也可能影响结果。
- `highQualityDepth: true` 在真机上启用 imageblock 多阶段管线，按 Alpha 累积并归一化深度，结果更连续，但增加 tile 初始化、深度混合和全屏 postprocess。模拟器代码会退回单阶段路径。

当前 depth state 使用 `.always` 并写深度；它输出深度供合成或重投影使用，不负责替代透明高斯的由远到近排序，也不会自动实现传统网格遮挡。若要与其他几何混合，必须先定义统一的投影约定、clear depth、比较函数和 pass 顺序，再用捕获帧验证。

架构影响：App renderer 多管理一个 attachment，vendor 会根据 depthFormat/highQualityDepth 选择不同 shader 管线。取舍是可与 AR/后处理集成，但增加显存带宽和 GPU 时间；高质量深度更连续，却比单阶段明显更复杂，应以目标设备实测决定。

## 性能分析

建立两级可复现基线：用 175,745 点 SH0 [GaussianSplatMobile/Resources/sample_scene.ply](../GaussianSplatMobile/Resources/sample_scene.ply) 快速检查加载和交互，用 [ValidationAssets/drjohnson_full_sh3.ply](../ValidationAssets/drjohnson_full_sh3.ply) 的 3,177,554 点 SH3 完整场景检查大模型内存和 60 FPS 候选预算。当前 Xcode Resources 同时打包两者，`ContentView` 优先运行 Dr Johnson；要强制轻量基线，需要临时从 target Resources 移除完整资源或改变 URL 选择顺序。每次测量都固定设备、系统、方向、分辨率、电量状态和运行时长。共享 Profile action 已是 Release；真机安装后优先用 Instruments 测量，避免用 Debug 或模拟器结果判断发布性能。

建议按问题选择工具：

- Time Profiler：关注 `SceneChunkLoader.load`、`SplatChunk.init(device:from:)`、`SplatChunk.sortByLocality()` 和 `SplatSorter.performSort`。排序会从全场展平序列确定性抽取最多当前 candidate budget 个点，再计算深度并执行 Swift sort；不应再把排序时间解读为“对全部常驻点排序”。
- Allocations 与 VM Tracker：记录加载前、每 8 个 chunk 的上传日志点、全部 chunk 完成和首次渲染后的常驻/峰值内存，重点观察单批 `[SplatPoint]`、Morton 临时结构、有界排序临时数组、三份候选索引 buffer 与全量 SH buffer。
- Metal System Trace/GPU Counters：定位 CPU 提交、GPU 执行、drawable 等待和热降频。代码已给 command queue 标记 `3DGS Render Command Queue`、command buffer 标记 `3DGS Frame`，并给 `Draw Splats`、高质量深度的 `Initialize`/`Postprocess` 加了 debug group。
- Xcode GPU Frame Capture：检查点/SH/chunk table/index buffer 绑定、实例数、像素 overdraw 和深度 attachment。透明椭圆通常受 overdraw 与分辨率影响，不能只根据 splat 数量估算 GPU 成本。

界面 FPS 在 command buffer 的 GPU completion handler 中计数，按至少 0.75 秒窗口统计；它比“CPU 已提交”更接近实际完成率，但仍不等于精确的屏幕 present pacing。“GPU ms”是当前窗口内 `gpuEndTime - gpuStartTime` 的平均值；“排序 ms”是后台 CPU 候选排序的墙钟时间。分析回归时至少同时记录加载耗时、峰值内存、当前候选数、排序时间、完成 FPS、GPU 时间和热稳定后的帧率。现有结构化日志覆盖离散阶段与耗时；若需要 Instruments 中可视化的嵌套时间线，再在 decode/encode、Morton sort、首次 candidate sort 和首次 present 周围增加 `os_signpost`，不要把日志输出放进逐点或逐帧热循环。

## 结构化日志与排障

App 统一通过 [`GaussianSplatMobile/App/AppLog.swift`](../GaussianSplatMobile/App/AppLog.swift) 使用 Apple Unified Logging，subsystem 取运行时 Bundle Identifier，分类如下：

| Category | 记录内容 | 热路径约束 |
| --- | --- | --- |
| `Lifecycle` | App 启动、`MTKView` 创建/拆除、加载任务取消 | 只在生命周期边界记录 |
| `State` | `loading`、`ready`、`failed` 状态转换 | 不记录 FPS 的每次刷新 |
| `SceneLoading` | 文件名、reader 类型、解析点数、中心/半径、GPU chunk 构建、取消与失败、阶段耗时 | 不逐点记录；只公开文件名，不记录完整路径 |
| `Rendering` | Metal 设备、首次排序、节流后的慢排序警告、首帧提交、尺寸变化和提交错误 | 不逐帧记录；慢排序警告最多每 5 秒一次 |
| `Camera` | 自动取景、重置、一次 orbit/zoom 手势结束后的参数，以及每次旋转/缩放按钮的最终相机状态 | 不记录手势的每个 `onChanged` |

在 Xcode Console 中运行 App 后按 subsystem 或上表 category 过滤。若在本机观察模拟器进程，也可使用：

```bash
log stream --level debug --predicate 'subsystem == "com.example.GaussianSplatMobile"'
```

更换 Bundle Identifier 后同步替换 predicate；真机日志优先在 Xcode 或 macOS Console.app 中选择对应设备查看。`notice/info` 记录正常关键路径，`warning` 表示排序持续时间超过 50 ms，`error/fault` 表示加载、Metal 初始化或渲染提交失败，`debug` 主要用于视图尺寸和相机交互。

新增日志时保持结构化 `key=value` 字段，并评估隐私标记。当前公开字段限于 bundle 内文件名、点数、字节数、耗时、设备名、场景统计和可展示错误文本；不要把用户选择文件的完整路径、账户标识或资产内容标为 `.public`。高频指标应进计数器、状态采样或 signpost，而不是增加逐帧字符串日志。

## 代码风格

工程未配置 SwiftLint、SwiftFormat、EditorConfig 或格式化脚本；当前没有可执行的独立 lint 命令。以 Xcode 默认 Swift 格式和现有文件为准，并把“零编译警告”作为最低检查标准。

- App target 使用 Swift 6.0 和 `SWIFT_STRICT_CONCURRENCY = complete`。UI、相机和状态保持 `@MainActor`；跨任务值应显式满足 `Sendable`。
- 资源所有权要可追踪：异步任务在 view 拆除/URL 变化时取消，command buffer 完成前不得回收 GPU 使用的 buffer。
- Swift 与 Metal 共享结构或常量必须同步修改两侧，并检查大小、对齐、字段顺序与像素格式。
- 热路径避免临时分配和主 actor 上的全点循环；任何性能优化都附真机 Release 数据。

## 分支约定

仓库内容中没有 CONTRIBUTING、PR 模板、分支说明或可读取的 Git 元数据，因此无法确定默认分支，也没有已文档化的命名规范。开始工作前向维护者确认目标分支。若团队尚无约定，建议使用短生命周期、描述性分支，例如 `feat/model-picker`、`perf/background-encoding` 或 `fix/depth-attachment`；这是建议，不是现有项目规则。

## PR 流程

当前没有 PR 模板或自动化 CI 工作流。提交前至少完成以下检查：

- 说明改动属于 App 产品层还是 vendored 引擎层；vendor 改动列出公共 API、数据布局、并发或第三方许可影响。
- 执行上表的无签名模拟器 Debug 构建，确保 Swift 6 严格并发和 Metal shader 编译通过。
- 在 iOS 18+ 真机用 Release 运行轻量 SH0 和完整 SH3 场景，验证加载、单指拖动、双指缩放、四向旋转/缩放按钮、双击/按钮重置、前后台切换和错误路径；确认加载期间相机按钮被禁用。
- I/O 改动附最小 fixture 和畸形输入；缓冲、排序或 shader 改动附对应单元测试接线或可复现的捕获/性能数据。
- 性能 PR 同时报告设备、系统、模型点数/SH degree、分辨率、基线与改后数据，避免只报告峰值 FPS。
- 不提交 DerivedData、`.build`、用户态 Xcode 数据或导入的私有模型；确认新增数据和依赖的许可允许再分发。

评审重点依次是：输入能否被安全拒绝、取消/切换是否会发布旧结果、CPU/GPU buffer 生命周期是否正确、透明排序与深度语义是否保持，以及真机性能是否出现回退。
