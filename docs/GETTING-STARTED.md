<!-- generated-by: gsd-doc-writer -->
# 快速开始与代码导读

这份指南帮助第一次接触项目的开发者完成构建和真机运行，并沿着一帧图像真正经过的路径阅读代码。先建立调用关系，再到 [ARCHITECTURE.md](ARCHITECTURE.md) 查数学、线程和缓冲区取舍；这里不重复完整渲染理论。

> **代码基线（2026-08-27）：** 当前 App 优先加载完整的 `drjohnson_full_sh3.ply`，按 65,536 点分批编码为多个 Metal chunk，支持 SH0～SH3，并以自适应的有界候选集追求 60 FPS。交互同时提供拖动/捏合手势、四向旋转按钮、放大/缩小按钮和重置视角。

## 前置条件

- 一台 Mac，以及能够解析 Swift tools 6.1 manifest、提供 iOS 18 SDK 的 Xcode。当前源码已用 Xcode 26.0.1（Apple Swift 6.2）验证；App target 使用 Swift 6 语言模式，本地 `MetalSplatter` 包声明了 `swift-tools-version: 6.1`。
- 用于运行的 iPhone 需安装 `iOS >= 18.0` 并支持 Metal。工程的目标设备族仅为 iPhone；模拟器可以用于编译检查，但不适合评估真实帧率。
- 在真机安装时，需要在 Xcode 中登录 Apple ID、选择 Development Team，并使用自己的唯一 Bundle Identifier。仓库中的默认值是 `com.example.GaussianSplatMobile`，Development Team 为空。
- 正常构建不需要联网：`Vendor/MetalSplatter` 是本地 Swift Package，轻量 `GaussianSplatMobile/Resources/sample_scene.ply` 与完整 `ValidationAssets/drjohnson_full_sh3.ply` 都已存在于当前工作区并列入 Copy Bundle Resources。完整文件约 752 MiB，构建、安装和首次加载都需要预留额外时间与空间。

只有在重新生成样例模型时，才额外需要 `curl`、`python3`、Node.js 提供的 `npx` 以及网络连接；这些不是首次运行 App 的前置条件。

## 安装步骤

仓库中没有可检测的 Git remote，因此请把下面的占位符换成实际仓库地址。

1. 克隆仓库：

   ```bash
   git clone <repository-url>
   ```

2. 进入工程根目录：

   ```bash
   cd GaussianSplatMobile
   ```

3. 确认本地依赖和两个已登记的模型资源都在：

   ```bash
   test -f Vendor/MetalSplatter/Package.swift
   test -f GaussianSplatMobile/Resources/sample_scene.ply
   test -f ValidationAssets/drjohnson_full_sh3.ply
   ```

4. 打开工程；无需运行 `swift package resolve` 或安装第三方依赖：

   ```bash
   open GaussianSplatMobile.xcodeproj
   ```

如果只想先验证源码能否为模拟器编译，可以在工程根目录运行：

```bash
xcodebuild \
  -project GaussianSplatMobile.xcodeproj \
  -scheme GaussianSplatMobile \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

成功时末尾会出现 `** BUILD SUCCEEDED **`。这条命令只检查构建，不会安装或启动 App。

## 第一次运行

1. 在 Xcode 选择 `GaussianSplatMobile` target，打开 **Signing & Capabilities**，选择自己的 Team，并把 Bundle Identifier 改成唯一值。
2. 在顶部选择共享 Scheme `GaussianSplatMobile` 和一台 iOS 18 或更高版本的 iPhone。Scheme 的 Run 配置已固定为 `Release`，这样大型 PLY 不会承受 Debug 构建的额外开销。
3. 按 `Command-R`。当前资源不变时，画面先显示“正在加载 3DGS”，完成后显示 `3,177,554` 个高斯、`SH3`、`49 chunks`，并开始显示 FPS、候选绘制数、平均 GPU 时间与最近一次排序耗时。App 会优先选择 `drjohnson_full_sh3.ply`；只有 bundle 中没有它时才回退到 175,745 点的 SH0 Bonsai。
4. 用单指拖动或屏幕四向按钮旋转，用双指捏合或放大/缩小按钮改变距离；双击画面或点右上角取景框重置。六个相机按钮在加载完成前保持禁用。
5. 测性能时，先让 Xcode 完成安装，再停止调试并从手机主屏幕启动 App。模拟器只能验证启动、界面和基本渲染，不能代表 iPhone GPU 帧率。

最小验收清单：Dr Johnson 模型可见；拖动和四向按钮都能绕场景旋转；捏合和缩放按钮都能改变距离；双击或取景框按钮能回到初始取景；底部状态卡持续更新 FPS、绘制候选数与 GPU/排序耗时。加载状态变为 ready 后，第一次相机相关排序仍可能尚未完成；renderer 暂时拿不到有效索引时会提交空 command buffer 并丢弃该帧，短暂等待不等同于崩溃。

## 分阶段阅读代码

先记住这条主线：

```text
GaussianSplatMobileApp
  → ContentView
  → MetalSplatView / MTKView
  → GaussianSplatRenderer.load + draw
  → SceneChunkLoader → SplatIO reader
  → SplatChunk / EncodedSplatPoint
  → SplatRenderer / SplatSorter
  → SingleStageRenderPath.metal / SplatProcessing.metal
```

每一阶段都先回答“输入是什么、输出是什么、谁拥有状态”，再做小实验。一次只改一个位置，实验后立即还原，并保持 Scheme 为 Release。

### 阶段 1：App 入口与 SwiftUI 状态

按以下顺序阅读：

1. `GaussianSplatMobile/App/GaussianSplatMobileApp.swift`：`@main` 创建 `WindowGroup`，根视图是 `ContentView`。
2. `GaussianSplatMobile/UI/ContentView.swift`：找到 `OrbitCamera`、`RenderStatus` 两个 `@StateObject`，再看 `bundledModelURL` 如何优先定位 `drjohnson_full_sh3.ply`，缺失时回退到 `sample_scene.ply`。
3. 继续跟踪 `cameraGesture`、`cameraControls`、`statusCard` 和 `phaseTitle`，理解手势、按钮与渲染状态如何反馈到界面。注意六个相机按钮只有在 `status.phase == .ready` 时可用。

检查点：你应能指出模型 URL、相机状态和加载状态分别由谁创建，解释为什么 SwiftUI 的 body 重算不会重新创建两个 `@StateObject`，并说明按钮和手势为什么最终都修改同一个 `OrbitCamera`。

安全实验：把标题 `3DGS MOBILE` 临时改成自己的文字，确认 SwiftUI 层可以独立变化；随后还原。这个实验不触碰模型或渲染数据。

### 阶段 2：SwiftUI 到 MTKView 的桥

阅读 `GaussianSplatMobile/Renderer/MetalSplatView.swift`：

- `makeUIView` 创建 UIKit 的 `MTKView`，再创建应用侧 `GaussianSplatRenderer` 并设为 `view.delegate`。
- `Coordinator` 跨越 SwiftUI 更新保存 renderer、加载任务和已加载 URL。
- `loadIfNeeded` 用 `loadedURL` 避免同一 URL 被重复加载，并在 URL 改变时取消旧任务。
- `dismantleUIView` 清除 delegate 并取消任务，形成明确的生命周期终点。

检查点：在纸上画出 `ContentView → MetalSplatView → MTKView.delegate → GaussianSplatRenderer` 四个节点；确认 SwiftUI 视图值本身并不直接承担逐帧绘制。

安全实验：分别在 `makeUIView`、`updateUIView` 和 `dismantleUIView` 加断点，启动后观察创建次数，再打开和关闭说明 sheet。无需修改业务代码。

### 阶段 3：模型加载与格式解析

从 `GaussianSplatMobile/Renderer/GaussianSplatRenderer.swift` 的 `load(url:)` 开始：

1. `RenderStatus.beginLoading()` 先把 UI 切到 loading，并重置上一场的点数、候选数和性能指标。
2. `Task.detached(priority: .userInitiated)` 调用 `SceneChunkLoader.load(url:device:)`，使 PLY 解析、统计、点编码和 Morton 重排都不占用主 actor。
3. `SceneChunkLoader` 创建 `AutodetectSceneReader`；当前两个 bundle 文件都是 `.ply`，因此走 `Vendor/MetalSplatter/SplatIO/Sources/SplatPLYSceneReader.swift`。
4. loader 用 `for try await batch in reader.read()` 消费异步批次，再把显式 `pendingPoints` 累计到最多 65,536 个 `SplatPoint`。数组满时立即编码一个最终 `SplatChunk`、做 chunk 内 locality sort，然后清空该批临时点。这个上限只约束 `pendingPoints`；上游 `AsyncThrowingStream` 没有有界 buffering/backpressure，producer 较快时仍可能让多个待消费 batch 排队。
5. 同一遍扫描用 Welford 在线算法累计中心和平方距离，把自动取景半径设为 `max(RMS × 2.5, 0.1)`；同时要求全场 SH degree 一致。文件结束时，尾部不足 65,536 点的数据形成最后一个 chunk。
6. 返回主 actor 的 `LoadedScene` 只持有 `[SplatChunk]` 和场景统计，不持有完整场景 `[SplatPoint]`。随后才创建并注册 `SplatRenderer`、自动取景并更新 `RenderStatus`。

检查点：在 `SceneChunkLoader.load` 返回前检查 `count`、`chunks.count` 和 `shDegree`；当前大模型应分别为 `3,177,554`、`49` 和 `SH3`。这里已经移除了显式整场 `readAll()` 聚合，并限制应用级 pending 数组，但尚未给 reader stream 增加背压，因此不能声称端到端 CPU 解码峰值严格有界。它也不是按视点渐进加载：完整文件读完、所有 chunk 都注册后才发布 renderer，而且全量属性仍常驻 Metal shared buffer。

安全实验：在 `RenderStatus.beginLoading()` 与 `finishLoading(...)` 加断点，观察 `idle → loading → ready`。然后把 `ContentView.bundledModelURL` 临时改为返回 `nil`，确认 UI 显示“App 包中缺少 sample_scene.ply”，验证后立即还原。

### 阶段 4：从 SplatPoint 到 GPU 数据

按数据变形顺序阅读：

1. [`Vendor/MetalSplatter/SplatIO/Sources/SplatPoint.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPoint.swift) 保留一个读取批次中的训练语义：位置、颜色、透明度、尺度和旋转；颜色可表示 SH0～SH3。
2. `GaussianSplatMobile/Renderer/SceneChunkLoader.swift` 把 reader 批次拼成最多 65,536 点的应用级工作集；这层决定场景 chunk 边界。
3. `Vendor/MetalSplatter/MetalSplatter/Sources/SplatChunk.swift` 遍历这一批 `[SplatPoint]`，创建基础 splat buffer；SH1、SH2、SH3 的附加系数分别以每点 9、24、45 个 `Float16` 进入单独 buffer，SH0 不创建该 buffer。
4. `Vendor/MetalSplatter/MetalSplatter/Sources/EncodedSplatPoint.swift` 把尺度和归一化四元数转换为三维协方差的六个独立分量，并用 half 精度存 SH0、透明度和协方差。
5. `Vendor/MetalSplatter/MetalSplatter/Sources/SplatChunk+sortByLocality.swift` 量化位置、生成 Morton code，并原地重排同一 chunk 的基础属性与对应高阶 SH 数据。

检查点：明确区分两种“排序”。这里的 Morton 排序只在加载阶段改变内存排列，以改善访问局部性；它不负责透明度的前后关系。下一阶段的相机相关深度排序才生成真正的绘制索引。

安全实验：在 LLDB 中检查 `MemoryLayout<EncodedSplatPoint>.stride`，当前布局应为 32 字节。也可以临时注释 `SceneChunkLoader` 中的 `chunk.sortByLocality()`，只比较加载耗时和 FPS，不比较画面正确性；完成后还原。不要把后续 `addChunks(..., sortByLocality: false)` 改为 `true`，否则每个 chunk 会重复做一次 locality sort。

### 阶段 5：相机、深度排序与逐帧提交

先看应用层 `GaussianSplatRenderer.draw(in:)`：它根据 `OrbitCamera` 生成 view/projection 矩阵和 viewport，创建 command buffer，再调用库的 `SplatRenderer.render(...)`。随后阅读：

1. `Vendor/MetalSplatter/MetalSplatter/Sources/SplatRenderer.swift` 的 `render`：从 view matrix 恢复相机 pose，把 pose 交给 sorter，取得最近一份有效索引，绑定 buffers 并编码实例化绘制。当前 App 只传一个 `ViewportDescriptor`，因此是单视口。
2. `Vendor/MetalSplatter/MetalSplatter/Sources/SplatSorter.swift` 的 `updateCameraPose`、`sortLoop` 和 `performSort`：先从全量扁平 chunk 序列做确定性均匀采样，把候选限制在当前预算内；后台任务再计算候选到相机的距离平方，按较大距离优先排列，并写入三份可轮换索引 buffer 中的一份。
3. 回到应用层，确认只有 `didRender == true` 才会 `present(drawable)`；暂时拿不到排序结果时会提交空 command buffer 并丢弃当前帧。

继续阅读 `recordCompletedFrame` 和 `adjustCandidateBudgetIfNeeded`：每至少 0.75 秒根据已完成帧统计 FPS 和平均 GPU 时间；预算最多每 3 秒调整一次。FPS 低于 55 时预算乘 0.8；FPS 至少 59、平均 GPU 时间大于 0 且低于 12 ms 时，预算乘 1.1。预算范围是 250,000 到 `min(场景点数, 1,250,000)`，当前大模型初值为 1,000,000。

检查点：你应能解释为什么 GPU 可以继续使用旧索引，而 CPU 同时写另一份索引；也应能指出当前配置的最多 in-flight render 数是 3，并区分“全量常驻属性”“有界候选索引”和“本帧实际绘制数”。完整的引用计数、互斥和延迟排序取舍见 [ARCHITECTURE.md 的线程与缓冲区说明](ARCHITECTURE.md#线程隔离与共享状态)。

安全实验：把 `SplatRenderer.Constants.sortByDistance` 暂时改为 `false`，对比“按欧氏距离平方”和“沿相机 forward 方向”旋转时的透明伪影，再还原。这个开关只改变索引排序，不改变点数据。也可以暂时降低 `PerformanceTarget.initialCandidateSplats`，观察状态卡中的绘制数、排序耗时和细节变化；性能比较必须使用同一相机位置和 Release 真机。

### 阶段 6：Metal 顶点与片元阶段

当前 App 传入 `depthFormat: .invalid` 且 `highQualityDepth: false`，所以阅读单阶段路径，不要先从未启用的 multi-stage 路径开始：

1. `Vendor/MetalSplatter/MetalSplatter/Resources/SingleStageRenderPath.metal` 的 `singleStageSplatVertexShader` 从排序索引查到 chunk 和局部 splat，再调用共享的 `splatVertex`。
2. `Vendor/MetalSplatter/MetalSplatter/Resources/SplatProcessing.metal` 的 `splatVertex` 先按 chunk 的 `shDegree` 选择 SH0 快路径或求值 SH1～SH3，再把三维协方差投影为二维协方差、分解椭圆轴，并为每个高斯生成四个 quad 顶点。
3. 同文件的 `splatFragmentAlpha` 根据片元在椭圆内的相对位置计算高斯权重。
4. 回到 `singleStageSplatFragmentShader`：它输出预乘 Alpha 颜色；pipeline 的 blending 再把已按深度排列的高斯由远到近合成。

检查点：任选一个像素，口头走完“排序索引 → `Splat` → 四边形顶点 → 片元 Alpha → blending”的顺序。协方差投影、特征分解和透明合成公式见 [ARCHITECTURE.md 的高斯投影部分](ARCHITECTURE.md#高斯投影颜色与片元合成)。

安全实验：临时把 `singleStageSplatFragmentShader` 的返回值改为 `half4(half3(1, 0, 0) * alpha, alpha)`，确认几何轮廓仍在但颜色统一变红；随后还原原始的预乘颜色表达式。若只想观察调用而不改 shader，可在 Xcode GPU Frame Capture 中捕获一帧并查找 `SingleStagePipeline`。

## 常见设置问题

### 真机提示签名失败

症状通常包含 “Signing requires a development team” 或 Bundle Identifier 已被占用。工程没有预设 Team，且默认标识只是示例值。到 target 的 **Signing & Capabilities** 选择 Team，并换成自己控制的唯一标识；不要直接把个人签名信息提交到共享工程。

### 看不到可用运行目标

工程的 deployment target 是 iOS 18.0，目标设备族是 iPhone。如果设备系统低于 iOS 18、Xcode 没有对应 SDK，或连接设备尚未信任这台 Mac，Xcode 不会提供有效 destination。更新设备/SDK并完成信任后重新选择目标。

### 页面显示缺少 sample_scene.ply

当前 `ContentView` 先查找 `drjohnson_full_sh3.ply`，再回退到 `sample_scene.ply`；两者都不在 bundle 时，`MetalSplatView` 仍使用这条历史错误文案。确认 `ValidationAssets/drjohnson_full_sh3.ply` 或 `GaussianSplatMobile/Resources/sample_scene.ply` 至少有一个存在，并在 target 的 **Build Phases → Copy Bundle Resources** 中登记了实际要加载的文件。仅把文件放进目录但没有加入 target，`Bundle.main.url(...)` 仍会返回 `nil`。

### 构建或安装耗时很长、App 包异常大

当前 target 同时复制 9.4 MiB 轻量样例和约 752 MiB 的完整 SH3 验证文件，因此每次干净构建、安装和部署都可能明显变慢。这是当前压力验证配置的直接结果，不是 Swift Package 下载卡住。日常 UI 开发若要暂时移除大文件，必须同时从 Copy Bundle Resources 移除 `drjohnson_full_sh3.ply`；App 随后会自动回退到 `sample_scene.ply`。需要恢复完整验证时运行 `./Scripts/download_validation_scene.sh`，再确认文件引用已经接回 target。

### 一直加载、首帧很慢或 FPS 很低

先确认 Run 使用 `Release`，再在真机上从主屏幕脱离调试器测试。当前实现不再保留全场 `[SplatPoint]`，但必须完整读完文件、构造 49 个 chunk、完成每个 chunk 的 Morton 重排并注册全部 Metal buffer 后才进入 ready；完整 SH3 属性仍全部常驻。候选预算只减少每帧排序和绘制点数，不减少常驻属性内存，所以大模型的加载时间和内存仍显著高于轻量样例。不要用模拟器结果推断 iPhone GPU 性能。

### 本地 Swift Package 无法解析

`GaussianSplatMobile.xcodeproj` 引用相对路径 `Vendor/MetalSplatter`。确认该目录和其中的 `Package.swift` 没有被遗漏，再重新打开工程。正常构建不会从远程下载 MetalSplatter；如果 Xcode 尝试查找缺失的远程包，说明本地目录或工程引用已被修改。

## 下一步

- 阅读 [ARCHITECTURE.md](ARCHITECTURE.md)，系统理解数据流、内存布局、排序并发、相机数学和 shader 取舍。
- 阅读 [CONFIGURATION.md](CONFIGURATION.md)，了解模型资源、编译设置和代码内渲染常量。
- 阅读 [DEVELOPMENT.md](DEVELOPMENT.md)，了解日常开发命令和工程约定。
- 阅读 [TESTING.md](TESTING.md)，了解测试目标、单测位置和运行方式。
- 阅读 [END-TO-END-DATA-FLOW.md](END-TO-END-DATA-FLOW.md)，按文件输入、线程切换、Metal buffer 和最终屏幕输出串起完整数据流。
- 阅读 [MILLION-SPLAT-IMPLEMENTATION.md](MILLION-SPLAT-IMPLEMENTATION.md)，了解 300 万级 SH3 场景的实现边界、内存预算和 60 FPS 取舍。
