<!-- generated-by: gsd-doc-writer -->
# 配置说明

> **代码基线（2026-08-27）：** 本文已按当前实现统一更新，覆盖 65,536 点分批编码、SH0～SH3、完整 SH3 验证资源、有界候选、自适应 60 FPS 控制，以及新增的四向旋转和缩放按钮。大场景设计与实测背景另见 [MILLION-SPLAT-IMPLEMENTATION.md](MILLION-SPLAT-IMPLEMENTATION.md)。

GaussianSplatMobile 没有服务器端配置或运行时配置文件。工程的配置来源只有 Xcode 工程与共享 Scheme、本地 Swift Package、编译资源，以及 Swift 源码中的默认值。除手势或屏幕按钮造成的相机状态变化，以及按实测帧率发生的候选预算变化外，修改本文列出的值都需要重新构建 App。

## 配置文件格式

| 层级 | 主要文件 | 生效阶段 | 修改方式 |
|---|---|---|---|
| Xcode 工程 | [`GaussianSplatMobile.xcodeproj/project.pbxproj`](../GaussianSplatMobile.xcodeproj/project.pbxproj) | 编译、链接、签名、打包 | 优先通过 Xcode 的 Project/Target 设置修改，避免手工破坏 PBX 对象引用 |
| 共享 Scheme | [`GaussianSplatMobile.xcscheme`](../GaussianSplatMobile.xcodeproj/xcshareddata/xcschemes/GaussianSplatMobile.xcscheme) | Build、Run、Test、Profile、Analyze、Archive | Xcode → Product → Scheme → Edit Scheme |
| 本地 Swift Package | [`Vendor/MetalSplatter/Package.swift`](../Vendor/MetalSplatter/Package.swift) | 依赖解析与编译 | 修改清单或替换整个 vendored 目录后重新解析包 |
| App 资源 | [`Assets.xcassets`](../GaussianSplatMobile/Assets.xcassets)、[`sample_scene.ply`](../GaussianSplatMobile/Resources/sample_scene.ply)、[`drjohnson_full_sh3.ply`](../ValidationAssets/drjohnson_full_sh3.ply) | 编译资源目录、Copy Bundle Resources、运行时加载 | 同时维护文件、Xcode 资源引用和源码查找名 |
| 运行时默认值 | [`GaussianSplatRenderer.swift`](../GaussianSplatMobile/Renderer/GaussianSplatRenderer.swift)、[`SceneChunkLoader.swift`](../GaussianSplatMobile/Renderer/SceneChunkLoader.swift)、[`OrbitCamera.swift`](../GaussianSplatMobile/Renderer/OrbitCamera.swift)、[`ContentView.swift`](../GaussianSplatMobile/UI/ContentView.swift)、[`AppLog.swift`](../GaussianSplatMobile/App/AppLog.swift) | App 启动、加载或渲染过程中 | 修改 Swift 源码并重新构建 |

仓库中没有 `.env`/`.env.example`、`.xcconfig`、独立 `Info.plist`、entitlements 文件，也没有通过 `ProcessInfo.environment`、`UserDefaults`、`@AppStorage` 或命令行参数读取配置。共享 Scheme 也没有声明 Launch Arguments 或 Environment Variables。因此，当前不存在无需重新编译即可覆盖的环境变量。

## 环境变量

| 变量 | 必需 | 默认值 | 说明 |
|---|---|---|---|
| 无 | 否 | — | App 不读取进程环境变量；在 Scheme 中添加变量不会改变行为，除非先增加相应的读取代码。 |

不要把签名凭据、证书或私钥写入 Scheme、源码或文档。`DEVELOPMENT_TEAM` 当前为空，应由每位开发者在本机 Xcode 中选择。

<!-- VERIFY: 在本机 Xcode 中选择实际的 Apple Developer Team；仓库中的 DEVELOPMENT_TEAM 为空，无法得知应使用的团队标识。 -->

## 默认值

本项目没有单独的默认值文件：构建默认值保存在 `project.pbxproj` 和共享 Scheme 中，依赖默认值保存在 `Package.swift`，渲染、相机、交互和界面默认值直接写在 Swift 源码中。下文逐项列出这些值、修改影响及约束。

## Xcode 工程设置

工程包含一个 `GaussianSplatMobile` application target。`xcodebuild -list` 能解析出 `Debug`、`Release` 两个 build configuration，以及共享的 `GaussianSplatMobile` Scheme；本地 Package 还暴露 `MetalSplatter`、`PLYIO`、`SplatIO` Scheme。没有 App 测试 target。

### 工程级通用与配置差异

下表覆盖 `project.pbxproj` 中显式保存的工程级 build settings。`—` 表示该配置没有显式覆盖，使用 Xcode/SDK 继承值。

| Setting | Debug | Release | 作用与取舍 |
|---|---:|---:|---|
| `ALWAYS_SEARCH_USER_PATHS` | `NO` | `NO` | 禁止旧式用户 Header 搜索路径，减少意外依赖。 |
| `CLANG_ENABLE_MODULES` | `YES` | `YES` | 启用 Clang modules。 |
| `CLANG_ENABLE_OBJC_ARC` | `YES` | `YES` | 对 Objective-C 依赖启用 ARC。 |
| `CLANG_WARN_BOOL_CONVERSION` | `YES` | `YES` | 检查可疑布尔转换。 |
| `CLANG_WARN_CONSTANT_CONVERSION` | `YES` | `YES` | 检查常量窄化或有损转换。 |
| `CLANG_WARN_DOCUMENTATION_COMMENTS` | `YES` | `YES` | 检查文档注释格式。 |
| `CLANG_WARN_EMPTY_BODY` | `YES` | `YES` | 检查意外空语句体。 |
| `CLANG_WARN_ENUM_CONVERSION` | `YES` | `YES` | 检查枚举类型转换。 |
| `CLANG_WARN_INFINITE_RECURSION` | `YES` | `YES` | 检查明显的无限递归。 |
| `CLANG_WARN_INT_CONVERSION` | `YES` | `YES` | 检查整数宽度和符号转换。 |
| `CLANG_WARN_OBJC_LITERAL_CONVERSION` | `YES` | `YES` | 检查 Objective-C 字面量转换。 |
| `CLANG_WARN_UNREACHABLE_CODE` | `YES` | `YES` | 检查不可达代码。 |
| `DEBUG_INFORMATION_FORMAT` | `dwarf` | `dwarf-with-dsym` | Debug 便于快速本地调试；Release 生成 dSYM，增加归档产物但支持符号化崩溃。 |
| `ENABLE_TESTABILITY` | `YES` | — | Debug 允许 `@testable import`；Release 不显式启用。 |
| `ENABLE_USER_SCRIPT_SANDBOXING` | `YES` | `YES` | 限制构建脚本的文件访问。当前 App target 没有 Run Script phase。 |
| `GCC_C_LANGUAGE_STANDARD` | `gnu17` | `gnu17` | C/Objective-C 依赖使用 GNU C17。 |
| `GCC_OPTIMIZATION_LEVEL` | `0` | — | Debug 关闭 GCC 优化。 |
| `GCC_PREPROCESSOR_DEFINITIONS` | `DEBUG=1 $(inherited)` | — | Debug 为 C/Objective-C 定义 `DEBUG`。 |
| `IPHONEOS_DEPLOYMENT_TARGET` | `18.0` | `18.0` | 最低 iOS 18.0；下调前必须同时审查本地 Package 平台声明和所用 API。 |
| `MTL_ENABLE_DEBUG_INFO` | `INCLUDE_SOURCE` | `NO` | Debug 将 Metal 源码纳入调试信息；Release 关闭以减小开销。 |
| `MTL_FAST_MATH` | `YES` | `YES` | 两种配置都允许 Metal 快速数学优化；速度更高，但不承诺严格 IEEE 精度。 |
| `ONLY_ACTIVE_ARCH` | `YES` | — | Debug 只编译当前架构以缩短构建；Release 使用默认架构集合。 |
| `SDKROOT` | `iphoneos` | `iphoneos` | 使用 iPhoneOS SDK；target 另行允许真机与模拟器平台。 |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `DEBUG $(inherited)` | — | 仅 Debug 定义 Swift `DEBUG`。App 源码当前没有消费该条件。 |
| `SWIFT_OPTIMIZATION_LEVEL` | `-Onone` | — | Debug 不优化，便于断点和变量检查，但大型 PLY 解析明显慢于 Release。 |
| `COPY_PHASE_STRIP` | — | `YES` | Release 复制产物时剥离符号。 |
| `ENABLE_NS_ASSERTIONS` | — | `NO` | Release 关闭 Foundation assertions。 |
| `SWIFT_COMPILATION_MODE` | — | `wholemodule` | Release 使用 whole-module 编译，换取优化机会但增加编译工作。 |
| `VALIDATE_PRODUCT` | — | `YES` | Release 验证最终产物。 |

Project 和 target 的默认 configuration 都是 `Release`。这只决定未指定 configuration 时的默认值；实际运行仍以 Scheme 动作为准。

### Target 设置

Debug 与 Release 的 target 设置完全相同。

| Setting | 当前值 | 作用、约束与修改影响 |
|---|---|---|
| `ASSETCATALOG_COMPILER_APPICON_NAME` | `AppIcon` | 必须与 `Assets.xcassets/AppIcon.appiconset` 名称一致；改名需同步更新资源目录。 |
| `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` | `AccentColor` | 全局强调色资源名；当前颜色为 sRGB `(0.000, 0.820, 1.000, 1.000)`。 |
| `CODE_SIGN_STYLE` | `Automatic` | Xcode 自动管理签名；改为 Manual 后需自行配置证书与 provisioning profile。 |
| `CURRENT_PROJECT_VERSION` | `1` | Bundle build number；发布新构建时通常递增。 |
| `DEVELOPMENT_TEAM` | 空字符串 | 仓库不固定团队；真机安装和归档通常需要在本机选择 Team。 |
| `ENABLE_PREVIEWS` | `YES` | 允许 SwiftUI Preview 构建。 |
| `GENERATE_INFOPLIST_FILE` | `YES` | Info.plist 由 build settings 生成，仓库没有独立 plist。 |
| `INFOPLIST_KEY_CFBundleDisplayName` | `3DGS Mobile` | 主屏幕显示名。 |
| `INFOPLIST_KEY_LSApplicationCategoryType` | `public.app-category.graphics-design` | App Store 分类为 Graphics & Design。 |
| `INFOPLIST_KEY_UIApplicationSceneManifest_Generation` | `YES` | 自动生成 scene manifest。 |
| `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents` | `YES` | 声明支持间接输入事件。 |
| `INFOPLIST_KEY_UILaunchScreen_Generation` | `YES` | 自动生成 launch screen。 |
| `INFOPLIST_KEY_UIStatusBarStyle` | `UIStatusBarStyleLightContent` | 使用浅色状态栏内容；App 同时强制深色外观。 |
| `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` | Portrait、Landscape Left、Landscape Right | 支持竖屏和两个横屏方向，不含 Upside Down。 |
| `IPHONEOS_DEPLOYMENT_TARGET` | `18.0` | target 最低系统版本，与工程级和 Package 平台声明一致。 |
| `LD_RUNPATH_SEARCH_PATHS` | `$(inherited)`、`@executable_path/Frameworks` | 从 App 内嵌 Frameworks 路径加载动态依赖。 |
| `MARKETING_VERSION` | `1.0` | 用户可见版本号。 |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.example.GaussianSplatMobile` | 示例标识；用于签名或发布前应改为团队拥有的唯一反向域名。 |
| `PRODUCT_NAME` | `$(TARGET_NAME)` | 产物名为 `GaussianSplatMobile.app`。 |
| `SUPPORTED_PLATFORMS` | `iphoneos iphonesimulator` | 可为 iPhone 真机与 iOS Simulator 构建。 |
| `SUPPORTS_MACCATALYST` | `NO` | 不生成 Mac Catalyst 版本。 |
| `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` | `NO` | 不允许以 Designed for iPhone/iPad 方式在 Mac 上运行。 |
| `SWIFT_EMIT_LOC_STRINGS` | `YES` | 编译器抽取可本地化字符串；仓库当前没有字符串目录。 |
| `SWIFT_STRICT_CONCURRENCY` | `complete` | 启用完整并发检查，提高数据竞争安全性，也会使迁移旧代码更严格。 |
| `SWIFT_VERSION` | `6.0` | App target 使用 Swift 6 语言模式。 |
| `TARGETED_DEVICE_FAMILY` | `1` | 仅 iPhone，不包含 iPad family `2`。 |

项目元数据还记录 `CreatedOnToolsVersion = 26.0`、`LastSwiftUpdateCheck = 2600`、`LastUpgradeCheck = 2600`、`compatibilityVersion = Xcode 14.0`、开发区域 `zh-Hans`，已知区域为 `zh-Hans`、`en`、`Base`。这些是工程格式/升级元数据，不是运行时开关。

## Scheme 设置

仓库共享的 `GaussianSplatMobile` Scheme 设置如下。

| 动作 | Build configuration | 其他显式设置 |
|---|---|---|
| Build | 由下游动作决定 | 并行构建 `YES`；构建隐式依赖 `YES`；架构 `Automatic`；App 对 Test、Run、Profile、Archive、Analyze 全部启用 |
| Test | `Debug` | LLDB debugger/launcher；继承 Scheme 的启动参数和环境；没有 testable target |
| Run | `Release` | LLDB debugger/launcher；默认工作目录；不忽略持久状态；允许定位模拟；无启动参数或环境变量 |
| Profile | `Release` | 继承启动参数和环境；默认工作目录 |
| Analyze | `Debug` | 静态分析 Debug 配置 |
| Archive | `Release` | 归档完成后在 Organizer 中显示 |

Run 使用 `Release` 是一个重要的性能配置：改成 Debug 会获得更好的断点体验，但 `-Onone` 会降低大型模型的解析与执行速度。需要逐语句调试时临时切换，性能测量则保持 Release，并尽量脱离调试器从设备主屏幕启动。

## 本地依赖与版本锁定

Xcode 通过 `XCLocalSwiftPackageReference` 引用 `Vendor/MetalSplatter`，所以 App 构建不需要下载远程 Swift Package。App target 直接链接 `MetalSplatter` 和 `SplatIO`；`SplatIO` 再依赖 `PLYIO`。

| 项目 | 当前值 | 生效阶段与取舍 |
|---|---|---|
| Package 路径 | `Vendor/MetalSplatter` | 编译时；移动目录必须同步修改 Xcode 本地包引用。 |
| Swift tools version | `6.1` | Package manifest 解析时。 |
| Package 平台 | `.iOS(.v18)` | Package 最低 iOS 18；与 App deployment target 一致。 |
| Swift language mode | `.v6` | Package targets 使用 Swift 6。 |
| App 直接产品 | `MetalSplatter`、`SplatIO` | 前者提供 Metal 渲染，后者提供场景读取。 |
| Package 内部产品 | `PLYIO`、`SplatIO`、`MetalSplatter` | `PLYIO` 是 `SplatIO` 的内部依赖，App 未直接链接该产品。 |
| 外部 Package 依赖 | 无 | `Package.swift` 没有 `dependencies`；仓库也没有 `Package.resolved`。 |
| 排除源码 | `SplatIO/Sources/SPZSceneReader.swift`、`SPZSceneWriter.swift` | 编译时排除 SPZ 实现，避免其可选依赖进入移动工程。 |
| Metal 资源 | `MultiStageRenderPath.metal`、`SingleStageRenderPath.metal`、`SplatProcessing.metal` | 由 Package 的 `.process("Resources")` 编入 `Bundle.module`。 |

[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) 声明 vendored 源码来自上游提交 `2b965de1934de38dda1c71cf90bf798aa948a14c`。本地引用本身把构建固定在仓库内这份源码，不会自动漂移；但 vendored 目录没有独立 `.git` 元数据或内容清单可将其重新证明为该上游提交。

<!-- VERIFY: 对照上游提交 2b965de1934de38dda1c71cf90bf798aa948a14c 审核 Vendor/MetalSplatter 内容；仓库只能验证该 revision 声明，不能独立证明内容完全对应。 -->

## 资源与支持的场景格式

### 打包资源

App 的 Resources build phase 包含以下三项：

| 资源名 | 当前内容 | 改动要求 |
|---|---|---|
| `Assets.xcassets` | `AppIcon` 和 `AccentColor` | 资源集改名时同步修改 target build settings。 |
| `sample_scene.ply` | 轻量回退资源；175,745 个 SH0 高斯；9,842,082 bytes；SHA-256 `5108445bc1594d6b6c5cb862b8c5084caf339e742b397f2295230684e576989b` | 文件名或扩展名变化时同步修改 `ContentView.bundledModelURL` 和 Xcode 资源引用。 |
| `drjohnson_full_sh3.ply` | 首选压力验证资源；3,177,554 个 SH3 高斯；788,034,924 bytes；当前文件 SHA-256 `92f4898839ec4ad7f197cf6c74b89918b35ea712b4e41435593ccb152d22b7f5` | `Scripts/download_validation_scene.sh` 下载并验证点数/schema/精确大小，再计算摘要写入 manifest；它不与预置可信摘要比对。当前 target 会把约 752 MiB 文件复制进 App bundle，不适合作为生产交付策略。 |

`AppIcon` 包含 20、29、40、60 point 的 iPhone 2x/3x 图标及 1024×1024 marketing 图标。`Design/AppIcon-Master.png` 是 1254×1254 的设计源文件，不在 Resources build phase 中。

`ContentView.bundledModelURL` 首先查找 `drjohnson_full_sh3.ply`，不存在时才回退到 `sample_scene.ply`。轻量样例是 PLY 1.0 binary little-endian，声明 `175745` 个 `vertex`，只含 `f_dc_0...2`，因此是 SH0。验证资源同样是 binary little-endian，包含连续的 `f_rest_0...44`，因此是 SH3。其来源、许可提醒和机器可读元数据记录在 [`ValidationAssets/README.md`](../ValidationAssets/README.md) 与 [`drjohnson_full_sh3.json`](../ValidationAssets/drjohnson_full_sh3.json) 中。

### 文件格式

| 扩展名 | 读取器状态 | 约束 |
|---|---|---|
| `.ply` | 支持，且是 App 当前自动选择的格式 | 必须是训练后的 3DGS `vertex` 数据。必需 Float32 属性：`x/y/z`、`scale_0...2`、`opacity`、`rot_0...3`。选择 Float32 `f_dc_0...2` 球谐颜色路径时，读取器才检查 `f_rest_*`：只接受从 `f_rest_0` 开始连续的 0、9、24、45 个 Float32 属性，分别映射 SH0、SH1、SH2、SH3；其他数量、不连续编号、无效名称或非 Float32 类型会被拒绝。若改用 Float32 或 UInt8 `red/green/blue` fallback，读取器将颜色转换为 SH0，不检查额外的 `f_rest_*` 属性。 |
| `.splat` | vendored `AutodetectSceneReader` 支持 | 当前 `ContentView` 只查找两个 `.ply` 名称；使用 `.splat` 时必须更换打包资源并修改名称/扩展名。每个固定长度记录必须完整，否则读取器报 unexpected EOF。`.splat` 颜色路径为 SH0。 |
| `.spz` | 不支持当前构建 | 格式枚举能识别扩展名，但自动读取器明确抛错，且 SPZ reader/writer 被 Package manifest 排除。 |
| 其他扩展名 | 不支持 | 自动读取器无法确定格式。 |

PLY 底层输入流每次最多读取 16 KiB；reader 会保留不足一条记录的尾部字节，并在下次读取后继续解码，因此 I/O 分块切在记录中间不会丢数据。`SceneChunkLoader` 通过 `reader.read()` 消费异步批次，最多累计 65,536 个 `SplatPoint` 就编码为最终 `.storageModeShared` Metal buffer，并对该 chunk 做 Morton locality sort；返回值只持有 `[SplatChunk]`，不保留完整场景的 `[SplatPoint]`。加载过程中还使用 Welford 单遍算法计算中心与 RMS 半径，并拒绝同一场景内混合 SH 阶数。

这种实现把 loader 自己的 `pendingPoints` 和逐 chunk 编码/Morton 临时限制在一个 scene chunk 附近，并移除显式整场 `readAll()` 聚合；但两级 reader `AsyncThrowingStream` 没有有界 buffering/backpressure，多个已解码 batch 仍可能排队，所以端到端临时解码峰值没有由 65,536 建立硬上界。它也不是按视点流入/淘汰的运行时 streaming：所有 chunk 的基础属性和高阶 SH 仍会常驻 Metal shared buffer。候选预算只限制每帧参与深度排序与绘制的均匀采样集合，不减少全量属性常驻内存，也不是遮挡剔除或 LOD。

## 运行时渲染默认值

这些值由源码在启动或模型加载时设置。它们不是用户偏好；修改后必须重编译。表中的“建议试验范围”是根据代码硬约束给出的保守起点，不是仓库内的自动校验，改动后仍需在目标设备上验证画质、内存和帧时间。

| 值 | 当前默认 | 影响与取舍 | 约束/建议试验范围 |
|---|---:|---|---|
| MTKView / renderer color format | `.bgra8Unorm_srgb` | sRGB 输出；两处必须完全一致，否则 pipeline 与 drawable 不匹配。 | 保持两处同步；改格式需验证色彩空间和 pipeline。 |
| Depth format | `.invalid` | 不分配深度纹理，减少带宽；无法输出深度。 | 若启用，MTKView、renderer 和传入 `depthTexture` 必须同步。 |
| Sample count | `1` | 关闭 MSAA，节省显存和带宽。 | 必须在 view、renderer、attachment 间一致；当前路径安全值为 `1`。 |
| `framebufferOnly` | `true` | drawable 仅供渲染，提高可优化性；不能用于通用计算/读取。 | 只有确需采样或计算访问 drawable 时才改为 `false`。 |
| 连续绘制 | `enableSetNeedsDisplay=false`、`isPaused=false` | MTKView 持续请求帧。 | 暂停可省电，但需增加显式恢复/按需刷新逻辑。 |
| 帧率请求 | 固定 `60` | 与自适应候选阈值共同构成 60 FPS 目标；比请求 120 FPS 更适合大场景的排序与带宽预算。 | 正整数；若改成 30/120，必须同步重设下述升降档阈值。 |
| Clear color | RGBA `(0.025, 0.03, 0.045, 1)` | 深蓝黑背景；在 view 和 renderer 两处重复。 | 分量保持 `0...1`，并同步两处。 |
| `maxViewCount` | `1` | 单视口；减少 uniform 和 vertex amplification 需求。 | vendored renderer 硬上限为 `2`，当前 iPhone UI 保持 `1`。 |
| `maxSimultaneousRenders` | `3` | 三个 in-flight uniform slots 提高 CPU/GPU 流水并行；数值越大，共享 uniform buffer 线性增加。 | 必须 `>=1`，否则 buffer/取模逻辑无效；建议先在 `1...3` 内测量。 |
| `highQualityDepth` | `false` | 当前没有深度输出；避免多阶段深度路径。 | 只有同时配置有效 depth format/texture 时才有意义。 |
| 场景解析优先级 | detached task `.userInitiated` | 在非 MainActor 任务中完成读取、分块编码和 locality sort，避免阻塞 SwiftUI；高优先级可能与其他用户任务竞争。 | 可降为 utility 以减小竞争，但会增加可见等待。 |
| PLY I/O buffer | `16 KiB` | 小缓冲降低单次临时内存，增加读调用；reader 会拼接跨边界记录。 | `>0`；更改 `PLYReader.Constants.bodyBufferLen` 后同时验证 ASCII、大小端 binary 与超长记录。 |
| Scene chunk | `65,536 splats` | 限制 `SceneChunkLoader.pendingPoints` 和单个 Metal buffer 的规模，并影响 chunk 数；越小越早清空显式 pending 数组，但 chunk 管理开销更高。 | `>0`；还需满足每个 Metal buffer 的 `maxBufferLength`。reader 的 `AsyncThrowingStream` 当前没有有界 buffering/backpressure，所以该值不是整个解码链路或加载峰值的硬上限。 |
| Locality sort | 每个 scene chunk 一次 | `SceneChunkLoader` 在注册前按 10-bit/axis Morton code 重排基础属性与对应 SH，提高局部性；付出一次 CPU 排序并改变文件顺序。 | 边界为每轴均值 ± `2.5σ`；`addChunks(..., sortByLocality: false)` 防止重复排序。 |
| 初始候选上限 | `1,000,000` | 初次只从完整扁平 chunk 序列中做确定性均匀采样并排序/绘制至多 100 万点；缩短帧排序并限制索引内存，但可能漏掉细节。 | 实际值为 `min(scene count, 1,000,000)`。 |
| 候选下限 / 上限 | `250,000` / `1,250,000` | 自适应范围越大，画质潜力越高但 CPU 排序、索引 buffer 和顶点处理成本越高。 | 下限必须为正，上限应不小于下限；实际上限还受场景点数限制。 |
| 候选调节间隔 | `3 s` | 避免每个 0.75 秒统计窗口都改变预算而振荡；响应更慢但更稳定。 | 应不短于 FPS 统计窗口。 |
| 候选降档条件 | FPS `<55`，预算乘 `0.8` | 快速降低排序/绘制压力以恢复流畅度，代价是减少可见高斯。 | 结果不低于 250,000。 |
| 候选升档条件 | FPS `>=59`、平均 GPU `>0` 且 `<12 ms`，预算乘 `1.1` | 只有帧率与可用的正 GPU duration 都有余量才逐步提高细节；GPU duration 为零或不可用时不升档。 | 结果不高于场景点数与 1,250,000。 |
| FPS 统计窗口 | `0.75 s` | 窗口短则反馈快、抖动大；长则稳定、滞后。 | 必须 `>0`；建议约 `0.5...2 s`。 |
| 自动场景半径 | `max(RMS radius × 2.5, 0.1)` | 过滤远端离群点对取景的影响，同时保证非零尺度。 | 乘数与相机 fitted distance 联动；最小值保持 `>0`。 |
| Render access timeout | 未传参，使用 Package 默认 `0.1 s` | 等待 in-flight/exclusive access；更大可减少丢帧但阻塞更久。 | `>=0`；`0` 表示不等待。 |
| Sort timeout | 未传参，使用 Package 默认 `0.1 s` | 等待首个有效排序；更大可减少瞬时空帧但阻塞更久。 | `>=0`；`0` 禁止阻塞。 |
| Color store action | `.store` | 保留颜色 attachment 供显示。 | 当前 drawable 展示路径必须存储。 |
| Depth/rate map/layering | `depthTexture=nil`、`rasterizationRateMap=nil`、`renderTargetArrayLength=0` | 单层、无深度、无 variable-rate shading 的简单路径。 | 启用任一能力都需同时调整纹理、视口和 renderer 配置。 |

`SplatRenderer` 内部还有与 app-facing 配置相关的硬限制：最多 `2` 个视图；chunk index 使用 UInt16，最多登记 `UInt16.max` 个 chunk；深度排序有 `3` 个引用计数 index buffer；locality sort 使用每轴均值 ± `2.5` 个标准差作为量化边界；quad 绘制索引模板覆盖 `1024` 个 splat，其余通过 instancing 复用。这些值位于 vendored 实现中，升级依赖时可能变化，不建议由 App 单独覆盖。候选采样按完整 chunk 序列的全局扁平索引等距选取，不做重要性、屏幕面积、视锥或遮挡判断。

## 相机与交互默认值

| 值 | 当前默认/公式 | 影响与取舍 | 约束/建议试验范围 |
|---|---|---|---|
| 垂直 FOV | `60°` | 更大可见范围更广但边缘透视更强；更小更接近长焦。 | 数学上需在 `0°...180°` 内；实际建议先试 `30°...100°`。 |
| 重置 yaw / pitch | `3.0 rad` / `-0.1 rad` | 决定 INRIA 风格模型的初始观察方向。 | yaw 可环绕；pitch 应保持在下述夹角范围。 |
| 加载前 distance / fitted distance | `5` / `5` | 只在模型尚未 frame 前使用；加载后会被半径公式覆盖。 | 必须为正。 |
| 场景半径下限 | `0.1` | 防止空尺度导致相机和裁剪面退化。 | 必须 `>0`。 |
| 自动取景距离 | `max(sceneRadius × 3.3, 0.5)` | 乘数大则模型更小、留白更多；小则填满屏幕但更易裁切。 | 保持正值；建议联动 FOV 和 clip planes 调试。 |
| 拖动灵敏度 | `0.006 rad/point` | 越大旋转越快，也越难精细控制。 | `>0`；建议从 `0.003...0.01` 试验。 |
| 旋转按钮步长 | `15°`/次 | 左右按钮改变 yaw，上下按钮改变 pitch；离散步长便于可重复观察，精细度低于拖动。 | pitch 继续使用 `-1.45...1.45 rad` 夹限；yaw 对 $2\pi$ 取余。 |
| Pitch clamp | `-1.45...1.45 rad` | 防止越过极点造成翻转。 | 保持绝对值小于 $\pi/2$；当前约 ±83.1°。 |
| Magnification 下限 | `0.05` | 防止接近零的手势缩放因子导致除零或距离暴增。 | 必须 `>0`。 |
| 缩放按钮倍率 | `1.2`/次 | 放大时距离除以 `1.2`，缩小时距离乘 `1.2`；与捏合共享距离范围。 | 必须 `>1`；仍夹限到 `0.15 × radius ... 20 × radius`。 |
| Zoom distance | `0.15 × radius ... 20 × radius` | 控制最近和最远观察距离。范围更宽会增加穿模或精度压力。 | 两端均需 `>0` 且下限小于上限。 |
| PLY up calibration | 绕 Z 轴旋转 $\pi$ | 将常见 PLY 方向调整到当前视图约定。 | 模型坐标系不同才修改；方向错误会使场景倒置。 |
| Near plane | `max(0.01, distance - 3 × radius)` | 越近能容纳贴近相机的内容，但降低深度精度；当前不写 depth，仍影响投影。 | 必须 `>0`。 |
| Far plane | `max(near + 10, distance + 5 × radius)` | 越远可见范围更大；需始终大于 near。 | 公式保证 `far > near`。 |
| Aspect ratio 下限 | `0.001` | 避免 drawable 尚未形成时除零。 | 必须 `>0`。 |
| 重置手势 | 双击；右上角按钮 | 双击次数越高越不易误触，但更难发现。 | 当前为 `2` 次。 |
| 拖动最小距离 | `0` points | 立即响应触摸；可能更容易将点击识别为拖动。 | `>=0`。 |
| 相机按钮可用状态 | 仅 `.ready` | 加载前禁用四向旋转和缩放，避免用户操作被加载完成后的自动取景覆盖。 | 禁用时 opacity 为 `0.45`；重置按钮不受该条件限制。 |

## 界面与状态显示常量

这些值只改变视觉或诊断显示，不改变 3DGS 数据和渲染算法。

| 类别 | 当前值 | 调整影响/安全范围 |
|---|---|---|
| 颜色外观 | `.preferredColorScheme(.dark)` | 强制深色界面；移除后跟随系统。 |
| 叠加渐变 | 顶部黑色 alpha `0.58`，底部 `0.52` | 提高文字对比但遮暗模型；alpha 保持 `0...1`。 |
| 主布局 | spacing `12`，水平 padding `16`，垂直 padding `12` | 正值越大越疏朗、可用渲染面积越小。 |
| 标题 | HStack spacing `10`、VStack spacing `2`、tracking `1.4` | 仅排版；避免负 frame/padding。 |
| 状态卡 | spacing `12/4/3`、最小 spacer `8`、padding `14`、corner radius `18` | 仅影响密度和轮廓。 |
| 状态卡描边 | 白色 alpha `0.12`、width `1` | alpha `0...1`，线宽 `>=0`。 |
| 状态文本 | subtitle 最多 `2` 行；GPU/排序耗时显示 `1` 位小数；候选数使用本地化整数 | 只影响截断与格式。 |
| 浮层按钮 | `42×42` points；描边 alpha `0.14`/width `1`；按下 scale `0.92` | 尺寸越小越难触控；scale 应 `>0`。 |
| 相机按钮组 | `6` 个按钮，HStack spacing `8` | 顺序为左、上、下、右、缩小、放大；全部提供中文 accessibility label。窄屏调整尺寸或间距后应验证不截断。 |
| 说明页 detents | `.medium`、`.large` | 限制 sheet 的两个高度。 |
| 文件/属性大小单位 | 除以 `1,048,576`，显示 `1` 位小数 | 状态摘要明确标记为 `MiB`；属性值是基础点 buffer 加高阶 SH buffer 的理论字节数。 |
| 加载耗时 | 秒，显示 `2` 位小数 | 只影响状态文本。 |
| 排序耗时 | 秒乘 `1,000` 转毫秒，显示 `1` 位小数 | 只影响诊断显示。 |
| 样例说明 | 当前点数、SH 阶数与 chunk 数来自 `RenderStatus`；“工程默认包含轻量样例、完整文件由脚本下载”是静态文案 | 动态元数据不需随模型修改；若改变资源交付方式，应同步修改静态说明。 |

## 结构化日志默认值

App 使用 Apple Unified Logging，没有独立日志配置文件或运行时日志开关。subsystem 优先取运行时 Bundle Identifier，取不到时回退到 `com.example.GaussianSplatMobile`；源码定义 `Lifecycle`、`State`、`SceneLoading`、`Rendering`、`Camera` 五个 category。

| 值 | 当前默认 | 影响与取舍 |
|---|---:|---|
| Scene upload progress | 第 `1` 个 chunk，之后每 `8` 个 chunk | 能观察大文件持续前进而不逐 chunk 刷屏；调小间隔会增加日志量和格式化成本。 |
| 慢排序阈值 | `50 ms` | 排序耗时达到阈值才发 warning；阈值太低会把正常抖动当异常。 |
| 慢排序 warning 节流 | `5 s` | 最多每 5 秒记录一次慢排序；首次成功排序始终单独记录 notice。 |
| 相机日志 | reset/frame 立即记录；drag/pinch 只在手势结束记录；按钮每次点击记录 | 避免对连续手势的每个 `onChanged` 写日志；按钮是离散事件，因此逐次记录。 |
| 数据可见性 | 文件名、数量、尺寸、耗时和相机数值标为 `.public` | 便于 Console 排障；代码不记录模型完整路径或逐点属性。若文件名本身敏感，应移除 `.public`。 |

加载取消由 `MetalSplatView.Coordinator.deinit` 和 `dismantleUIView` 触发并记录，关闭 App/Simulator 时出现取消或 dismantle 日志不等同于 crash。真正异常应结合 `fault`/`error`、异常类型和系统 crash report 判断。

## 必需与可选设置

| 必需项 | 缺失或不匹配时的行为 |
|---|---|
| 支持 Metal 的设备与可创建的 `MTLCommandQueue` | renderer 初始化失败，界面显示“当前设备不支持 Metal”。 |
| Bundle 中至少存在 `drjohnson_full_sh3.ply` 或 `sample_scene.ply` | App 优先选择前者并回退到后者；两者都不存在时 `Bundle.main.url` 返回 `nil`，当前错误文案显示“App 包中缺少 sample_scene.ply”。 |
| 非空、格式受支持且场景内 SH 阶数一致 | 读取错误、零点场景或混合 SH 阶数都会进入失败状态；空场景提示没有可渲染的高斯点。 |
| `Vendor/MetalSplatter` 本地包及 `MetalSplatter`/`SplatIO` products | Xcode 无法解析 imports 或链接 target。 |
| AppIcon/AccentColor 名称与 target 设置一致 | 资源目录编译警告/错误，或应用缺少预期图标/强调色。 |
| 有效签名设置 | Simulator 不依赖真实 Team；真机安装/Archive 需要本机可用的签名身份与 provisioning。 |

除此之外没有启动时强制验证的外部设置。Bundle identifier、版本号、显示名、分类和方向属于发布/产品配置，不会由 App 自己读取并拒绝启动。

## 每个环境的覆盖方式

项目没有 development/staging/production 三套配置文件。唯一的编译环境划分是 Debug 与 Release：

1. Debug 定义 `DEBUG`、启用 testability、关闭 Swift/GCC 优化，并包含 Metal 调试源码。
2. Release 使用 whole-module Swift 编译、dSYM、产品验证和剥离，并关闭 Metal debug info 与 NS assertions。
3. 两者共用 iOS 18、Swift 6、签名、Bundle ID、资源名和所有 Info.plist 生成值。
4. 共享 Scheme 的 Run/Profile/Archive 使用 Release，Test/Analyze 使用 Debug。

若未来需要环境覆盖，建议新增明确命名的 `.xcconfig`，让 Xcode configuration 选择非秘密值；秘密和签名材料留在本机或 CI secret store。加入运行时开关时，应集中到一个类型安全的配置结构，并为缺失值提供验证错误，而不是在各 View/Renderer 中直接读取环境。

## 更改配置的核对清单

1. 修改 deployment target 时，同时核对工程、target 和 `Vendor/MetalSplatter/Package.swift` 的 iOS 版本。
2. 修改颜色格式、深度格式、sample count 或 clear color 时，同步 MTKView 与 `SplatRenderer` 初始化参数。
3. 替换模型时，同步文件名、扩展名、Resources build phase、`ContentView.bundledModelURL`、缺失资源错误文案和说明页中的静态资源文案；点数、SH 与 chunk 数由运行时状态生成。
4. 改 AppIcon/AccentColor 资源集名称时，同步 target 的 asset catalog compiler settings。
5. 改 Bundle ID 或签名方式后，在目标真机上重新验证签名与安装；不要提交个人 provisioning 文件。
6. 改相机 FOV、取景距离或裁剪面时，使用极小、极大和偏心模型验证是否裁切、翻转或出现数值异常。
7. 改并发帧数、scene chunk、候选预算或模型规模时，测量峰值 CPU/Metal shared 内存、加载耗时、排序耗时、GPU 时间、持续帧率和温升。
8. 调整旋转/缩放按钮时，验证加载期禁用状态、VoiceOver 标签、横竖屏布局，以及与拖动、捏合、重置共用的 pitch/distance 夹限。
