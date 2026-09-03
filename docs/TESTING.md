<!-- generated-by: gsd-doc-writer -->
# 测试指南

> **代码基线（2026-08-27）：** 本文按当前的 65,536 点分批编码、SH0～SH3、317 万点 SH3 默认验证场景、有界候选与自适应 60 FPS 控制，以及四向旋转/缩放按钮更新。当前仍只有构建与人工运行验证，没有可执行的 App 自动化测试 target。

## 测试框架与当前状态

GaussianSplatMobile 当前**没有可运行的自动化测试套件**。Xcode 工程只包含 `GaussianSplatMobile` application target；共享 Scheme 的 `TestAction` 为空，没有 unit test、UI test 或 performance test target。XCTest 随 Xcode 提供，无需单独安装，但目前也没有 target 会链接并运行它。

仓库内能看到一些 XCTest 源码，但它们属于随项目内置的 MetalSplatter 上游代码：

- [`Vendor/MetalSplatter/PLYIO/Tests/`](../Vendor/MetalSplatter/PLYIO/Tests/)：PLY 字节转换、ASCII/binary 读取与往返写入测试。
- [`Vendor/MetalSplatter/SplatIO/Tests/`](../Vendor/MetalSplatter/SplatIO/Tests/)：PLY、`.splat` 和 SPZ 读写测试。
- [`Vendor/MetalSplatter/MetalSplatter/Tests/`](../Vendor/MetalSplatter/MetalSplatter/Tests/)：chunk 管理与深度排序测试，需要 Metal device。

这些文件目前不是本项目的可执行测试。理由可直接从 [`Vendor/MetalSplatter/Package.swift`](../Vendor/MetalSplatter/Package.swift) 验证：manifest 只声明 `PLYIO`、`SplatIO`、`MetalSplatter` 三个 `.target`，没有任何 `.testTarget`，也没有把 `TestData` 声明为测试资源。因此，保留的 `Tests` 目录不会被 Swift Package Manager 自动发现。

不要直接把所有上游测试重新挂回 manifest。当前精简包排除了 `SPZSceneReader.swift` 和 `SPZSceneWriter.swift`，也没有 `spz` 依赖，而 `SplatIOTests.swift` 仍含 `import spz` 和多项 SPZ 测试；恢复测试前需要先拆分或移除这些与当前产品裁剪不相容的用例。

开始任何验证前，需要：

- 在 macOS 上安装能构建 iOS 18 target 和 Swift tools 6.1 manifest 的 Xcode。
- 从仓库根目录运行命令，使 `GaussianSplatMobile.xcodeproj` 和本地 package 相对路径能正确解析。
- 若在真机上运行 App，按 [`README.md`](../README.md) 配置开发团队和唯一 Bundle Identifier。下面的无签名模拟器构建不需要这一步。

## 运行测试与当前可执行验证

### 当前能运行的检查

下列命令已针对仓库中的工程、Scheme 和本地 package 路径核验。它们是构建验证，不应被描述成单元测试或集成测试。

先确认 Xcode 能解析工程和本地 package：

```bash
xcodebuild -list -project GaussianSplatMobile.xcodeproj
```

预期能看到一个 `GaussianSplatMobile` target，以及 `GaussianSplatMobile`、`MetalSplatter`、`PLYIO`、`SplatIO` 四个 Scheme。该检查能发现工程文件损坏、Scheme 丢失或本地 package 无法解析；它不会编译源码、运行 App，也不会验证渲染结果。

执行无签名的 Release 模拟器构建：

```bash
xcodebuild \
  -project GaussianSplatMobile.xcodeproj \
  -scheme GaussianSplatMobile \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

该检查会编译 App、Swift package 和 Metal 资源，并验证链接与 App bundle 生成。当前 Resources phase 还会复制约 752 MiB 的 `drjohnson_full_sh3.ply`，因此完整仓库中的构建需要明显更多磁盘空间和复制时间。该检查能捕获大部分编译错误、缺失源码/资源引用和链接错误；它不会启动 App、解析完整样例、验证手势或像素输出，也不能代表真机 GPU 性能、内存占用和签名是否正确。

执行 Debug 静态分析：

```bash
xcodebuild \
  -project GaussianSplatMobile.xcodeproj \
  -scheme GaussianSplatMobile \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  analyze
```

该检查增加编译器静态分析，可发现一部分控制流、资源使用和 API 误用问题；它无法证明异步任务、Metal 命令提交、视觉正确性或运行时资源生命周期正确。

### 当前人工运行验证

完整压力资产由以下命令下载并检查结构完整性；脚本支持断点续传，文件已存在时仍会重新验证点数、PLY header/schema、vertex stride 和精确文件大小，并重新计算 SHA-256 写入 manifest。脚本不会把该摘要与固定或先前可信值比较，因此这一步不构成 SHA-256 完整性或来源校验；生产或供应链验收应另行与受信任的固定摘要比较：

```bash
./Scripts/download_validation_scene.sh
```

运行 App 时，`ContentView` 优先加载 `drjohnson_full_sh3.ply`，只有主 bundle 中找不到它时才回退到 `sample_scene.ply`。在固定 iPhone 上使用共享 Scheme 的 Release 配置验证以下路径：

1. 等待状态从“正在加载 3DGS”进入 `ready`，确认显示 `3,177,554` 个高斯、`SH3`、`49 chunks`；首次可见画面可能晚于 `ready`，因为第一次相机深度排序不包含在加载完成条件中。
2. 检查四个箭头按钮分别向左、上、下、右旋转；每次点击改变 15°，pitch 应保持在 `[-1.45, 1.45]` 弧度内。
3. 检查缩小/放大按钮每次按 $1.2$ 倍改变相机距离，并保持在场景半径的 `0.15...20` 倍内；加载完成前六个按钮应禁用并显示为半透明。
4. 检查单指拖动、双指捏合、双击画面和右上角取景框重置仍可与按钮交替使用，切换输入方式时不应跳回旧的手势起点。
5. 观察状态卡中的完成帧率、平均 GPU 时间、最近排序时间和候选数。大场景初始候选为 1,000,000；控制器至少间隔 3 秒调整一次，低于 55 FPS 时乘 `0.8`，达到至少 59 FPS 且平均 GPU 时间大于 0、低于 12 ms 时乘 `1.1`，最终受 250,000～1,250,000 和场景总点数约束。
6. 重复进入后台/前台和销毁视图，确认加载任务被取消、Metal view delegate 被移除，且内存不会随次数持续上涨。若直接关闭 Simulator，LLDB 可能停在 `SIGTERM` 或 `mach_msg2_trap`；这本身不是 App crash。真正的异常应保留 `EXC_BAD_ACCESS`、`EXC_BREAKPOINT`、fatal error 或 `.ips` 报告再分析。

性能验证必须停止 Xcode 调试后从设备主屏幕启动 Release App；模拟器、Debug、连接 LLDB 或首次温热缓存的数据不能作为 iPhone 15 Pro 的 60 FPS 结论。

### 当前不能运行的测试命令

完整套件、测试子集、单个测试文件和 watch mode 都**没有可用命令**，因为仓库尚未定义测试 target。当前执行 App Scheme 的 `test` action 会以退出码 66 失败：

```text
xcodebuild: error: Scheme GaussianSplatMobile is not currently configured for the test action.
```

因此，不要把 `xcodebuild test` 或 `swift test --package-path Vendor/MetalSplatter` 放进绿色验证流程。添加测试 target、把它加入共享 Scheme，并确认 `xcodebuild -list`/Scheme 测试标识后，才能记录全量、`-only-testing` 子集和单例命令。

## 编写新测试

建议先在 Xcode 工程中增加一个 XCTest unit test target，并把它加入 `GaussianSplatMobile` 共享 Scheme。若要测试完整启动和手势，再单独增加 UI test target。App 侧目前没有命名惯例；为与保留的上游 XCTest 源码一致，可以采用 `*Tests.swift` 文件名、`XCTestCase` 类和 `test...` 方法名。

推荐的新目录结构如下；这些路径是待创建建议，不是现有文件：

```text
GaussianSplatMobileTests/
├── Unit/
├── Integration/
├── MalformedInput/
├── Performance/
├── Fixtures/
└── TestSupport/

GaussianSplatMobileUITests/
├── Interaction/
└── Visual/
```

保持 fixture 小而确定：正常格式保留几个高斯点即可；畸形文件优先在测试中生成短 `Data`，避免把大型或来源不明的二进制文件提交到仓库。共用的临时文件创建、浮点近似比较、异步等待和截图比较逻辑放在 `TestSupport`，不要复制到每个测试类。

[`SceneChunkLoader.load(url:device:)`](../GaussianSplatMobile/Renderer/SceneChunkLoader.swift) 已是 internal，可由 App test target 通过 `@testable import` 调用，但它会创建真实 `SplatChunk` 和 Metal buffer，仍属于 Metal 集成边界。若要在没有 GPU 的测试中稳定覆盖 Welford 中心/半径统计、SH 一致性和错误映射，应把纯统计/校验状态提取为 internal 组件并注入编码器；不要为了测试把实现细节全部改成 public。自适应候选策略目前也位于 renderer 的 private 方法中，若要对 55/59 FPS、12 ms 和三秒节流边界做确定性单元测试，应把策略提取为接收指标并返回新预算的纯函数。

### 推荐测试分层

| 类型 | 优先覆盖的代码与行为 | 能捕获什么 | 盲点与代价 |
| --- | --- | --- | --- |
| 单元测试 | [`OrbitCamera`](../GaussianSplatMobile/Renderer/OrbitCamera.swift) 的拖动、捏合、15° 离散旋转、1.2 倍离散缩放、pitch/距离/clip-plane 边界；[`MatrixMath.swift`](../GaussianSplatMobile/Math/MatrixMath.swift) 的投影矩阵；[`RenderStatus`](../GaussianSplatMobile/App/RenderStatus.swift) 的状态转换、字段重置和秒到毫秒换算 | 数学边界回归、按钮与手势状态串扰、无穷值/NaN、状态字段漏重置、单位换算错误 | 不会经过 SwiftUI、PLY 解析或 GPU；矩阵逐元素断言应使用浮点容差，不能只比较完全相等 |
| 集成测试 | 用 SH0～SH3 的微型合法 PLY 贯通 `AutodetectSceneReader`、`SceneChunkLoader`、65,536 点边界、Morton 重排、`SplatChunk` 创建与 `RenderStatus.ready`；另用 bundle 测试确认优先资源 `drjohnson_full_sh3.ply` 和回退资源 `sample_scene.ply` 的存在与 header/manifest 一致 | package 接线、fixture/resource 打包、异步分批读取、App 与 SplatIO/MetalSplatter 的契约变化、chunk 尾批错误 | 模拟器成功不能证明真机 GPU 正确；317 万点文件不应进入每个测试，多数用例使用微型 fixture，只留独立且可跳过的完整资产冒烟测试 |
| 畸形输入测试 | 截断 header/body、未知格式、缺少 `vertex` 或必需属性、非法 `f_rest_*` 数量/缺号、同一场景混合 SH degree、声明数量与内容不符、零点场景、NaN/Infinity、异常大的 element count、取消中的读取任务 | 解析错误未传播、崩溃、失控分配、空场景未进入 `failed`、混合 SH 未拒绝、取消后错误覆盖新状态 | 一组手写样本不能替代 fuzzing；超大声明值要用小文件模拟并设置超时，避免测试本身耗尽内存或拖垮 CI |
| UI/交互集成测试 | 启动后等待 ready/failed，检查加载中按钮禁用；按 accessibility label 操作“向左/上/下/右旋转”“缩小”“放大”“重置视角”；再覆盖拖动、捏合、双击和说明 sheet | SwiftUI 绑定、accessibility 标识、按钮启用条件、按钮/手势接线、资源优先级与缺少资源时的错误界面 | UI 自动化只能确认可见状态和交互，不会证明投影、排序或透明混合的像素正确；完整 SH3 首次加载时间随设备变化，必须使用条件等待，禁止固定长时间 sleep |
| 视觉回归测试 | 在固定设备、OS、方向、分辨率和相机矩阵下渲染微型确定场景，与基准图做带容差的差异比较 | Metal shader、投影矩阵、相机方向、颜色空间、透明混合和排序造成的画面回归 | GPU、OS、抗锯齿和色彩管理会产生微小像素差；阈值过严会抖动，过松会漏错。基准图需按受支持设备族管理，不能用单一模拟器截图代表真机 |
| 性能测试 | Release 真机上的分批解析/编码耗时、首次 `ready`、首次可渲染时间、候选深度排序耗时、完成帧率、GPU 时间和预算升降；分别使用微型模型、175,745 点 SH0 fallback 与 3,177,554 点 SH3 压力场景 | 算法复杂度退化、额外拷贝、同步阻塞、排序或上传变慢、自适应控制振荡或不能恢复 | 数据高度受设备型号、温度、后台负载和编译配置影响。每次 PR 上跑完整 SH3 严格阈值成本高且易误报；模拟器适合粗粒度回归，权威基线应在固定真机、冷却条件和多次采样下取得 |
| 内存测试 | 65,535/65,536/65,537 点 chunk 边界、反复加载/销毁 view、取消并重启加载、前后台切换、317 万 SH3 峰值，以及持久点/SH buffer、三个排序索引和 buffer pool 生命周期 | 批次 `[SplatPoint]` 未及时释放、CPU 对象泄漏、Task/Coordinator 生命周期错误、重复加载后持续增长、候选 buffer 只增不复用、峰值超预算 | XCTest 的进程内存指标不完整覆盖 GPU/driver 分配；需要结合 Allocations、Leaks 和 Metal System Trace。完整检查较慢，适合作为定期真机任务而非每次提交的阻塞门槛 |

### 性能测试的执行原则

性能数字必须带上设备型号、iOS/Xcode 版本、build configuration、模型 hash、分辨率、刷新率和采样次数，否则不同结果不可比较。轻量 fallback `sample_scene.ply` 的 SHA-256 是 `5108445bc1594d6b6c5cb862b8c5084caf339e742b397f2295230684e576989b`；完整压力场景 `drjohnson_full_sh3.ply` 的 SHA-256 是 `92f4898839ec4ad7f197cf6c74b89918b35ea712b4e41435593ccb152d22b7f5`。后者的点数、SH degree、stride 和字节数还必须与 [`drjohnson_full_sh3.json`](../ValidationAssets/drjohnson_full_sh3.json) 一致。

建议把性能检查分成两层：

1. PR 层只运行微型 SH0～SH3 fixture 和 65,536 点边界的短时解析/算法回归，主要捕获契约变化与数量级恶化；完整 752 MiB 资产不应成为每次 checkout 或普通 PR 的硬依赖。
2. 定期或发布前在固定 iPhone 15 Pro 上运行完整 SH3 Release 基准，停止调试器影响，预热后多次采样并报告中位数和尾部结果；把 60 FPS 记录为目标，而不是单次观察即可证明的保证。

性能测试和覆盖率采集应分开运行。覆盖率插桩、Debug 优化级别、连接调试器和模拟器都会改变时序与内存行为；用它们取得的数字不能作为 README 所述真机体验的性能结论。

## 覆盖率要求

仓库没有 coverage 配置、`.xctestplan`、`xccov` 脚本或 CI 门槛；由于当前没有测试 target，也不会生成有意义的覆盖率报告。

| 类型 | 当前阈值 |
| --- | --- |
| Lines | 未配置 |
| Branches | 未配置 |
| Functions | 未配置 |
| Statements | 未配置 |

添加首批测试后，先保存报告用于观察未覆盖区域，再基于稳定的纯逻辑代码设门槛。不要用高行覆盖率替代视觉、GPU、内存或畸形输入验证：Metal shader、资源打包和真机渲染路径即使没有反映在 Swift 行覆盖率中，仍然是高风险区域。

## CI 集成

当前仓库没有 `.github/workflows/` 或其他可识别的 CI 配置，所以 push 和 pull request 不会自动运行构建、静态分析或测试；也不存在可引用的 workflow、job 或测试命令。

在添加 CI 时，可以先把本页已核验的 Release 模拟器构建和 Debug 静态分析作为基础 job。等测试 target 真正加入共享 Scheme 后，再增加单元/集成测试 job，并从实际 Scheme 获取测试标识；视觉基准应固定 simulator runtime，性能和完整内存检查则应放到独立的定期真机流程，避免让易受环境噪声影响的指标阻塞每个 PR。
