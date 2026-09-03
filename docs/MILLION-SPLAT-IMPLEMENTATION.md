<!-- generated-by: codex -->
# 300 万 SH3 / 60 FPS 目标实现说明

本文记录仓库针对“至少 300 万个 SH3 Gaussian、iPhone 15 Pro、目标 60 FPS”完成的实现，以及它没有承诺的部分。当前验证资产保留完整的 3,177,554 个高斯，不再为凑整裁剪到 300 万。它是本次改造后的现状文档；`readAll()`、单一 chunk、PLY 仅支持 SH0/SH3、全量索引排序均属于改造前的较早实现/历史基线。

## 1. 结论与诚实边界

当前实现可以：

- 读取 Graphdeco 风格 SH0、SH1、SH2、SH3 PLY；
- 按 65,536 点构造多个最终 `SplatChunk`，不再保留完整场景 `[SplatPoint]`；
- 让完整 300 万 SH3 属性常驻 Metal shared buffer；
- 把三份排序索引和 CPU 排序临时项限制在 100 万初始候选，而不是 300 万全量；
- 以 60 Hz 驱动 `MTKView`，统计 GPU 完成帧而非只统计 CPU submit；
- 根据完成 FPS 和 GPU 时间，在 25 万～125 万候选之间调整预算；
- 显示 splat 总数、SH 阶数、chunk 数、属性 MiB、候选数、GPU ms 与 CPU sort ms；
- 提供左、上、下、右四向旋转和缩小、放大六个屏幕相机按钮；
- 下载完整 3,177,554 点的 Dr Johnson SH3 PLY，验证点数/schema/精确大小且不裁剪记录，并记录计算出的 SHA-256；当前脚本不与预置可信摘要比对。

当前实现**没有**做到：

- 保证在任意相机、分辨率、热状态下把 300 万点全部画出仍为 60 FPS；
- 空间树、按相机磁盘流式 residency、chunk 淘汰；
- 独立的 GPU project/cull/compact 预处理阶段、逐屏幕 tile binning/sort、遮挡剔除；当前 Metal 顶点路径仍会逐高斯投影，并剔除相机后方、clip 范围外或宽松视口外的高斯；
- 用图像质量指标证明 100 万候选与 300 万全量完全等价；
- 在本仓库环境中替代 iPhone 15 Pro 真机完成持续热稳定性验收。

设计取舍是：**全量属性保证场景可用，有界候选保证帧预算可控**。因此 60 FPS 是运行时控制目标，不是“300 万个高斯每帧全部经过 vertex/fragment”的承诺。

## 2. 新的数据流

```text
PLY InputStream
  → PLYReader：16 KiB 字节缓冲，完整记录解析
  → SplatPLYSceneReader：小批 [SplatPoint]
  → SceneChunkLoader：累计最多 65,536 点
      ├─ Welford 在线 center / radius 统计
      ├─ 验证全场 SH degree 一致
      ├─ 编码 32 B/点基础 Metal buffer
      ├─ 编码 SH1/2/3 Float16 高阶 buffer
      └─ chunk 内 Morton locality 重排
  → [SplatChunk]：只保留最终 Metal buffer
  → SplatRenderer.addChunks：一次独占注册全部 chunk
  → SplatSorter：从全量常驻属性确定性抽取有界候选
  → 后台从远到近排序
  → Metal quad instancing + alpha blending
```

关键代码：

- [`SceneChunkLoader.swift`](../GaussianSplatMobile/Renderer/SceneChunkLoader.swift)
- [`GaussianSplatRenderer.swift`](../GaussianSplatMobile/Renderer/GaussianSplatRenderer.swift)
- [`SplatPLYSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPLYSceneReader.swift)
- [`SplatChunk.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatChunk.swift)
- [`SplatSorter.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatSorter.swift)
- [`SplatRenderer.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatRenderer.swift)

## 3. 为什么分成 65,536 点一个 chunk

它首先是**加载工作集 chunk**，还不是空间 tile 或可淘汰 LOD 节点。选择 $65,536=2^{16}$ 的原因是：

- 300 万点约形成 46 个 chunk，远低于 `UInt16` chunk index 上限；
- SH3 原始 PLY 语义数据每批足够大，可摊薄分配和函数调用；
- Morton 排序的索引、visited、临时数组只针对一个 chunk；
- `SceneChunkLoader` 的显式 pending `[SplatPoint]` 每批最多 65,536 点，构建完成即清空；但读取链路的 `AsyncThrowingStream` 未指定有界 buffering/backpressure，生产者可能领先消费者并排队，因此端到端加载峰值仍需实测或通过背压改造建立上界。

取舍：文件相邻记录不保证空间相邻，所以这些 chunk 不能直接用于视锥剔除或距离 residency。每个 chunk 内的 Morton 排序改善局部访问，但 chunk 之间仍按输入记录范围分界。真正的大场景流式方案仍应离线按空间树分块，见 [LARGE-SCENE-RENDERING.md](LARGE-SCENE-RENDERING.md)。

## 4. 在线 center / radius：为什么不需要第二遍

加载器使用 Welford 更新均值。第 $n$ 个位置向量为 $\mathbf{x}_n$，旧均值为 $\boldsymbol{\mu}_{n-1}$：

$$
\boldsymbol{\delta}=\mathbf{x}_n-\boldsymbol{\mu}_{n-1}
$$

读作“新位置减旧均值”，得到新点相对已有中心的向量偏差。向量是同时包含 $x,y,z$ 三个分量的数。

$$
\boldsymbol{\mu}_n=\boldsymbol{\mu}_{n-1}+\frac{\boldsymbol{\delta}}{n}
$$

分子是向量偏差，分母是已读点数；它让新点以 $1/n$ 权重修正均值。代码对应 `mean += delta / Float(count)`。

$$
M_{2,n}=M_{2,n-1}+\boldsymbol{\delta}\cdot(\mathbf{x}_n-\boldsymbol{\mu}_n)
$$

点积把三个方向的乘积相加成一个标量，累计相对中心的平方距离。最终相机取景半径为：

$$
r=\max\left(2.5\sqrt{\frac{M_{2,N}}{N}},\ 0.1\right)
$$

根号内是平均平方距离，开平方得到均方根半径，再乘 2.5 覆盖大部分场景；`0.1` 防止退化场景产生无效相机裁剪面。

取舍：它与旧实现“先求精确均值、再做第二遍平方距离”在浮点舍入上可能有极小差异，但不需要完整数组，数值稳定性也好于直接累计各位置向量的平方和。

## 5. SH0～SH3 PLY 规则

Graphdeco PLY 的 `f_dc_0...2` 是 SH0。额外 `f_rest_*` 标量数必须是：

| SH degree | 每通道总系数 | 额外 RGB 标量数 | 合法属性范围 |
|---:|---:|---:|---|
| 0 | 1 | 0 | 无 `f_rest_*` |
| 1 | 4 | 9 | `f_rest_0...8` |
| 2 | 9 | 24 | `f_rest_0...23` |
| 3 | 16 | 45 | `f_rest_0...44` |

reader 会拒绝缺号、重复后缀、非 Float32 或其他数量。文件按“所有 R、所有 G、所有 B”保存；reader 依据每通道数量重排成逐系数 RGB triplet。`SplatChunk` 还会再次验证同一 chunk 内每点系数数一致，避免错误偏移让 shader 越界读取。

## 6. 内存预算为什么从约 452 MiB 降下来

SH degree 为 $d$ 时，每点常驻属性字节为：

$$
B_{attribute}(d)=32+3\left((d+1)^2-1\right)\times2
$$

读作“32 字节基础属性，加 RGB 三通道乘 SH0 之外的系数数，再乘 Float16 的 2 字节”。SH3 为 $32+90=122$ B/点。

旧的全量排序规划下界是：

$$
M_{old}=N\times122+3N\times8+N\times12
$$

第一项是 SH3 属性；第二项是三份 8 字节 `ChunkedSplatIndex`；第三项是约 12 字节 CPU 排序临时项。$N=3,000,000$ 时约为 452 MiB。

新实现把索引与临时项的规模改为候选数 $C$：

$$
M_{new}=N\times122+3C\times8+C\times12
$$

对原来的 $N=3,000,000$ 目标，初始 $C=1,000,000$ 时规划下界约 383.4 MiB，最大 $C=1,250,000$ 时约 392.0 MiB。完整验证资产取 $N=3,177,554$ 后，对应下界约为 404.0 MiB 和 412.6 MiB。这里没有计入 App、drawable、Metal driver、chunk table 和临时 batch，因此仍需真机观察 `currentAllocatedSize` 与 Jetsam。

注意：`MetalBuffer.ensureCapacity` 不会因候选预算下降而自动缩容。动态 LOD 主要降低排序与绘制工作；若曾扩到 125 万，之后降到 25 万也不会立即归还那部分 buffer capacity。要严格回收需新增可控的 buffer 重建时机。

## 7. 候选抽样与排序

对展平后的全场 $N$ 个点，要选择 $C$ 个候选，第 $k$ 个候选的全局记录下标为：

$$
i_k=\left\lfloor\frac{kN}{C}\right\rfloor,
\qquad 0\le k<C
$$

分子 $kN$ 让候选均匀跨越完整记录范围，分母 $C$ 把范围分成等距区间，向下取整得到现有记录下标。实现只单调遍历 chunk 边界，不构造第二份全场索引。

优点：确定性、无随机抖动、$O(C+chunkCount)$ 生成、内存有界。缺点：它不是重要性采样；若输入顺序严重聚类，可能漏掉小而关键的区域。chunk 内 Morton 重排让等距抽样通常能覆盖更多局部区域，但不能替代基于投影尺寸、opacity、LOD tree 的选择。

候选仍使用 CPU 从远到近比较排序。当前深度键是“到相机位置的欧氏距离”，因此只有相机位置超过小阈值才触发新排序；纯旋转和静止相机都不会重复百万级排序。一次排序完成且没有新请求时，后台任务会退出，而不是继续以 1 ms 间隔轮询；下一次位置或候选预算变化会原子地启动新任务。渲染可继续使用最近完成的旧排序，因此长排序不会直接阻塞 60 Hz submit，但快速相机移动时透明次序可能滞后。

## 8. 60 FPS 控制器

`MTKView.preferredFramesPerSecond` 固定为 60。每个成功 command buffer 的 completion handler 读取 GPU 时间并回到 MainActor 统计完成帧。控制规则：

- 初始候选 100 万；
- 最低 25 万，最高 125 万；
- 至少间隔 3 秒才调整一次；
- 完成 FPS 低于 55 时，候选乘 0.8；
- FPS 至少 59 且平均 GPU 时间小于 12 ms 时，候选乘 1.1；
- 每次变化触发后台重建排序结果，旧有效结果在此期间继续可用。

这是简单的反馈控制器。它没有 p95、热状态、分辨率和相机速度输入，可能在临界负载附近缓慢摆动。生产版本应加入滞回窗口、热状态降级、质量档位与持久化设备 profile。

## 9. 验证资产

运行：

```bash
./Scripts/download_validation_scene.sh
```

脚本下载公开的 Dr Johnson iteration 30000 Graphdeco PLY，并原样保留全部 3,177,554 条二进制记录。它验证：

- `binary_little_endian 1.0`；
- 只有 vertex element，且没有 list property；
- `f_rest_0...44` 连续存在，即 SH3；
- 根据 property 类型计算的 record stride；
- 文件字节数等于原始 header 加 $3,177,554\times stride$，从而排除缺失记录或尾部附加数据；
- 计算完整文件 SHA-256 并写入 manifest；当前不与固定可信摘要比较。

结果位于：

- `ValidationAssets/drjohnson_full_sh3.ply`
- `ValidationAssets/drjohnson_full_sh3.json`

Xcode target 会把完整验证 PLY 作为资源，App 优先加载它；若该文件不存在，代码回退到轻量 `sample_scene.ply`。这让源码仍保留小样例 fallback，但 project resource reference 在执行 Xcode build 时要求先下载验证文件。

把约 752 MiB PLY 放进 App bundle 适合这次压力验证，不适合生产交付。生产方案应改成首次下载到 Application Support、校验 hash 后原地读取，或者采用可寻址压缩/LOD 格式。

## 10. 验收层次

### 已自动验证

- iOS Simulator Debug 全量 Xcode build 成功；
- arm64 generic iOS Release 全量 Xcode build 成功；
- 轻量样例通过新的 3-chunk 加载路径成功显示；
- Simulator 画面显示 175,745 splats、SH0、3 chunks、60 completed FPS；
- Python 工具验证 PLY 的点数、SH3 schema、stride 和精确大小，并计算 SHA-256 写入 manifest；摘要值另与本文记录的基线人工核对，脚本本身不含固定摘要断言。

此前裁剪到 300 万点的结果只用于第一次验收，现已由完整 3,177,554 点资产替代。完整文件 record stride 为 248 B，大小为 788,034,924 B（751.5 MiB），SHA-256 为 `92f4898839ec4ad7f197cf6c74b89918b35ea712b4e41435593ccb152d22b7f5`。

iPhone 17 Pro / iOS 26 Simulator 使用完整资产的一次结构性运行结果为：3,177,554 splats、SH3、49 chunks、属性 369.7 MiB，加载 36.52 秒，首次 100 万候选排序 1,584.25 ms。控制器在 80 万～125 万候选间调整；稳定窗口多数为 59～60 completed FPS，但在重排或宿主机抖动窗口也观察到 51～54 FPS。截图时为 125 万候选、59 FPS。Simulator 报告的 GPU 时间和 Metal working-set 都不具备真机代表性，这个结果证明的是完整文件未裁剪的读取、编码、排序和绘制链路已经跑通，不是 iPhone 15 Pro 的持续 60 FPS 结论。

### 仍需 iPhone 15 Pro 真机验证

1. Release 构建，关闭 debugger 的额外开销；
2. 冷启动加载 300 万点，记录峰值 resident memory 与 `currentAllocatedSize`；
3. 固定分辨率、固定相机轨迹运行至少 10 分钟；
4. 记录 completed FPS 的平均、p95 frame time、GPU ms、sort ms、候选变化和 thermal state；
5. 对比 25/50/75/100/125 万候选的图像误差与 FPS；
6. 触发 background/foreground 和 memory warning，确认不会出现无恢复黑屏；
7. 若 25 万候选仍低于目标，降低渲染分辨率或进入 30 FPS 档，不能继续假称 60 FPS 已保证。

## 11. 下一阶段

这次改造解决的是“300 万属性如何加载和把每帧工作限制住”，不是最终超大场景架构。下一阶段优先级：

1. 离线空间 chunk + bounds + 多级 LOD，让 $N_{resident}<N_{asset}$；
2. chunk 级视锥/投影尺寸选择，让候选与当前视图相关；
3. GPU project/cull + compact，避免候选都进入 quad vertex 路径；
4. 逐 tile bin/sort 与 pair capacity guard；
5. conservative opacity/coverage pruning；
6. 按 p95/p99、热稳定性和图像误差决定设备档位。

详细目标架构见 [LARGE-SCENE-RENDERING.md](LARGE-SCENE-RENDERING.md)，数据结构背景见 [DATA-STRUCTURES.md](DATA-STRUCTURES.md)，完整渲染器原理见 [SPLAT-RENDERER.md](SPLAT-RENDERER.md)。
