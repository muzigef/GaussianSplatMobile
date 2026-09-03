<!-- generated-by: gsd-doc-writer -->
# `SplatRenderer.swift` 深入导读

本文面向不熟悉 Swift、Metal 和 3D Gaussian Splatting（3DGS）实时渲染的读者，沿当前源码解释 `SplatRenderer` 为什么这样设计、数据如何流动，以及每项设计的收益与代价。入口文件是 [`SplatRenderer.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatRenderer.swift)，但真正的实现横跨 CPU 排序器、chunk 数据结构和 Metal shader，不能只读一个 Swift 文件。

建议把本文与以下文档配合阅读：

- 系统边界和 App 调用链：[ARCHITECTURE.md](ARCHITECTURE.md)；
- 文件、CPU 对象和 Metal buffer 的内存关系：[DATA-STRUCTURES.md](DATA-STRUCTURES.md)；
- 与 `diff-gaussian-rasterization` 前向渲染的逐阶段区别：[FORWARD-RENDERING-COMPARISON.md](FORWARD-RENDERING-COMPARISON.md)；
- 双眼和 vertex amplification：[STEREO-RENDERING.md](STEREO-RENDERING.md)；
- 超大场景、tile、LOD 和剔除的演进方向：[LARGE-SCENE-RENDERING.md](LARGE-SCENE-RENDERING.md)；
- PLY、`.splat`、SPZ 和存储顺序：[3DGS-FORMATS.md](3DGS-FORMATS.md)。

## 1. 一句话建立心智模型

`SplatRenderer` 是一个 **CPU 命令编排器**：它不读取 PLY，也不训练高斯；它持有已经编码好的 `SplatChunk`，每帧取得 sorter 最近发布的、跨 chunk 混排的候选索引，准备本帧 uniforms 和 chunk 地址表，然后用一次 indexed-instanced draw 把候选高斯扩展成屏幕空间 quad。真正的三维协方差投影、SH 求色和高斯 Alpha 计算在 Metal shader 中执行。

所有权关系上，`SplatRenderer` 强持有 chunk，`SplatSorter` 只持有各 chunk 基础 splat buffer 的引用；排序结果保存 `(chunkIndex, splatIndex)`，不复制位置、颜色、协方差或 SH 数据。

## 2. 职责边界与关键抽象

| 抽象 | 当前职责 | 不负责什么 |
| --- | --- | --- |
| `SplatRenderer.ViewportDescriptor` | 描述一个 view 的 viewport、投影矩阵、view matrix 和屏幕像素尺寸 | 不拥有相机，不计算手势 |
| `SplatRenderer.Uniforms` | 保存 shader 每个 view 所需的矩阵、相机和投影派生量 | 不保存每个高斯的数据 |
| `SplatRenderer.UniformsArray` | 固定容纳最多两个 view 的 uniforms，并定义 256-byte ring slot 对齐 | 不是三帧 uniform ring 本身；它只是 ring 中一个 slot 的内容 |
| `SplatRenderer.GPUChunkInfo` | 每帧把 chunk 的 GPU 地址、点数、SH degree 和 enabled 位交给 shader | 不复制 chunk 内的点属性 |
| `SplatRenderer.RenderState` | 保存 pipeline cache、当前 uniform slot 指针和 quad index template | 不是每帧各一份，也不是 render pipeline 的同义词 |
| `SplatRenderer.AccessState` | 协调串行 CPU 编码、GPU in-flight 数和 chunk 独占访问 | 不承担相机排序算法 |
| `SplatChunk` | 持有一份基础 `EncodedSplatPoint` buffer、可选 SH buffer 和统一 degree | 不保存 `[SplatPoint]` 原数组 |
| `SplatSorter` | 从已注册 chunk 的完整展平序列均匀取至多 `maximumSplatCount` 个候选，再生成一条跨 chunk、相机相关的索引顺序 | 不重新排列 chunk 的实际点属性，也不做可见性、LOD 或重要性选择 |
| `ChunkID` | 对外稳定且不复用的 chunk 句柄 | 不等于 shader 使用的连续 `UInt16 chunkIndex` |
| `ChunkedSplatIndex` | 用 8 字节记录连续 chunk index 和 chunk 内局部点 index | 不记录顶点索引，也不记录深度 |

这些类型分别定义在 [`SplatRenderer.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatRenderer.swift)、[`SplatChunk.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatChunk.swift)、[`SplatSorter.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatSorter.swift) 和 [`ShaderCommon.h`](../Vendor/MetalSplatter/MetalSplatter/Resources/ShaderCommon.h)。Swift 与 Metal 两侧的 `BufferIndex`、`Uniforms`、`UniformsArray`、`GPUChunkInfo/ChunkInfo` 和 `ChunkedSplatIndex` 必须同步。

## 3. 先补足这些 Swift 阅读规则

| 写法 | 阅读方式 | 本文件中的意义 |
| --- | --- | --- |
| `public final class` | package 外可用的引用类型，且不能被继承 | 多个变量可以指向同一个 renderer |
| `@unchecked Sendable` | 作者接管跨并发域安全证明 | 不代表自动线程安全；仍依赖 mutex、串行编码和 completion |
| `private struct AccessState: ~Copyable` | 私有、不可普通复制的值类型 | 由 `Mutex` 独占管理一份协调状态 |
| `guard let x else { return }` | optional 不存在就提前返回，通过后 `x` 已解包 | 没有有效排序 buffer 时丢帧 |
| `value?.member` / `if let` | optional chaining 与条件解包 | SH buffer 只在高阶 SH chunk 中存在 |
| `defer { ... }` | 当前作用域退出时必定执行 | 早退或抛错也会清除 `isRendering` |
| `async` / `await` | task 可以挂起并在条件满足后恢复 | chunk 独占等待不必占住线程 |
| `withCheckedContinuation` | 把回调式唤醒桥接为异步等待 | 独占等待者进入 FIFO 队列 |
| `@TaskLocal` | 随当前异步 task 传播的局部值 | 让同一 task 内嵌套 chunk 操作可重入 |
| `[sorter, weak self]` | 闭包强捕获 sorter、弱捕获 renderer | GPU 完成前保留 sorter，又避免 renderer 引用环 |
| `try?` | 错误转成 `nil` 并被忽略 | chunk index patch 分配失败不会上抛给调用者 |

裸指针也值得单独认识：`dynamicUniformBuffers.contents().bindMemory(to: UniformsArray.self, capacity: 1)` 取得 shared Metal buffer 的 CPU 地址，并告诉 Swift 按 `UniformsArray` 解释字节；`pointee` 表示指针指向的结构。shader 读取同一 buffer，所以 Swift/Metal 字段顺序或对齐不一致会直接产生错误数据。

## 4. 一帧从 App 到 GPU 的完整流程

当前 App 在 [`GaussianSplatRenderer.draw(in:)`](../GaussianSplatMobile/Renderer/GaussianSplatRenderer.swift) 中创建一个 `ViewportDescriptor`，调用 `SplatRenderer.render(...)`。后者依次完成：

1. 在 `AccessState` 下尝试取得 render 权限：不能处于 chunk 独占期、不能有独占等待者、不能有另一个 `render()` 正在编码，且 GPU in-flight 数必须小于上限。
2. 将 `isRendering` 设为 `true`，并把 `inFlightRenderCount` 加一；这一步发生在真正编码之前，以覆盖所有后续早退路径。
3. 按 `orderedChunkIDs` 建立包括 enabled 和 disabled chunk 的连续数组。
4. 从所有 view matrix 的逆矩阵计算平均相机位置和平均 forward，把 pose 交给 sorter。`sortByDistance = true` 时，只有世界位置变化平方大于 `1e-6` 才因 pose 请求新排序；纯旋转本身不会。chunk generation 或候选上限改变也会请求排序。
5. 尝试引用最近有效的排序索引；如果从上次 chunk 变更后还没有任何有效结果，默认最多等待 `sortTimeout = 0.1` 秒。它不会等待“最新 pose 对应的排序”。
6. 计算 `indexedSplatCount` 和 `instanceCount`，切换 uniform ring slot，写入每个 view 的 uniforms。
7. 从 pool 取得或创建本帧 `GPUChunkInfo` buffer，写入所有 chunk 的 GPU 地址、点数、degree 和 enabled 位。
8. 根据配置懒创建 single-stage 或 multi-stage pipeline state，建立 render encoder。
9. 必要时扩展 quad index template；绑定 uniform、chunk table、排序索引，并声明所有间接寻址的 splat/SH buffer 为本次 vertex 阶段资源。
10. 编码一次 `drawIndexedPrimitives(..., instanceCount:)`；multi-stage 路径还会编码 tile 初始化和全屏 postprocess。
11. 结束 encoder 并返回 `true`。调用方负责 present 和 commit；GPU completion handler 归还 chunk table buffer、释放排序索引引用并递减 in-flight 数。

一个重要调用约束是：`render()` 一旦安装 completion handler，调用方必须提交该 command buffer。否则 completion 永远不发生，排序 buffer 引用和 `inFlightRenderCount` 都不会释放。当前 App 在 `didRender == false` 时也会 `commit()`，满足这一约束。

## 5. `RenderState` 只有一份，但 GPU frame 可以有三份在途

当前 `SplatRenderer` 只有一个：

```swift
private var renderState: RenderState
```

这个 `RenderState` 保存：

- single-stage 和 multi-stage 的 pipeline cache；
- 当前 uniform ring 的 slot index、byte offset 和 CPU 指针；
- 一份可增长、反复复用的 quad index template。

`AccessState.isRendering` 保证同一时刻只有一个线程修改这些字段，所以无需为每个 CPU 调用创建一份 `RenderState`。但这不等于只能有一帧在 GPU 执行：编码完成后 `isRendering` 被清零，而 `inFlightRenderCount` 要到 GPU completion 才减少。

当前 App 初始化参数为：

```swift
maxViewCount: 1,
maxSimultaneousRenders: 3
```

因此最多允许三个 command buffer 已编码但尚未完成。每帧易变资源的隔离方式不同：

| 资源 | in-flight 隔离方式 |
| --- | --- |
| uniforms | 三个固定 ring slots |
| chunk table | 每帧从 pool 取得一个 buffer，GPU 完成后归还 |
| 排序索引 | sorter 三 buffer 的引用计数；多帧也可以共享同一份有效结果 |
| splat/SH buffer | chunk 生命周期内持久存在，command encoder 用 `useResource` 声明间接读取 |
| quad index template | 所有帧共享；只有在串行编码时按需增长，稳定后只读 |

所以“一个 `RenderState`”“三份 uniform slot”“sorter 三份 index buffer”和“single-stage pipeline”是四个不同概念。

## 6. Uniform ring：三槽如何切换，以及每个字段是什么

### 6.1 slot 数量由 `maxSimultaneousRenders` 决定

库本身不是永远三槽，而是构造时分配 `maxSimultaneousRenders` 个 slot。当前 App 传入 3，所以本文简称“三槽 ring”。总分配大小为：

$$
B_{uniform}=R\,A
$$

读作“uniform buffer 总字节数等于 slot 数 $R$ 乘每个对齐后 slot 大小 $A$”。当前 $R=3$。这里没有分子或分母；乘法表示每个在途 frame 预留互不重叠的区域。代码对应 `dynamicUniformBuffersSize`。

一个 `UniformsArray` slot 会向上对齐到 256 字节：

$$
A=256\left\lceil\frac{S}{256}\right\rceil
$$

读作“用结构实际大小 $S$ 除以 256，向上取整后再乘 256”。分子是结构字节数 $S$，分母是 256-byte 对齐粒度；结果 $A$ 是相邻 slot 的 byte stride。源码用等价的位运算 `(S + 0xFF) & -0x100`。不要手工假定 `S`，应让目标架构的 `MemoryLayout<UniformsArray>.size` 决定。

第 $f$ 次切换选择：

$$
j_f=(j_{f-1}+1)\bmod R,
\qquad
o_f=A\,j_f
$$

读作“当前 slot index 加一后对 slot 数 $R$ 取模，再用 slot 大小 $A$ 乘 index 得到 byte offset $o_f$”。`mod` 表示循环回到开头。初值是 0，而 `render()` 写入前先切换，因此三槽第一次到第四次依次使用 `1 → 2 → 0 → 1`；slot 0 并未丢失，只是第一次不使用。

### 6.2 为什么 ring 不直接覆盖同一个 uniform

CPU 提交 command buffer 后会很快开始编码下一帧，但 GPU 可能仍在读取上一帧的 view/projection matrix。如果所有帧写同一地址，CPU 会把 GPU 尚未消费的数据覆盖。ring 用不同 byte offset 隔离最多 $R$ 个在途 frame；`inFlightRenderCount < R` 限制 CPU 不会无限追赶 GPU。

当前 App 只有一条 `MTLCommandQueue`，其帧按提交顺序完成，因此循环复用与 in-flight 上限相匹配。若以后让同一个 renderer 接收来自多条可能乱序完成的 command queue，当前代码没有记录“具体哪个 slot 已完成”，只记录总 in-flight 数；这种扩展需要给 slot 增加独立占用状态或 fence，不能直接假定安全。

### 6.3 `UniformsArray` 与 view 数量

一个 ring slot 不是一份 `Uniforms`，而是固定的：

```swift
struct UniformsArray {
    var uniforms0: Uniforms
    var uniforms1: Uniforms
}
```

这是为了支持最多两个 view。单眼时只写 `uniforms0`；双眼时分别写 0、1，vertex amplification 的 `amplificationID` 选择对应项。没有使用的第二项不会被当前单眼 shader 访问。

### 6.4 每个 `Uniforms` 字段

| 字段 | 来源 | shader 用途 |
| --- | --- | --- |
| `projectionMatrix` | 当前 `ViewportDescriptor` | 把 view-space 中心变为 clip-space 中心 |
| `viewMatrix` | 当前 `ViewportDescriptor` | 把世界位置和三维协方差转到 view space |
| `cameraPosition` | 所有 view 世界位置的平均值 | 高阶 SH 的共享视线方向；双眼不是各自眼位 |
| `_padding0` | 固定 0 | 保持 Swift/Metal ABI 对齐 |
| `screenSize` | viewport 对应纹理像素宽高 | 像素轴向量转换成 NDC/clip delta |
| `focalX` | `screenWidth × projection[0][0] / 2` | 三维协方差投影的像素焦距 |
| `focalY` | `screenHeight × projection[1][1] / 2` | 同上，垂直方向 |
| `tanHalfFovX` | `1 / projection[0][0]` | 限制 covariance 投影时的屏幕外位置 |
| `tanHalfFovY` | `1 / projection[1][1]` | 同上，垂直方向 |
| `chunkCount` | 本帧全部 chunk 数 | shader 校验 `chunkIndex` 边界 |
| `splatCount` | 当前排序 index buffer 项数 | 丢弃最后一个不足整组 instance 的多余调用 |
| `indexedSplatCount` | `min(splatCount, 1024)` | 把 `instanceID` 和 `vertexID` 映射为候选排序位置 |

像素焦距的预计算为：

$$
f_x=\frac{W\,P_{00}}{2},
\qquad
f_y=\frac{H\,P_{11}}{2}
$$

读作“屏幕宽 $W$ 乘投影矩阵横向缩放 $P_{00}$，再除以 2，得到横向像素焦距 $f_x$；纵向同理”。两个分式的分子分别是像素尺寸与投影缩放的乘积，分母 2 把完整屏幕跨度转换为半屏尺度。代码在 `updateUniforms` 中计算，shader 的 `calcCovariance2D` 消费。

## 7. Quad index template、1024 与 instance 的真实关系

### 7.1 先用常规 mesh instancing 建立心智模型

常规 mesh instancing 通常采用“一 instance 一物体”的业务约定。例如绘制 1000 棵树时，GPU 反复使用同一份树 mesh 和 index buffer，`vertexID` 选择树的局部顶点，`instanceID` 选择第几棵树的模型矩阵、颜色或材质参数：

$$
\mathbf p_{world}=M_{\mathrm{instanceID}}\mathbf p_{local}
$$

读作“用编号为 `instanceID` 的模型矩阵 $M$ 变换固定 mesh 的局部位置向量 $\mathbf p_{local}$，得到世界位置向量 $\mathbf p_{world}$”。向量是一组带方向的坐标，矩阵表示旋转、缩放和平移等线性或仿射变换；这个公式没有分子或分母。这里一个 instance 的所有 mesh 顶点通常共享同一个 $M_{\mathrm{instanceID}}$，但这只是常见的数据组织方式，不是 Metal 对 instancing 的强制语义。

对 `drawIndexedPrimitives(..., instanceCount:)`，硬件真正保证的是：把同一条 index stream 重放 `instanceCount` 次，并在每次重放时向 shader 提供不同的 `instanceID`。它**不要求**同一个 instance 内的所有顶点共享一份业务数据，也不规定一个 instance 必须等于一个可见物体。当前 renderer 正是利用了这点，让一个硬件 instance 覆盖一组不同高斯。

### 7.2 最直观但未被当前代码采用的“一高斯一 instance”

一种完全合理的 3DGS 实现是只建立一个 quad 模板：4 个逻辑顶点、6 个 index，然后令：

$$
\mathrm{indexCount}=6,
\qquad
\mathrm{instanceCount}=N,
\qquad
\mathrm{splatID}=\mathrm{instanceID}
$$

读作“index stream 只描述一个 quad，却被重复 $N$ 次；每次的 `instanceID` 直接就是高斯编号”。$N$ 是本帧提交的高斯总数；这里没有分式。`vertexID` 仍从 0 到 3 选择同一高斯的四个角。这与常规“一 instance 一物体”最接近，只是每个物体从树 mesh 换成一个高斯 quad。

当前实现没有采用该方案。源码注释把 `maxIndexedSplatCount = 1` 称为只使用 instancing，并记录它有明显性能损失。这个描述是当前作者对该实现的经验结论，不应推广成“所有 Apple GPU 或所有 3DGS renderer 中，一高斯一 instance 都一定慢”。

### 7.3 当前方案是 indexed + grouped instancing

当前 index stream 一次描述的不是一个 quad，而是 $K$ 个 quad；随后硬件把这一整条 stream 重放 $I$ 次。令本帧候选排序索引数为 $N$；它可能小于场景常驻高斯总数：

$$
K=\min(N,1024),
\qquad
I=\left\lceil\frac{N}{K}\right\rceil
$$

读作“`indexedSplatCount` $K$ 取高斯总数 $N$ 与上限 1024 的较小值；`instanceCount` $I$ 是 $N/K$ 向上取整”。第二个式子的分子 $N$ 是全部排序位置数，分母 $K$ 是一条 index stream 覆盖的高斯数；向上取整保证最后不足一组的数据也会被提交。Swift 用整数等价式 `(N + K - 1) / K` 计算。

一个 quad 有四个逻辑顶点、两个三角形和六个 index。模板内第 $i$ 个高斯写入：

$$
Q_i=(4i,\;4i+1,\;4i+2,\;4i+1,\;4i+2,\;4i+3)
$$

读作“前三个 index 组成第一个三角形，后三个组成第二个三角形；$4i$ 到 $4i+3$ 是模板内第 $i$ 个高斯的四个角”。$i$ 是 $0\ldots K-1$ 的局部高斯编号。代码把这些 `UInt32` 写入 `triangleVertexIndexBuffer`；`triangleVertexCount` 这个变量名容易误导，它实际保存 draw 的 index 数 $6K$，不是不同顶点数。

因此当前 draw 的形状是：

```text
一条 index stream：K 个 quad，共 6K 个 index
        ×
I 个硬件 instance：每次重放映射到另一组高斯
        =
一次 draw 覆盖最多 I × K 个排序位置
```

更准确的名称是“共享 quad index template 的分组实例化”，而不是“一高斯一 instance”。这是当前 `SplatRenderer` 的工程选择，并不是 3DGS 唯一或规范规定的实例化方式。

### 7.4 三层索引：组、组内高斯和 quad 角

在 indexed draw 中，shader 收到的 `vertexID` 是 index buffer 取出的值。当前 shader 把寻址拆成三层：

```text
instanceID   → 第几组高斯
vertexID / 4 → 组内第几个高斯
vertexID % 4 → 该高斯 quad 的第几个角
```

候选排序位置 $g$ 为：

$$
g=\mathrm{instanceID}\times K+\left\lfloor\frac{\mathrm{vertexID}}{4}\right\rfloor
$$

读作“先用 `instanceID × K` 跳到当前组的起点，再加 `vertexID / 4` 得到组内高斯编号”。分式的分子是 index stream 给出的逻辑 `vertexID`，分母 4 来自每个高斯的四个顶点；向下取整使同一 quad 的四个角映射到同一个 $g$。代码对应 `singleStageSplatVertexShader` 的 `splatID`。

quad 角编号 $c$ 为：

$$
c=\mathrm{vertexID}\bmod 4
$$

读作“`vertexID` 除以 4 的余数选择角 0、1、2、3”。这里 `mod` 是取余，不是分数；代码把它作为 `splatVertex(..., vertexID % 4, ...)` 的第三个参数。这样同一高斯的四次 vertex invocation 读取同一份高斯属性，但生成不同角点。

### 7.5 $N=2500$ 的完整例子

若 $N=2500$，当前上限使 $K=1024$，则：

$$
I=\left\lceil\frac{2500}{1024}\right\rceil=3
$$

读作“2500 除以每组 1024 后向上取整，得到 3 个 instance”。分子 2500 是有效排序位置，分母 1024 是每组容量。三次重放分别映射为：

| `instanceID` | 由公式产生的 $g$ | 有效范围 |
| ---: | --- | --- |
| 0 | `0...1023` | 全部有效 |
| 1 | `1024...2047` | 全部有效 |
| 2 | `2048...3071` | 仅 `2048...2499` 有效 |

最后一组多提交 572 个逻辑高斯位置。shader 在访问排序 buffer 前执行 `g >= uniforms.splatCount` 检查，把 `2500...3071` 的顶点退化到固定位置，因此不会继续读取这些不存在的排序项。这个尾组浪费最多小于 $K$ 个高斯的 vertex 工作，是固定模板和简单单 draw 换来的代价。

### 7.6 拓扑被复用，高斯属性没有被复用

必须严格区分以下数据：

| 名称 | 保存什么 | 是否被各 instance 复用 |
| --- | --- | --- |
| `indexedSplatCount` | 一个整数 $K$ | 所有 instance 使用相同值 |
| `triangleVertexIndexBuffer` | $6K$ 个 quad 拓扑 index | 是；每次重放相同 index stream |
| `splatIndexBuffer` | $N$ 个跨 chunk 排序后的候选 `(chunkIndex, splatIndex)` | 不是重复模板；每个 $g$ 取不同项 |
| `SplatChunk.splats` | 位置、SH0/Alpha、三维协方差 | 否；每个排序项间接找到自己的高斯 |
| `SplatChunk.shCoefficients` | 可选高阶 SH 数据 | 否；按真实 chunk 内索引读取 |

所以当前方案复用的是 **quad topology、shader 和 pipeline**，并不会把每个高斯的位置、协方差、Alpha 或 SH 变成一份共享数据，也不会像常规 mesh instancing 那样主要依靠“固定 mesh + 每物体 transform”压缩几何内存。

### 7.7 固定 mesh 变换与程序化屏幕 quad 的区别

常规实例化读取已经存在的局部 mesh 顶点，再用每 instance 的模型矩阵变换。当前 3DGS index buffer 只提供四个角的拓扑编号，并不保存高斯 quad 的世界空间顶点。`splatVertex` 每帧根据高斯中心、三维 covariance、view/projection matrix 和屏幕尺寸，求投影椭圆的两个二维主轴 $\mathbf a_1,\mathbf a_2$，再程序化生成角点：

$$
\mathbf p_{s,t}=\mathbf p_c+3\left(s\mathbf a_1+t\mathbf a_2\right),
\qquad
s,t\in\{-1,+1\}
$$

读作“从投影中心向量 $\mathbf p_c$ 出发，沿两个屏幕主轴向量 $\mathbf a_1,\mathbf a_2$ 分别选择正负方向，并扩展到三倍标准差”。$s,t$ 只是正负符号；公式没有分子或分母。由于主轴由 covariance 和相机共同决定，同一高斯的 quad 会随相机改变大小、方向和形状。第 8 章继续推导三维 covariance 如何得到这两个二维主轴。

### 7.8 透明排序引入了额外间接寻址

常规不透明 mesh instancing 常见的数据路径是 `instanceID → transform → 固定 mesh`。当前候选高斯必须先遵守 `SplatSorter` 产生的远到近顺序，所以 $g$ 不是原始高斯编号，而是**跨 chunk 候选排序数组中的位置**。shader 的实际读取链为：

```text
instanceID + vertexID
    → 候选排序位置 g
    → splatIndexArray[g]
    → (chunkIndex, splatIndex)
    → chunks[chunkIndex]
    → chunk.splats[splatIndex]
    → 可选 chunk.shCoefficients
```

这层 indirection 让 sorter 只重排轻量候选索引而不搬动全部高斯属性，也允许候选跨多个 chunk 混排；代价是 vertex shader 多做若干次非连续 buffer 读取，排序后的访问顺序也可能削弱 `SplatChunk.sortByLocality` 建立的内存局部性。

### 7.9 $K=1$、$K=1024$ 与 $K=N$ 的 trade-off

把模板覆盖数 $K$ 视为可调参数，可以看到当前 1024 位于两个极端之间。活跃 index 数和索引字节数为：

$$
\mathrm{indexCount}=6K,
\qquad
B_{index}=6K\times4=24K\ \mathrm{bytes}
$$

读作“每个 quad 有 6 个 `UInt32` index，所以 $K$ 个 quad 需要 $6K$ 项；每项 4 字节，因此需要 $24K$ 字节”。$B_{index}$ 是当前 draw 所需模板字节数；这里的乘法没有分子或分母。实际 `MetalBuffer` 的已分配 capacity 还可能保留历史高水位，不一定随较小场景立即缩小。

| 方案 | `indexCount` | `instanceCount` | 模板索引内存 | 主要收益 | 主要代价 |
| --- | ---: | ---: | ---: | --- | --- |
| $K=1$：一高斯一 instance | $6$ | $N$ | 24 B | 模板最小，业务映射最直观 | instance 数最大；源码注释记录当前实现性能明显下降 |
| $K=1024$：当前分组方案 | 最大 6144 | $\lceil N/1024\rceil$ | 最大 24 KiB | 小而易复用的模板、较少 instance、仍是一次 draw | 尾组有最多 1023 个无效高斯位置；多一级组内寻址 |
| $K=N$：全部 indexing | $6N$ | $1$ | $24N$ B | 没有分组和尾组浪费，只需一个 instance | index buffer 随 $N$ 线性增长，内存和 cache 压力更高 |

例如本帧 $N=1{,}000{,}000$ 个候选时，$K=N$ 的 index template 约为 24 MB，而当前 $K=1024$ 的活跃模板约为 24 KiB，相差约 1000 倍；常驻高斯属性和另行保存的候选排序索引内存并没有因此减少。源码注释称约 1k 是经验上的 sweet spot，并认为它比两个极端略好，但仓库没有按设备、模型规模和 GPU counter 给出的 benchmark。因此 1024 应理解为当前实现的经验参数，而不是 3DGS 算法常数；改变 GPU、索引生成方式或渲染架构后，应重新测量。

## 8. 高斯 quad 的四个顶点如何计算

实现位于 [`SplatProcessing.metal`](../Vendor/MetalSplatter/MetalSplatter/Resources/SplatProcessing.metal)。结论是：**四个顶点包围三维高斯投影到屏幕后的二维椭圆，覆盖两个主轴方向上的 $\pm3\sigma$；它不是世界空间中真实存在的四边形，也不是椭圆边界本身。**

### 8.1 从三维协方差到二维协方差

`EncodedSplatPoint` 已经保存对称三维协方差 $\Sigma_{3D}$ 的六个独立分量。shader 先把高斯中心变到 view space，再建立透视投影的局部 Jacobian $J$。按数学行列写法，它对应：

$$
J=
\begin{bmatrix}
f_x/z & 0 & -f_xx/z^2 \\
0 & f_y/z & -f_yy/z^2 \\
0 & 0 & 0
\end{bmatrix}
$$

读作“中心在 view space 的位置为向量 $(x,y,z)$；$f_x,f_y$ 是像素焦距。矩阵 $J$ 描述中心附近很小的三维位移怎样改变二维像素坐标”。例如第一行的分式 $f_x/z$ 中，分子是横向焦距，分母是深度；深度绝对值越大，同样的世界位移投影得越小。$-f_xx/z^2$ 的分子是焦距和横向位置，分母是深度平方，描述改变深度对屏幕横坐标的影响。Metal 矩阵构造按列给值，但表达的是同一线性变换。

令 $W$ 为 view matrix 左上 $3\times3$ 的旋转部分，代码计算：

$$
T=JW,
\qquad
\Sigma_{2D}=\left(T\Sigma_{3D}T^{\mathsf T}\right)_{xy}+0.3I
$$

读作“先用矩阵 $W$ 把世界方向转到 view 方向，再用 Jacobian $J$ 投影到像素方向；矩阵 $T$ 是两步的组合。$T^{\mathsf T}$ 是 $T$ 的转置，即交换行列。乘积得到投影协方差，再取左上二维部分”。$0.3I$ 给两个对角分量各加 0.3，作为低通下限，降低亚像素高斯造成的不稳定。这里的向量表示带方向的有序数，矩阵表示线性变换；没有求梯度或反向传播。

投影前，代码还把 $x/z$、$y/z$ 限制到约 $1.3\tan(\mathrm{FOV}/2)$，避免屏幕外很远的中心产生极端 Jacobian。之后又用中心 clip 坐标和 `1.2 × w` 做一次较宽松的早期剔除。

### 8.2 特征分解得到椭圆主轴

二维对称协方差以三个数保存：

$$
\Sigma_{2D}=
\begin{bmatrix}
a & b\\
b & d
\end{bmatrix}
$$

读作“对角元素 $a,d$ 是两个屏幕轴方向的方差，非对角元素 $b$ 表示二者相关造成的旋转”。由于矩阵对称，左下和右上都是 $b$，所以只需三个标量。

源码用闭式解计算：

$$
m=\frac{a+d}{2},
\qquad
\Delta=ad-b^2,
\qquad
q=\max\left(0.1,\sqrt{m^2-\Delta}\right)
$$

读作“$m$ 是对角线和的一半；分式分子 $a+d$ 是矩阵迹，分母 2 取平均；$\Delta$ 是行列式；$q$ 是两个特征值相对平均值的距离，并至少为 0.1”。代码的下限作用在开方结果上，公式按源码书写。

$$
\lambda_1=m+q,
\qquad
\lambda_2=m-q
$$

读作“$\lambda_1,\lambda_2$ 是二维协方差的两个特征值，也就是两个主轴方向的方差”。它们不是顶点坐标。

若对应的单位特征向量为 $\mathbf e_1,\mathbf e_2$，shader 形成：

$$
\mathbf a_1=\sqrt{\lambda_1}\,\mathbf e_1,
\qquad
\mathbf a_2=\sqrt{\lambda_2}\,\mathbf e_2
$$

读作“方差开平方得到标准差，所以向量 $\mathbf a_1,\mathbf a_2$ 同时包含椭圆主轴方向和一倍标准差长度”。向量有两个分量，对应屏幕像素的横、纵方向；源码变量就是 `axis1`、`axis2`。

### 8.3 四个角是 $\pm3\sigma$ 的组合

相对符号 $(s,t)$ 取 `(-1,-1)`、`(-1,1)`、`(1,-1)`、`(1,1)`。像素空间角点偏移为：

$$
\Delta\mathbf p_{s,t}=3\left(s\mathbf a_1+t\mathbf a_2\right),
\qquad s,t\in\{-1,+1\}
$$

读作“沿第一主轴选正或负方向，再沿第二主轴选正或负方向，两者相加并乘三倍标准差”。$s,t$ 只是符号，不是新的坐标轴；常数 3 对应 shader 的 `kBoundsRadius`。

像素偏移再变成 NDC 偏移：

$$
\Delta\mathbf p_{ndc}
=
\left(
\frac{2\Delta p_x}{W},
\frac{2\Delta p_y}{H}
\right)
$$

读作“横向像素偏移 $\Delta p_x$ 除以屏幕宽 $W$，纵向像素偏移 $\Delta p_y$ 除以屏幕高 $H$，再乘 2，因为 NDC 从 -1 到 1 共跨 2”。两个分式的分子是带符号像素位移，分母分别是屏幕像素宽、高。shader 再乘 clip-space 的 $w$ 加到中心的 clip $x/y$，保持齐次坐标下的正确位置。

### 8.4 真正的椭圆在 fragment shader 中形成

quad 内插值得到局部坐标 $(u,v)$，范围在每个轴的 `-3...3`。Alpha 为：

$$
\alpha(u,v)=
\begin{cases}
\alpha_0\exp\!\left(-\dfrac{u^2+v^2}{2}\right), & u^2+v^2\le 9\\
0, & u^2+v^2>9
\end{cases}
$$

读作“局部半径平方不超过 9 时，用二维标准高斯衰减乘原始透明度 $\alpha_0$；超过三倍标准差圆形边界时直接返回 0”。指数中分式的分子 $u^2+v^2$ 是局部距离平方，分母 2 是标准高斯的固定尺度；负号让离中心越远 Alpha 越小。四边形的角落超出圆形/椭圆有效域，因此会得到 0。

与 CUDA `diff-gaussian-rasterization` 的核心差别不是高斯数学变了，而是调度方式：当前 Metal 路径借助硬件 triangle rasterizer 产生 fragment，再解析计算 Alpha；参考 CUDA 路径先做 tile binning/range，再在 tile kernel 中逐像素累积。完整比较见 [FORWARD-RENDERING-COMPARISON.md](FORWARD-RENDERING-COMPARISON.md)。

## 9. `SplatSorter`：跨多个 chunk 的有界候选排序

### 9.1 候选覆盖完整展平序列，但只为候选建临时项

`SplatSorter.performSort` 先按注册顺序把所有 chunk **概念上**展平成一条序列，再从整条序列中确定性均匀采样至 `maximumSplatCount`。它不建立第二份完整展平数组，只为被选中的候选生成临时项：

```text
(UInt16 chunkIndex, UInt32 splatIndex, Float depth)
```

随后对整个 `sortTempStorage` 调用 Swift `sort`，再只把 `(chunkIndex, splatIndex)` 写进目标 Metal buffer。disabled chunk 没有从 sorter 移除，所以也参加这一过程。

设有 $C$ 个 chunk，第 $c$ 个有 $N_c$ 个常驻高斯，总数为：

$$
N_{all}=\sum_{c=1}^{C}N_c
$$

读作“所有 chunk 的高斯总数 $N_{all}$ 等于每个 chunk 数量 $N_c$ 的求和”。求和符号表示从第 1 个 chunk 累加到第 $C$ 个；这里没有分子或分母。所有 $N_{all}$ 个高斯的位置、协方差、颜色和 SH 属性仍保留在各自的 Metal buffer 中。

令候选上限为 $N_{max}$，实际候选数为：

$$
K=\min(N_{all},N_{max})
$$

读作“候选数 $K$ 取常驻总数 $N_{all}$ 和配置上限 $N_{max}$ 的较小值”。这里没有分子或分母。若上限不小于总数，退化为全量候选；当前 App 则从 1,000,000 初始候选开始，并在 250,000～1,250,000 范围内按完成帧率和 GPU 时间调整。

第 $j$ 个候选对应的展平下标为：

$$
q_j=\left\lfloor\frac{jN_{all}}{K}\right\rfloor,
\qquad j=0,1,\ldots,K-1
$$

读作“用候选序号 $j$ 乘完整场景点数 $N_{all}$，再除以候选数 $K$ 并向下取整，得到原展平序列下标 $q_j$”。分子 $jN_{all}$ 表示按完整序列长度等比例推进，分母 $K$ 把完整序列分成 $K$ 个采样间隔。遍历时只维护当前 chunk 的全局起止位置，因此候选会落入不同 chunk，之后一起远到近混排。

这只是按文件经过各 chunk Morton 重排后的注册顺序做**确定性等距抽样**：它不看视锥、屏幕贡献、透明度、尺度或语义，不是随机采样，也不是 visibility culling、LOD 或 importance sampling。对于同一 chunk 序列和同一上限，候选集合是确定的；改变 chunk generation 或上限会重建候选。

一次 CPU 排序的主要量级为：

$$
T(N_{all},K,C)=O(C+K)+O(K\log K)+O(K)=O(C+K\log K)
$$

读作“先用 $O(C)$ 统计各 chunk 点数，再以单向 chunk 游标访问 $K$ 个候选并计算键，中间比较排序，最后线性写索引；通常由 $K\log K$ 主导”。$C$ 是 chunk 数，$K$ 是候选数，不再对未入选的 $N_{all}-K$ 个点建立深度临时项。`sortTempStorage` 是 $O(K)$，三份发布 index buffer 的逻辑项数各至多为 $K$；buffer 扩容后可能保留历史 capacity，不会因预算下降立即缩小。

### 9.2 当前排序键

当前 `sortByDistance = true`，第 $i$ 个**候选高斯**使用：

$$
d_i=\left\|\mathbf p_i-\mathbf c\right\|^2
$$

读作“世界位置向量 $\mathbf p_i$ 减相机位置向量 $\mathbf c$，再把三个分量分别平方并求和”。向量是 $(x,y,z)$；平方距离不求平方根，因为平方根不会改变非负距离的大小关系。数组按 $d_i$ 从大到小排，即大致由远到近。

源码保留另一条沿 forward 的键：

$$
z_i=\mathbf p_i\cdot\mathbf f
$$

读作“位置向量 $\mathbf p_i$ 与相机 forward 单位向量 $\mathbf f$ 做点积，即对应分量相乘后求和”。相机位置项对所有点是同一个常数，所以省略它不改变相对顺序。当前常量没有启用这条分支。

欧氏距离不是严格的 view-depth：屏幕边缘点可能因为横向距离较大而被判断更远。源码注释记录了经验取舍——距离排序靠近物体时可能不稳定，forward 排序转动时可能出现伪影——但仓库没有自动 benchmark 或画质指标证明其中一个普遍更优。

### 9.3 single-stage 的输出和固定混合方程

[`SingleStageRenderPath.metal`](../Vendor/MetalSplatter/MetalSplatter/Resources/SingleStageRenderPath.metal) 的 fragment shader 先计算高斯在当前像素的覆盖率 $\alpha$，再输出：

$$
\mathbf S=\left(\alpha\mathbf c,\alpha\right)
$$

读作“片元输出 $\mathbf S$ 的 RGB 部分是颜色向量 $\mathbf c$ 乘透明度 $\alpha$，Alpha 部分仍是 $\alpha$”。向量 $\mathbf c=(r,g,b)$ 表示红、绿、蓝三个颜色分量；这一步从左到右把未预乘颜色变成**预乘 Alpha 颜色**。公式没有分式，所以不存在分子和分母。它对应源码中的 `half4(alpha * in.color.rgb, alpha)`。

[`SplatRenderer.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatRenderer.swift) 为 single-stage pipeline 开启固定功能混合，并精确设置为：

```text
RGB operation            = add
source RGB factor        = one
destination RGB factor   = oneMinusSourceAlpha
Alpha operation          = add
source Alpha factor      = one
destination Alpha factor = oneMinusSourceAlpha
```

因此每画一个 fragment，颜色 attachment 的新值是：

$$
\mathbf C_{new}=\mathbf C_{src}+\left(1-\alpha_{src}\right)\mathbf C_{dst}
$$

读作“新颜色等于当前源片元的预乘颜色 $\mathbf C_{src}$，加上旧目标颜色 $\mathbf C_{dst}$ 乘剩余透射率 $1-\alpha_{src}$”。这里的“源”是**现在正在画的高斯**，“目标”是 attachment 中**之前已经画好的结果**；计算方向是用当前源覆盖旧目标。公式没有除法；$1-\alpha_{src}$ 越小，旧颜色留下得越少。它逐项对应 `.one` 和 `.oneMinusSourceAlpha` 两个 Metal blend factor。

Alpha attachment 同样按以下方式更新：

$$
\alpha_{new}=\alpha_{src}+\left(1-\alpha_{src}\right)\alpha_{dst}
$$

读作“新 Alpha 等于源 Alpha，加上源片元未遮住的比例乘旧 Alpha”。$\alpha_{src}$ 与 $\alpha_{dst}$ 都在 $0$ 到 $1$ 之间；计算方向同样是当前源覆盖旧目标。这里也没有分子和分母。它对应 source/destination Alpha blend factor 的相同设置。

### 9.4 为什么该方程要求从远到近

考虑同一像素上的远层 $F$、近层 $N$ 和背景 $B$。先画远层时，attachment 先得到：

$$
\mathbf C_1=\alpha_F\mathbf c_F+\left(1-\alpha_F\right)\mathbf C_B
$$

读作“远层自身颜色 $\mathbf c_F$ 先乘覆盖率 $\alpha_F$，再加上远层没有挡住的背景 $\mathbf C_B$”。$\mathbf C_1$ 是第一次绘制后的预乘颜色；计算方向是从背景向观察者前进。公式没有除法，因而没有分子、分母。它对应第一次执行 fixed-function blend。

随后画近层，近层作为新的 source 覆盖已经包含远层的 destination：

$$
\begin{aligned}
\mathbf C_{final}
&=\alpha_N\mathbf c_N+\left(1-\alpha_N\right)\mathbf C_1\\
&=\alpha_N\mathbf c_N
+\left(1-\alpha_N\right)\alpha_F\mathbf c_F
+\left(1-\alpha_N\right)\left(1-\alpha_F\right)\mathbf C_B
\end{aligned}
$$

第一行读作“近层颜色，加近层透过去的旧结果”；第二行把旧结果展开成远层和背景。$\alpha_N$、$\alpha_F$ 分别是近、远高斯在该像素的 Alpha，$\mathbf c_N$、$\mathbf c_F$ 是它们的未预乘 RGB 向量。计算方向仍是远处到近处：背景先被远层过滤，再被近层过滤。公式没有分式；每个 $1-\alpha$ 都表示光穿过一层后剩下的比例。这个结果正是观察者应该看到的“近层在远层前面”。

如果反过来先画近层、再画远层，fixed-function blend 会把后来提交的远层当成 source，得到：

$$
\mathbf C_{wrong}
=\alpha_F\mathbf c_F
+\left(1-\alpha_F\right)\alpha_N\mathbf c_N
+\left(1-\alpha_F\right)\left(1-\alpha_N\right)\mathbf C_B
$$

读作“远层被错误地放到了近层前面”：近层颜色现在被 $1-\alpha_F$ 衰减。$\mathbf C_{wrong}$ 是错误顺序的输出；乘法次序虽然可以交换，但哪一层的颜色被另一层透射率削弱不能交换。公式没有除法。除非两层颜色相同、某层完全透明等特殊情况，否则它与 $\mathbf C_{final}$ 不相等。

所以 [`SplatSorter.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatSorter.swift) 使用 `sort { $0.depth > $1.depth }`：较大的距离先提交，较小的距离后提交。**远到近不是 3DGS 的数学定律，而是当前“预乘 Alpha + source-over 固定混合”实现对提交顺序的要求。**

### 9.5 一个两层数值例子

令近层是红色、远层是蓝色，两者 Alpha 都为 $0.5$，背景为黑色：

$$
\mathbf c_N=(1,0,0),\quad
\mathbf c_F=(0,0,1),\quad
\alpha_N=\alpha_F=0.5,\quad
\mathbf C_B=(0,0,0)
$$

读作“近层是单位红，远层是单位蓝，两层各覆盖一半，背景没有颜色”。三元组是 RGB 向量，不是矩阵；$0.5$ 表示一半覆盖、一半透过。公式没有分子和分母，计算将在三个颜色分量上分别进行。

按远到近绘制时，先把蓝色写成 $(0,0,0.5)$，再叠加近处红色：

$$
\mathbf C_{far\rightarrow near}
=(0.5,0,0)+0.5(0,0,0.5)
=(0.5,0,0.25)
$$

读作“近层贡献 $0.5$ 的红色，并让远层已有蓝色的一半继续透过”，最终红色分量为 $0.5$、蓝色分量为 $0.25$。箭头表示绘制顺序，不是向量运算；公式没有除法。它对应当前 blend pipeline 的正确调用顺序。

若按近到远绘制，远层会在第二次 blend 中被当成前景：

$$
\mathbf C_{near\rightarrow far}
=(0,0,0.5)+0.5(0.5,0,0)
=(0.25,0,0.5)
$$

读作“蓝色错误地取得主要权重，只让先画的红色透过一半”，所以结果变成蓝色更强。各三元组仍是 RGB 向量，箭头只描述提交方向；这里也没有分子和分母。两种结果不同，直接说明这种 Alpha 合成不可随意交换绘制顺序。

### 9.6 为什么普通 depth buffer 不能代替半透明排序

普通不透明渲染可以让 depth test 只保留离相机最近的片元，因为被挡住的远处表面不再贡献颜色。半透明高斯不同：只要近层满足 $\alpha_N<1$，上面的正确公式就仍包含远层项 $(1-\alpha_N)\alpha_F\mathbf c_F$。如果先画近层并写 depth，再让 depth test 丢弃远层，这一项会完全消失；如果关闭 depth write，又回到了必须正确合成多个片元的问题。

当前 single-stage 的 depth compare 明确设置为 `.always`，而不是依靠普通的 nearer-wins 测试决定颜色可见性；当前 App 还使用 `depthFormat: .invalid`，根本没有 depth attachment。即便将来启用 depth 输出，depth 值也不能自动替代透明颜色的有序累积。

### 9.7 multi-stage 为什么也要求相同顺序

multi-stage 不使用上述固定功能颜色混合，而是在 [`MultiStageRenderPath.metal`](../Vendor/MetalSplatter/MetalSplatter/Resources/MultiStageRenderPath.metal) 的 imageblock 中从透明黑色开始，手写以下更新：

$$
\mathbf C_{new}
=\mathbf C_{previous}\left(1-\alpha\right)+\alpha\mathbf c
$$

读作“保留旧 imageblock 颜色 $\mathbf C_{previous}$ 的 $1-\alpha$，再加当前高斯的预乘颜色 $\alpha\mathbf c$”。$\alpha$ 和 $\mathbf c$ 来自当前 fragment，$\mathbf C_{new}$ 写回 imageblock；计算方向是当前 fragment 覆盖此前结果。公式没有分式。它对应 `previousColor * oneMinusAlpha + colorWithPremultipliedAlpha`，只是加法两项的书写顺序与 single-stage 方程相反，数学含义完全相同。

因此 multi-stage 仍需让旧值先包含远层，再由当前近层覆盖。它改善的是 tile 内颜色与 Alpha 加权深度的存储/输出方式，并没有把合成算子改成与顺序无关。

### 9.8 可以采用近到远，但必须更换累积算法

数学上可以得到同一有序合成结果的一种替代方案，是维护“到目前为止仍未被遮住的透射率” $T$，并从近到远累积：

$$
\begin{aligned}
\mathbf C_0&=\mathbf 0,\qquad T_0=1\\
\mathbf C_i&=\mathbf C_{i-1}+T_{i-1}\alpha_i\mathbf c_i\\
T_i&=T_{i-1}\left(1-\alpha_i\right)
\end{aligned}
$$

第一行读作“开始时没有累积颜色，透射率为 1”；第二行读作“第 $i$ 个由近到远的高斯，只能通过前面所有层剩下的 $T_{i-1}$ 贡献颜色”；第三行把该层遮住的部分从透射率中扣除。$i$ 是遍历序号，$\alpha_i$ 是当前层 Alpha，$\mathbf c_i$ 是 RGB 向量，$\mathbf C_i$ 是累积的预乘颜色。这里没有分式；计算方向与当前实现相反，是从近处向远处推进。

处理完 $n$ 层后再补上背景：

$$
\mathbf C_{final}=\mathbf C_n+T_n\mathbf C_B
$$

读作“所有高斯已经累积的颜色，再加最终还能透过全部高斯的背景”。$T_n$ 是一个标量，$\mathbf C_B$ 是背景 RGB 向量；标量乘向量表示三个颜色分量都乘同一比例。公式没有分子和分母。它给出与正确 back-to-front source-over 相同的有序结果。

近到远方案还有一个潜在收益：当 $T_i<\varepsilon$ 时，后续远层贡献最多只剩很小比例，可以提前终止。$\varepsilon$ 是人为选择的误差阈值，越大越快但越可能损失远处颜色。要实现它，需要 shader/tile rasterizer 能读取并更新每像素透射率，并配合近到远的 tile 内顺序；**当前 single-stage 和 multi-stage 都没有采用这套更新规则，也没有按 $T_i$ 做 early termination。**

### 9.9 当前“候选中心距离排序”仍只是近似

当前每个候选高斯只有一个排序键，而且来自其三维**中心**。未进入候选集的常驻高斯根本不会提交本帧 draw；对已经入选的高斯，中心排序仍有三类边界：

- 一个投影后的高斯覆盖许多像素，但所有像素共享中心顺序；两个大高斯相交时，不同像素的真实前后关系可能不同。
- 当前键是欧氏距离平方，既包含视线方向分量，也包含屏幕横向分量；位于屏幕边缘的中心可能因为横向距离大而被排得更远，它并不等于 view-space depth。
- 大型、强各向异性的高斯投影范围更宽，中心顺序对其边缘像素的代表性更弱。

可选演进方案各有代价：per-tile binning 与 per-tile 排序能让顺序更贴近局部像素，但增加分桶、索引和 GPU 排序成本；概念上的 per-pixel 精确排序质量更高，但存储和排序代价通常过大；front-to-back tile rasterization 可结合透射率 early termination，但要改写累积管线；OIT（order-independent transparency）可减少对严格全局顺序的依赖，但通常是近似方法，需要在显存、带宽和伪影之间取舍。这些都不是当前仓库已经实现的功能。

### 9.10 为什么不能简单让每个 chunk 各画各的

当前候选可能同时来自多个 chunk。若不同 chunk 的深度范围互相穿插，只保证各 chunk 候选在块内有序、然后整块绘制，不能得到候选集的跨 chunk 远到近顺序，因而会破坏 9.4 的合成关系。可以先做每 chunk 排序再做 k-way merge，但每个 chunk 的顺序仍随相机变化，merge 本身也有成本。只按 chunk 包围盒排序更快，但要接受交界处的混合误差。

### 9.11 后台排序和 stale-but-valid 结果

sort loop 由 `Task.detached(priority: .high)` 运行。一次循环分四阶段：

1. 复制 chunk 引用、相机 pose、候选上限和 chunk generation，选择没有 frame 引用、且不是当前发布结果的目标 buffer；
2. 从完整展平 chunk 序列确定性采出 $K$ 个引用，只读取这些候选在 shared splat buffer 中的位置并计算深度；
3. 对这 $K$ 个临时项做 Swift 远到近比较排序；
4. 写目标 `ChunkedSplatIndex` buffer，若 chunk generation 未变化且未发生 invalidation，则发布为最近有效结果。

每次 `render()` 都调用 `updateCameraPose`，但它**不会无条件排序**。当前 `sortByDistance = true`，只有世界空间相机位置变化平方满足：

$$
\left\|\mathbf c_{new}-\mathbf c_{old}\right\|^2>10^{-6}
$$

才会因 pose 设置 `needsSort`。读作“新旧相机位置向量相减，把三个分量分别平方后求和；结果大于一百万分之一才请求新排序”。向量 $\mathbf c$ 是相机世界位置；平方距离避免开平方。纯旋转不会触发距离键重排；但当前 `OrbitCamera` 绕目标改变 yaw/pitch 时通常也改变世界位置，所以一般仍会越过阈值。若把 `sortByDistance` 改为 `false`，源码还会在新旧 forward 点积小于 `0.99999` 时因旋转请求排序。

注册、添加或删除 chunk 会递增 chunk generation 并触发排序；`setMaximumRenderedSplatCount` 改变候选上限时也递增 generation 并触发重采样、重排。相机在一次排序期间再次越过阈值不会取消已经开始的 CPU 工作；旧 pose 的结果可以先发布，循环随后再为较新的 pose 排序。因此渲染可以使用落后一帧或多帧但结构仍合法的索引，换取不让 GPU 每帧等待 CPU。

### 9.12 三份 sorter index buffer

sorter 固定创建三份 index buffer。每份有 `referenceCount` 和 `isValid`：

- frame 取得最近有效 buffer 时，引用计数加一；多个 frame 可以共享同一 buffer；
- GPU completion 后 renderer 显式释放，引用计数减一；
- sorter 只选引用计数为 0、且不是当前发布 buffer 的一份来写；
- 如果暂时没有可写 buffer，后台循环每 1 ms 再检查；
- chunk 变化期间完成的旧 sort 由 `chunkGeneration` 阻止发布。

“三份”与 uniform ring 的“三槽”只是当前都等于 3，生命周期协议彼此独立。sorter 文档明确指出 index buffer 数量与 `maxSimultaneousRenders` 无关。

### 9.13 性能取舍和优先优化方向

当前方案的收益是候选跨 chunk 混排、属性全量常驻时仍把每次 CPU sort 和 GPU draw 限制在 $K$，且排序在后台进行。代价是候选抽样与可见性无关，排序仍有 $O(K\log K)$ 成本；disabled chunk 在完整展平序列中仍占候选位置，被采中的项仍付出排序和 vertex shader 成本，全部属性也保持 resident。

面向大场景，更合理的优化顺序通常是：

1. 按场景尺度和交互轨迹实测、调优已经存在的相机位置/方向阈值；
2. 用 chunk 级视锥、驻留、LOD 或屏幕贡献选择替代当前与视点无关的等距候选；
3. 从候选构建阶段真正排除不可见/disabled chunk，而不只是 shader 标志；
4. 评估 GPU radix sort、tile binning 或 per-tile 排序；
5. 同时扫候选预算和画质指标，决定全局精确排序、chunk merge、近似排序或 OIT 的取舍。

这些属于演进方向，不是当前已经实现的功能。超大场景完整设计见 [LARGE-SCENE-RENDERING.md](LARGE-SCENE-RENDERING.md)。

## 10. `AccessState`、`withChunkAccess` 与 `render()` 的并发协议

### 10.1 五个状态字段

| 字段 | 含义 |
| --- | --- |
| `inFlightRenderCount` | 已取得 render 权限、但尚未在 GPU completion 或早退清理中完成的 render 数 |
| `isRendering` | 是否有一个 `render()` 正在 CPU 侧修改共享 `RenderState` 并编码 |
| `hasExclusiveAccess` | 是否有 task 正在独占修改 renderer chunk 集合 |
| `exclusiveAccessWaiters` | 按进入顺序等待独占访问的 continuation 队列 |
| `maxSimultaneousRenders` | 允许的 GPU 在途上限；当前 App 为 3，不存放在 `AccessState` 内 |

`isRendering` 和 `inFlightRenderCount` 解决的是不同时间尺度：前者随 CPU 编码结束而清零，后者随 GPU 执行完成而减少。

### 10.2 `render()` 如何防止资源竞态

取得权限时必须满足：

```text
没有独占持有者
并且没有独占等待者
并且没有另一个 render 正在编码
并且 in-flight 数未达到上限
```

有独占等待者时停止接纳新 frame，是公平性设计：让已经提交的 GPU 工作逐渐排空，避免连续渲染让 chunk 修改永久饥饿。`render()` 的等待使用 `Thread.sleep(1 ms)`，会短暂阻塞调用线程；当前 App 通常先查 `isReadyToRender`，减少进入等待的机会。

若在安装 command buffer completion handler 之前早退，`defer` 会同步调用 `renderCompleted()`；安装后则由 GPU completion 调用。这样每次成功增加的 in-flight 计数原则上只减少一次。

### 10.3 `withChunkAccess` 的排队与可重入

`withChunkAccess` 只有在以下条件成立时立即授权：没有独占持有者、等待队列为空、GPU in-flight 数为 0。否则把 continuation 加到队尾。独占 body 结束时：

- 若还有等待者且 in-flight 已经为 0，直接把所有权传给队首，`hasExclusiveAccess` 保持为 `true`；
- 否则清除 `hasExclusiveAccess`，允许新 render。

`@TaskLocal` 使同一个 task 内嵌套调用可重入。例如一次独占 body 中连续调用 `removeChunk` 和 `addChunk`，内层不会再次等待自己释放权限。

### 10.4 当前协议的真实边界

`withChunkAccess` 可以证明：独占 body 执行时没有 GPU frame 还在使用 renderer 提交的 chunk 表和点 buffer，也不会有新的 `render()` 开始。它足以保护 `chunks`、`orderedChunkIDs`、`chunkIDToIndex` 的增删和 enabled 修改。

但 [`SplatSorter.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatSorter.swift) 自己还有独立的 `isReadingChunks` 和 `withExclusiveAccess` 协议，而 `SplatRenderer.withChunkAccess` 当前没有调用它。sorter 的后台 phase 1 可能在 GPU frame 已清空后仍读取 shared splat 位置。因此：

> 不能只凭 `SplatRenderer.withChunkAccess` 就断言“原地改写一个已经注册的 `SplatChunk.splats` 与 sorter 完全互斥”。

当前内置增删路径通常不原地改写已注册点。vendored library 的 `addChunk` 会在注册前完成可选 Morton 重排，remove 只改引用与索引；App 自己的 `SceneChunkLoader` 则每累计 65,536 点就构造一个 `SplatChunk` 并立即做 Morton 重排，最后通过一次 `addChunks(..., sortByLocality: false)` 注册全部预构建 chunk。两条路径都不会在 sorter 已登记后原地重排这些点，因此当前 App 的多 chunk 加载不触发这个竞态。若以后公开点编辑、对已注册 chunk 调用 `optimize`，或边流式写入边渲染，应把 renderer 独占与 sorter 的 `withExclusiveAccess/invalidateAllBuffers` 接起来，并在 API 层禁止绕过。

另外，`optimize(_:)` 只是直接调用 `chunk.sortByLocality()`，它自身不会取得独占访问，也不会使 sorter index 失效。对尚未注册的 chunk 调用是预期用法；对已注册 chunk 直接调用不安全。

## 11. Single-stage 与 multi-stage：不要和 `RenderState` 数量混淆

### 11.1 路径选择条件

`useMultiStagePipeline` 的实际条件是：

```text
真机，并且 depthFormat != .invalid，并且 highQualityDepth == true
```

模拟器强制 single-stage。当前 iPhone App 配置 `depthFormat: .invalid`、`highQualityDepth: false`，所以只走 single-stage；虽然 `RenderState` 内有 multi-stage cache 字段，它们不会在当前 App 路径被构建。

### 11.2 Single-stage

single-stage 使用一个 vertex shader 和一个 fragment shader：

- vertex：间接读取 chunk/splat，计算 SH 颜色、二维协方差和 quad；
- fragment：计算高斯 Alpha，输出预乘颜色；
- fixed-function blending：source factor 为 one，destination factor 为 `oneMinusSourceAlpha`；
- depth compare 永远是 `.always`，有 depth attachment 时可写 depth。

因为按远到近绘制，single-stage 最后写入的 depth 接近“最后覆盖该像素的较近 splat 深度”，不根据 Alpha 对多个 splat 深度做连续合成。源码注释指出，即使某个近 splat 几乎透明，也可能决定该像素最终 depth。

### 11.3 Multi-stage

multi-stage 在一个 tile render pass 中使用 imageblock memory：

1. `initializeFragmentStore` 按 tile 清零颜色和深度；
2. draw splats 时手动读取前值并累积预乘颜色与 Alpha 加权深度；
3. 全屏三角形 postprocess 把 imageblock 写到 color/depth attachment。

每个 fragment 的深度累积为：

$$
D_{new}=D_{old}(1-\alpha)+z\alpha
$$

读作“旧的累计深度 $D_{old}$ 乘当前 fragment 未遮住的比例 $1-\alpha$，再加当前深度 $z$ 乘 Alpha”。这里没有分式；两个乘积分别保留旧贡献和加入新贡献。

最终有颜色覆盖时输出：

$$
z_{out}=\frac{D}{A}
$$

读作“累计深度 $D$ 除以累计合成 Alpha $A$，得到归一化的代表深度”。分子是按透明度混合后的深度量，分母是最终颜色 Alpha。它比“最近 quad 的 z”连续，适合源码所述的 visionOS reprojection；代价是 tile/imageblock 路径更复杂，并受设备能力与 attachment 配置约束。

两条路径共享同一套 `splatVertex`、高斯 Alpha、chunk table、排序 index 和 quad template。区别主要是片元结果怎样累积和怎样产生 depth。

## 12. Chunk 的增删、启停、索引 patch 和两种排序

### 12.1 两套 chunk 标识

- `ChunkID`：对外稳定句柄，`nextChunkID` 单调增加且不复用。
- `chunkIndex`：sorter 和 shader 使用的连续 `UInt16` 下标，必须与 `orderedChunkIDs` 和本帧 `GPUChunkInfo` 数组位置一致。

删除 chunk 后，后面的连续 index 会前移，因此 renderer 重建 `chunkIDToIndex`，同时让 sorter patch 所有幸存 `ChunkedSplatIndex`。当前最大同时 chunk 数是 `UInt16.max`，即 65,535 个条目；数量达到上限时新 chunk 不加入，但仍返回一个新的、未注册的 `ChunkID`，调用者不能把“获得 ID”理解为“必然添加成功”。

### 12.2 单 chunk patch 与 App 批量注册不是同一条路径

vendored library 的 `addChunk` 会调用 sorter 的 `addChunkToSort`。当 `maximumSplatCount == .max` 时，它可以把新 chunk 的局部索引按原顺序追加到最近有效 buffer；但在当前 App 使用的有界候选模式下，新 chunk 会改变完整展平序列和等距采样位置，不能简单追加。因此 sorter 会在空闲 buffer 中按全部已注册 chunk **重新生成一份有界顺序候选索引**，后台再发布正确的跨 chunk 深度排序。没有可 patch 的有效 buffer 时也使用顺序候选 fallback。删除单个 chunk 时，sorter 单遍移除候选中的目标项，并把幸存 chunk index 改成新连续值，复杂度与当前候选 buffer 项数成正比。

当前 App 不循环调用 `addChunk`：`SceneChunkLoader` 先返回所有预构建 chunk，`GaussianSplatRenderer.load` 再调用一次 `addChunks(loadedScene.chunks, sortByLocality: false)`。`addChunks` 在一次 renderer chunk access 和 sorter exclusive access 中登记多个 `ChunkID`、重建连续 `chunkIndex`，再用 `setChunks` 触发一轮新候选排序；它不会重复执行上述逐 chunk append/patch。3,177,554 点验证资产按 65,536 点上限得到 49 个 chunk，其中前 48 个为满块，尾块为 31,826 点。

patch 或顺序候选 fallback 的收益是单个 chunk 变化后可以尽快得到结构合法的 index；代价是它在后台 sort 发布前不保证正确远到近混排。`afterNextSort` 是 library 提供的一次性完成回调，可用于等下一次成功排序后再启用新 chunk；它不是 `SceneChunkLoader` 的 API，也不是当前 App 批量注册的必要步骤。

`addChunkToSort` 和 `removeChunkFromSort` 的错误在 renderer 中由 `try?` 忽略。通常只有 Metal buffer 扩容失败才会触发；发生后后台候选排序仍可能恢复，但调用者不会收到 patch 失败。shader 的 chunk/splat 边界检查可避免一部分 stale index 越界，却不能保证临时画面顺序正确。

### 12.3 enabled 是 GPU 标志，不是驻留或排序标志

`setChunkEnabled` 只修改 `ChunkEntry.isEnabled`。下一帧重建 chunk table 时，shader 看到 `enabled = 0` 后把顶点退化。这样切换几乎没有排序等待，但 disabled chunk 仍然：

- 继续占据完整展平序列中的位置，并可能被均匀抽为候选；
- 被抽中的项继续出现在 `splatIndexBuffer` 并参加跨 chunk 排序；
- 被抽中的项继续进入 vertex shader，读取 index 和 chunk info 后才退出；
- 其 splat/SH buffer 仍被 `useResource` 声明 resident。

因此 enabled 不是大场景的 culling/streaming 机制。更精确地说，disabled chunk 仍占据完整展平采样序列的位置；只有命中的候选进入排序索引和 vertex shader，并非该 chunk 的每个常驻高斯都会在有界模式下被逐帧处理。

### 12.4 Morton 本地排序与相机候选排序不是一回事

`addChunk(..., sortByLocality: true)` 注册前调用 [`SplatChunk+sortByLocality.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatChunk+sortByLocality.swift)：

1. 用位置均值 $\pm2.5$ 倍标准差建立近似 bounds；
2. 每轴归一化、clamp 并量化到 10 bit，即 `0...1023`；
3. 逐 bit 交错 `x/y/z` 得到 30-bit Morton code；
4. 按 code 排序，原地重排基础 splat；
5. 若有高阶 SH，把每点整组系数按同一 permutation 重排。

Morton code 可以写成位交错：

$$
M(x,y,z)=\sum_{i=0}^{9}
\left(x_i2^{3i}+y_i2^{3i+1}+z_i2^{3i+2}\right)
$$

读作“取量化坐标 $x,y,z$ 的第 $i$ 个二进制位 $x_i,y_i,z_i$，依次放到结果的第 $3i$、$3i+1$、$3i+2$ 位，再从 0 到 9 累加”。求和没有分母；$2^k$ 表示该 bit 的位置权重。它是经典三维 Morton/Z-order 的直接 bit-interleaving 实现。

这是一种一次性的、与相机无关的**物理数据排列**，目标是让空间附近的点更可能在内存中相邻。`SplatSorter` 则对等距抽出的候选做持续的、与相机有关的**索引排列**，目标是透明混合顺序。前者不替代后者，也不能保证跨 chunk depth sort 后所有相邻 index 仍连续访问。

当前 App 的调用顺序是 `SceneChunkLoader` 对每个至多 65,536 点的 chunk 先执行这项 Morton 重排，然后 `addChunks(..., sortByLocality: false)` 一次注册；这里传 `false` 是为了避免 vendored library 再排序一次。`SceneChunkLoader` 是 App wrapper 的内部加载器，不是 `MetalSplatter` 对通用使用者承诺的公共读取 API。

## 13. `maxViewCount = 2` 与当前 App 的单视图

库常量 2 同时体现在：

- Swift `Constants.maxViewCount`；
- `UniformsArray` 的两个字段；
- Metal `kMaxViewCount`；
- pipeline 的 `maxVertexAmplificationCount`。

构造时公开的 `maxViewCount` 会被 `min(requested, 2)` 截断。传入两个 view 时，renderer 设置两个 viewport 和 vertex amplification mapping；一次 draw 的每个逻辑顶点会为两个 render-target layer 各执行一次投影。排序仍只有一条，使用两眼平均位置/forward；高阶 SH 也使用写入两个 uniforms 的同一个平均相机位置。

当前 App 明确传 `maxViewCount: 1`，每帧也只传 `[descriptor]`，没有双眼渲染。双眼限制、平均眼位的取舍和输入契约见 [STEREO-RENDERING.md](STEREO-RENDERING.md)。

当前 `render()` 没有显式拒绝空 `viewports` 或 `viewports.count > maxViewCount`；`updateUniforms` 的循环条件也写成 `i <= maxViewCount`，而 `setUniforms` 只处理 0、1。现有 App 输入安全，但把库用于其他调用方时，应在入口增加 `1...maxViewCount` 的前置条件，而不能依赖多余 view 被可靠忽略。

## 14. SH0–SH3：renderer 与 PLY reader 的支持范围

### 14.1 renderer 和 shader 支持四个 degree

[`SplatPoint.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPoint.swift) 定义 `.sh0`、`.sh1`、`.sh2`、`.sh3`；[`SplatProcessing.metal`](../Vendor/MetalSplatter/MetalSplatter/Resources/SplatProcessing.metal) 分级执行相应 basis。degree 为 $d$ 时，每个颜色通道的累计系数数是：

$$
n_d=(d+1)^2
$$

读作“SH degree $d$ 加一后平方，得到每个 R、G、B 通道的系数数量”。这里没有分子或分母。$d=0,1,2,3$ 时分别是 1、4、9、16。

基础 `EncodedSplatPoint.color.rgb` 只保存 SH0；额外 buffer 每点的 Float16 标量数是：

$$
r_d=3\left((d+1)^2-1\right)
$$

读作“总系数减去已经单独保存的一个 SH0，再乘 RGB 三通道”。括号中的减一排除 DC 项，外面的 3 表示每个 basis 有 R、G、B 三个标量。SH0/1/2/3 分别需要 0、9、24、45 个额外 Float16。

`GPUChunkInfo` 为每个 chunk 单独保存 `shDegree` 和 SH buffer 地址，所以不同 chunk 可以有不同 degree。shader 在每次取到 chunk 后选择 SH0 快路径或 SH1/2/3 计算。

### 14.2 同一 chunk 的 degree 必须统一

`SplatChunk(device:from:)` 从 `points.first?.color.shDegree` 推断整块 degree，随后逐点验证系数数量一致，再按统一 stride 分配 SH buffer。不一致时 initializer 抛出 `mixedSphericalHarmonics`，避免较短数据留下未写区域或较长数据越过预期容量。

常见 PLY 的 property schema 对一个 `vertex` element 是统一的，所以正常 reader 产出的整文件点天然具有同一布局。自定义 reader、手工构造点或以后按 tile 使用不同质量时，应按 degree 拆成不同 chunk，或在 chunk initializer 中增加验证。

### 14.3 PLY reader 如何推导 SH0～SH3

[`SplatPLYSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPLYSceneReader.swift) 当前规则是：

- 没有 `f_rest_*`：只组装 `f_dc_0...2`，得到 SH0；
- 9、24、45 个连续 Float32 `f_rest_*` 分别得到 SH1、SH2、SH3；
- 其他数量、缺号、错误后缀或非 Float32 都会被拒绝；
- channel-major 的 PLY 属性会按实际每通道数量重排为 RGB-interleaved triplet。

这与 [`SplatPLYSceneWriter.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPLYSceneWriter.swift) 的 0、9、24、45 输出规则闭合，SH1/SH2 可以 round-trip。格式层的完整讨论见 [3DGS-FORMATS.md](3DGS-FORMATS.md)。

## 15. 常见误解速查

| 误解 | 当前事实 |
| --- | --- |
| `RenderState` 有三份 | 只有一份；三槽是当前 uniform ring，GPU 可有三帧在途 |
| 当前使用 multi-stage，因为 `RenderState` 有那些字段 | 当前 App 无 depth attachment，所以使用 single-stage；pipeline cache 字段不等于已启用 |
| `indexedSplatCount` 是 index 数组 | 它只是最多 1024 的高斯数量；真正 quad index 数是 `6 × indexedSplatCount` |
| 每个 instance 的 1024 个高斯相同 | 只复用拓扑；`instanceID` 让每组访问不同候选排序位置 |
| quad 就是高斯椭圆 | quad 是 $\pm3\sigma$ 包围区域；fragment shader 的指数函数形成椭圆和透明度 |
| chunk 已经各自排好，所以不用混排 | Morton 是局部性物理重排；相机排序仍把来自不同 chunk 的候选混排 |
| 候选上限就是视锥剔除或 LOD | 它只是完整展平序列上的确定性等距抽样，不看相机可见性、尺度或重要性 |
| sorter 仍为所有常驻高斯建立临时深度项 | 它只为至多 `maximumRenderedSplatCount` 个候选建立临时项和排序索引；全部属性仍常驻 |
| disabled chunk 不消耗性能 | 它仍占采样序列，被命中的候选仍参加 CPU 排序和 vertex shader，只是不产生有效 rasterization |
| sorter 每帧一定重新排序并给出最新相机顺序 | pose 要越过阈值才请求排序；renderer 返回最近有效结果，快速移动时允许 stale sort |
| sorter 的三 buffer 与三帧 uniform 一一对应 | 两套 ring 独立；多帧可以引用同一排序 buffer |
| `withChunkAccess` 保护一切点编辑 | 它保护 GPU frame 和 renderer chunk 状态；当前没有自动与 sorter 读位置阶段互斥 |
| `maxViewCount = 2` 表示当前 App 正在双眼渲染 | 库上限是 2，当前 App 请求并提交的都是 1 个 view |
| 只能渲染 SH0/SH3 | shader、chunk 和当前 PLY reader 都支持 SH0～SH3；reader 会严格拒绝非 0/9/24/45 的高阶标量数 |

## 16. 建议亲手做的验证实验

状态卡现在可以直接观察 **completed FPS**、平均 GPU ms、最近一次 sort ms、当前 candidate 数和加载摘要（总点数、SH、chunk、文件/属性 MiB、加载秒数）。这些是开发反馈，不等于完整性能剖析：CPU/GPU 各 stage、峰值与常驻内存、overdraw、frame/sort p95 仍需 Instruments、Metal System Trace 或 GPU capture，并应保留原始样本而不只记平均值。

1. **确认 uniform ring**：在 `switchToNextDynamicBuffer` 记录 `uniformBufferIndex/offset`，观察当前 App 为 `1,2,0` 循环；再用 GPU capture 检查每帧 vertex buffer offset。
2. **确认 instance 映射**：临时把 `maxIndexedSplatCount` 改为很小的 4 或 8，在 shader 输出由 `instanceID` 着色的颜色，验证同一 index template 访问不同高斯。
3. **确认 $3\sigma$ quad**：把 `kBoundsRadius` 从 3 改为 1、2、4，观察截断、overdraw 和边缘能量变化。修改后顶点扩展和 fragment cutoff 必须保持同一常数。
4. **比较排序键与阈值**：在 `sortByDistance = true` 下分别做真正固定眼位的纯旋转、OrbitCamera 轨道旋转和平移，核对只有世界位置平方变化大于 `1e-6` 才因 pose 产生 sort；再切换 forward 键录制伪影、sort ms 和 p95，不要用单帧截图下结论。
5. **验证候选抽样**：固定 chunk 顺序，记录不同 candidate 上限产生的展平下标，核对 $q_j=\lfloor jN_{all}/K\rfloor$；再移动相机，确认候选成员不随可见性改变，只有顺序改变。
6. **测 disabled 成本**：加入同规模 enabled/disabled chunk，分别测 sorter 候选构成、sort p95 和 vertex invocation；它能验证 enabled 只是 shader 门控，而不是从抽样序列移除。
7. **测重排价值**：同一数据分别预先 Morton 重排或保持原序，用 Metal System Trace 或 counter 比较 vertex cache、GPU time 和 overdraw；App 路径应保持 `addChunks(..., sortByLocality: false)`，避免重复重排。
8. **验证格式、并发与内存边界**：把 SH0–SH3 writer 输出交给 reader 做 0/9/24/45 高阶标量 round-trip；另用显式钩子验证 sorter phase 1 与点原地重排必须互斥，并用 Instruments 记录加载峰值、稳定常驻、CPU/GPU stage 和 frame/sort p95。

## 17. 最小使用示例

下面保留当前 App 的关键调用形状，省略错误 UI、日志和状态发布：

```swift
// SceneChunkLoader 属于 App wrapper：它流式消费 reader.read()，每 65,536 点
// 构造一个 SplatChunk，并在注册前完成该 chunk 的 Morton 重排。
let loadedScene = try await SceneChunkLoader.load(url: url, device: device)
let initialCandidateCount = min(loadedScene.splatCount, 1_000_000)

let renderer = try SplatRenderer(
    device: device,
    colorFormat: .bgra8Unorm_srgb,
    depthFormat: .invalid,
    sampleCount: 1,
    maxViewCount: 1,
    maxSimultaneousRenders: 3,
    maximumRenderedSplatCount: initialCandidateCount,
    highQualityDepth: false
)

await renderer.addChunks(loadedScene.chunks, sortByLocality: false)
```

逐帧使用一个 view：

```swift
let didRender = try renderer.render(
    viewports: [viewport], // 当前 App 只传一个 ViewportDescriptor
    colorTexture: drawable.texture,
    colorStoreAction: .store,
    depthTexture: nil,
    rasterizationRateMap: nil,
    renderTargetArrayLength: 0,
    to: commandBuffer
)

if didRender {
    commandBuffer.present(drawable)
}
commandBuffer.commit()
```

这里必须区分两层：`SplatRenderer`/`SplatChunk`/`addChunks` 是 vendored `MetalSplatter` library API，`SceneChunkLoader.load` 是当前 App 的内部 wrapper，不应被当成库的通用 reader API。它避免整场 `[SplatPoint]`，但要读完整文件并让全部 chunk 属性常驻后才发布 renderer；候选上限只约束排序和绘制，不减少属性常驻。当前 3,177,554 点资产生成 49 个 chunk。内存峰值和分批读取见 [DATA-STRUCTURES.md](DATA-STRUCTURES.md)，真正按视点驻留的 tile/LOD 目标见 [LARGE-SCENE-RENDERING.md](LARGE-SCENE-RENDERING.md)。

## 18. 推荐源码阅读顺序

1. [`GaussianSplatRenderer.swift`](../GaussianSplatMobile/Renderer/GaussianSplatRenderer.swift)：先看 App 如何构造 renderer、设置 candidate 预算、一次注册 chunks、建立单 view descriptor 和提交 command buffer。
2. [`SceneChunkLoader.swift`](../GaussianSplatMobile/Renderer/SceneChunkLoader.swift)：区分 App wrapper 的 reader 流、65,536 点批次、逐 chunk Morton 和 library API。
3. [`SplatRenderer.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatRenderer.swift)：按 `Constants → Uniforms → RenderState/AccessState → chunk API → render()` 阅读。
4. [`ShaderCommon.h`](../Vendor/MetalSplatter/MetalSplatter/Resources/ShaderCommon.h)：把 Swift 字段和 Metal ABI 一一对上。
5. [`SingleStageRenderPath.metal`](../Vendor/MetalSplatter/MetalSplatter/Resources/SingleStageRenderPath.metal)：理解 `instanceID/vertexID → candidate splatID → chunk/local index`。
6. [`SplatProcessing.metal`](../Vendor/MetalSplatter/MetalSplatter/Resources/SplatProcessing.metal)：顺着 SH、二维协方差、特征分解、顶点和 Alpha 阅读。
7. [`SplatSorter.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatSorter.swift)：重点看确定性候选采样、pose/generation 触发、三 buffer 引用计数、sort loop 和四阶段 `performSort`。
8. [`SplatChunk.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatChunk.swift) 与 [`SplatChunk+sortByLocality.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatChunk+sortByLocality.swift)：理解 SH 分组不变量和 Morton 物理重排。
9. [`MultiStageRenderPath.metal`](../Vendor/MetalSplatter/MetalSplatter/Resources/MultiStageRenderPath.metal)：最后再比较 imageblock 深度累积，不要一开始把两条 pipeline 混在一起。
10. [`SplatPLYSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPLYSceneReader.swift) 与 [`SplatPLYSceneWriter.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPLYSceneWriter.swift)：确认 I/O 支持 SH0～SH3，高阶 `f_rest_*` 标量数严格对应 0/9/24/45；限制不在 renderer。

读完后应能回答三个核心问题：CPU 为什么需要一条跨 chunk 的全局索引；GPU 怎样用 1024 大小的共享拓扑模板访问 $N$ 个不同高斯；一个三维协方差怎样变成屏幕上由四顶点包围、由 fragment shader 解析绘制的二维椭圆。
