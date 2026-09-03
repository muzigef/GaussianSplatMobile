<!-- generated-by: gsd-doc-writer -->
# 3D Gaussian Splatting 文件格式指南

这份指南面向需要选择、检查或转换 3D Gaussian Splatting（3DGS）资产的开发者。先建立一个最重要的分层：**高斯的语义数据**说明“一个点代表什么”，**文件格式**说明“这些数据怎样编码和封装”，而**查看器支持**说明“某个具体 reader 实际实现了哪些布局”。三者不能仅凭扩展名互相推导。

本文把行业格式生态与 GaussianSplatMobile 的实现分开说明。前半部分介绍通用格式与取舍，最后一节给出本仓库截至 2026-08-27 的精确支持边界。

## 先理解一个高斯携带什么

普通点云的一个点往往只有位置和颜色；可渲染的 3DGS 高斯通常至少包含以下语义：

| 语义 | 常见形状 | 作用 | 常见陷阱 |
| --- | --- | --- | --- |
| 中心/均值 | $\mathbf{\mu}=(x,y,z)$ | 高斯在三维空间中的位置 | 坐标轴方向、左右手系和单位通常不由扩展名保证 |
| 尺度 | $\mathbf{s}=(s_x,s_y,s_z)$ | 沿三个局部主轴的扩散大小 | 可能存线性尺度，也可能存 $\log(s)$；2DGS 可能只有两个尺度 |
| 旋转 | 单位四元数 $q$ | 把三个局部主轴转到场景方向 | `(w,x,y,z)` 与 `(x,y,z,w)` 都很常见；还可能被量化为“smallest three” |
| 不透明度 | $\alpha$ | 控制高斯的最大 Alpha | 可能存线性 $[0,1]$、8 位整数，或 sigmoid 之前的 logit |
| 颜色 | RGB 或零阶 SH | 给出基础、视角无关的颜色 | SH0 系数不是可以直接显示的 8 位 RGB |
| 高阶球谐 | SH degree 1–3 常见 | 描述随观察方向变化的颜色 | 系数顺序、通道布局、最高阶数和颜色空间必须一致 |
| 可选标签/元数据 | antialias、2DGS、LOD、坐标系等 | 告诉 renderer 应采用哪种投影或重建约定 | 转换到不能表达该标签的格式时可能静默丢失 |

尺度和旋转共同决定三维协方差。令 $R(q)$ 是四元数生成的旋转矩阵，$\operatorname{diag}(\mathbf{s})$ 是把三个尺度放在对角线上的矩阵，则常见的重建方式是：

$$
\Sigma = R(q)\operatorname{diag}(\mathbf{s})^2R(q)^T
$$

读作“协方差等于旋转矩阵、尺度平方矩阵和旋转矩阵转置依次相乘”。$\Sigma$ 是 $3\times3$ 矩阵，描述高斯椭球的大小、长短轴与朝向；矩阵可以理解为把三维向量映射到另一个三维向量的一张规则表。这里的“平方”是三个线性尺度分别平方，不是把文件里的对数尺度直接平方。

原始 [graphdeco-inria/gaussian-splatting](https://github.com/graphdeco-inria/gaussian-splatting) 实现把训练参数写入 PLY 时保留未激活域：尺度是对数值，透明度是 logit，旋转在使用时归一化。对应的恢复关系为：

$$
s_k = \exp(\ell_k), \qquad
\alpha = \frac{1}{1+\exp(-a)}
$$

读作“第 $k$ 个线性尺度等于对数尺度 $\ell_k$ 的指数；线性透明度等于 logit $a$ 经过 sigmoid”。分式上方的 $1$ 是分子，下方的 $1+\exp(-a)$ 是分母。把已经是线性值的数据再做一次 `exp` 或 sigmoid，会产生严重的尺寸或透明度错误。

球谐 degree 为 $d$ 时，每个颜色通道累计有 $(d+1)^2$ 个系数；RGB 三通道在 SH0 之外的额外标量数为：

$$
N_{rest}=3\bigl((d+1)^2-1\bigr)
$$

读作“额外球谐标量数等于三个颜色通道乘每通道除去零阶后的系数数”。因此 degree 0、1、2、3 分别对应 `f_rest_*` 数量 0、9、24、45。向量是按顺序排列的一组数；任何 reader 若假设了另一种通道或系数排列，即使数量相同也可能得到错误的视角颜色。

## 兼容性不是扩展名判断题

在处理任何 3DGS 文件前，至少同时确认以下六项：

1. **容器与 schema**：例如 PLY 只是可声明任意 element/property 的容器；普通点云 PLY、INRIA 3DGS PLY 和 PlayCanvas compressed PLY 并非同一布局。
2. **坐标系**：右/左、上/下、前/后、单位和场景原点。PLY 本身通常没有强制的 3DGS 坐标系元数据。
3. **四元数顺序**：INRIA PLY 常见 `rot_0...3 = (w,x,y,z)`；glTF 使用 `(x,y,z,w)`；SOG 的压缩定义则明确以 `(w,x,y,z)` 排序。
4. **数值域**：线性尺度还是 log-scale，线性 Alpha 还是 logit，颜色是 RGB 还是 SH 系数。
5. **SH 约定**：degree、按 band 的 $m$ 顺序、RGB 是交错还是按通道成段、颜色空间以及查看器是否会忽略高阶项。
6. **模型标签**：抗锯齿训练、传统 3DGS、2DGS 和特定投影核可能需要不同 renderer。数据“能解析”不等于“能正确成像”。

坐标变换尤其容易只修正一半。正确转换通常要同时处理中心、旋转、尺度轴，并在存在高阶 SH 时旋转 SH 基函数；Niantic SPZ 的官方库明确在跨坐标系转换时用 Wigner-D 矩阵旋转 SH。只对 `z` 取反可能让位置看似正确，却让椭球朝向、视角色或绕序错误。

颜色也不能只看“RGB”三个字母。INRIA 风格的 `f_dc_*` 是 SH0 系数，常见基础颜色恢复使用 $C_0\approx0.2820947918$：

$$
\mathbf{c}_0 = \operatorname{clamp}\bigl(0.5 + C_0\mathbf{f}_{dc}, 0, 1\bigr)
$$

读作“把零阶系数乘常数 $C_0$，加 $0.5$ 后限制到 0 到 1”。$\mathbf{f}_{dc}$ 和 $\mathbf{c}_0$ 都是 RGB 三维向量。这个公式只解决 SH0 到基础颜色的数值映射；合成究竟在 sRGB/Rec.709 display、线性 Rec.709 还是工具自定义空间进行，仍需读取格式元数据和 renderer 约定。`KHR_gaussian_splatting` 因此把 `colorSpace` 设为必填属性。

## 文件存储顺序与格式规范

讨论“顺序”时必须先说明是哪一种；下面三者不能互相替代：

1. **结构/索引对应顺序**：位置、尺度、旋转、颜色、Alpha 和 SH 的第 $i$ 项是否共同描述第 $i$ 个 Gaussian。这通常是 reader 能否正确解码的硬约束。
2. **空间存储顺序**：Gaussian 在文件中是否按 Morton/Z-order、按 `x/y/z` 字典序、按重要性或按某种 chunk/bucket 相邻存放。它主要影响压缩、缓存和渐进显示；除非格式明确规定，否则不是有效性条件。
3. **每帧渲染深度顺序**：renderer 针对当前相机生成的前后关系，用于顺序相关的 Alpha 合成。相机一动，关系就可能改变；任何固定文件顺序都不能替代任意视角下的运行时排序。

### 结论表

| 格式 | 结构/索引硬约束 | 文件空间顺序：Morton / XYZ | 官方工具链约定 | 当前相机的渲染顺序 |
| --- | --- | --- | --- | --- |
| INRIA 3DGS PLY | 一个 `vertex` row 内的全部 property 属于同一 Gaussian | **都不要求** | 原始 `save_ply` 按张量现有 row 顺序写出，不做空间排序 | 文件未规定；renderer 运行时生成 |
| antimatter15 `.splat` | 每个 32 B record 内属性对应同一 Gaussian | **都不要求** | 参考转换器按“尺度体积因子 × Alpha”从大到小写出，服务渐进加载 | 文件重要性顺序不是深度；viewer 仍按相机排序 |
| GaussianSplats3D `.ksplat` | 私有 header/section/bucket 元数据必须与连续 splat records 对应；压缩位置依赖所属 bucket 的中心 | **都不要求** | 默认转换路径按场景中心距离分 section，再按空间 block 归 bucket | `.ksplat` 布局不是视图顺序；renderer 运行时排序 |
| SPZ v4 | 所有属性流共享 `numPoints`；格式没有跨流 remap，reader 按相同 Gaussian 顺序解释对应元素 | **都不要求** | 规范定义独立属性流与统一 `numPoints`；未定义空间重排 | 文件未规定；renderer 运行时生成 |
| PlayCanvas compressed PLY | chunk 的 min/max 元数据对应其连续 packed vertex 组；可选 SH row 与 vertex index 对齐 | Morton **不是格式硬约束**；不要求 XYZ | 当前 SplatTransform writer 先 Morton 排序，再按 256 点分 chunk | 文件未规定；renderer 运行时生成 |
| SOG v2 | 除 palette 图 `shN_centroids` 外，同一像素在所有属性图中必须是同一 Gaussian；索引按 top-left、row-major 展开 | Morton **不是公开 reader 有效性条件**；不要求 XYZ | 当前 SplatTransform writer 默认 Morton；调用者提供完整 permutation 时可覆盖 | 像素顺序不是深度；renderer 运行时生成 |
| Streamed SOG v1 | leaf 的 `offset/count` 指向 chunk 中连续、互不重叠且完整覆盖 chunk 的 runs；每个 run 内仍遵守 SOG 像素对齐 | **每个 run 内必须 Morton**；run 之间无全局顺序；不要求 XYZ | writer 建空间树、连续 runs 与单 LOD chunks | LOD/chunk 选择后，活动 Gaussian 仍需按当前相机处理深度 |
| glTF/GLB + `KHR_gaussian_splatting` | 同一 primitive 的各 Gaussian attribute accessor 以相同 vertex index 对齐 | **都不要求** | accessor/buffer 排列可由 exporter 决定 | `cameraDistance` 是运行时、由远到近的排序方法，不是文件空间顺序 |

### 逐格式判定依据

- **INRIA PLY**：[原始 `GaussianModel.save_ply`](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/scene/gaussian_model.py)把 `xyz`、法线占位、SH、Alpha、尺度和旋转按 axis 1 拼接后直接写成 `vertex` rows，没有 Morton、XYZ 或重要性排序步骤。因此普通 PLY 以及 INRIA 事实 schema 都**没有空间顺序要求**；重排 rows 只要完整同步每个 row 的全部属性，文件语义不变。
- **antimatter15 `.splat`**：[外部上游 antimatter15/splat 仓库的 `convert.py`](https://github.com/antimatter15/splat/blob/main/convert.py)在写固定 32 B records 前计算重要性并降序排列；这里的文件名指向链接中的上游脚本，不是本仓库文件：

$$
I=\exp(scale_0+scale_1+scale_2)\frac{1}{1+\exp(-opacity)}
$$

  读作“重要性 $I$ 等于三个 log-scale 的指数乘线性 Alpha”；指数项等于三个线性尺度的乘积，分式的分子是 $1$、分母是 $1+\exp(-opacity)$，也就是对 opacity logit 做 sigmoid。转换器让 $I$ 大的 Gaussian 先出现，便于顺序下载时先显示重要内容。这是**参考转换器约定**，不是 `.splat` reader 判断文件有效性的空间排序条件，也不是 Morton、XYZ 或某个相机的深度顺序。
- **GaussianSplats3D `.ksplat`**：[官方实现](https://github.com/mkkellogg/GaussianSplats3D)的 `SplatBuffer` 是项目私有的 block/bucket 格式：全局 header 后跟 section headers；压缩级别 1/2 的位置是相对 bucket center 的量化值，local splat index 还决定它属于哪个 bucket。默认 partitioner 会按到 `sceneCenter` 的量化距离分 section，再把点归入空间 block/bucket。这些 section/bucket 边界及元数据是 decoder 的布局契约，但它不是公开跨工具 Morton/XYZ 标准，也不可能预存任意相机的最终合成顺序。
- **SPZ v4**：[Niantic 规范](https://github.com/nianticlabs/spz)为所有属性流共享一个 `numPoints`，并用多条独立 Zstandard 流保存 positions、alphas、colors、scales、rotations 与 SH。格式没有提供跨流重映射表，因此 reader 必须按相同 Gaussian 顺序解释各流中的元素；这是由容器布局推导出的解码前提，不是规范另列的一条空间排序规则。规范也没有要求元素按 Morton、XYZ 或其他空间键排序。属性流的物理先后与流内 Gaussian 的空间先后不是一回事。
- **PlayCanvas compressed PLY**：[PlayCanvas PLY 说明](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/ply/)所述的 PLY 容器本身不定义空间顺序；[SplatTransform 的 compressed PLY writer](https://github.com/playcanvas/splat-transform/blob/main/src/lib/writers/write-compressed-ply.ts)当前先做 Morton 重排，再以连续 256 点计算 chunk min/max 并量化 packed vertices。reader 真正依赖的是每组 packed vertex 与其 chunk 元数据、以及 SH row 的 index 对齐；Morton 是当前 writer 改善压缩和 locality 的选择，不是“非 Morton 文件无效”的公开格式条件。
- **SOG v2**：[公开格式页](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/sog/)的硬约束是属性图在**同一像素**描述同一 Gaussian，像素 index 以左上角为原点按 row-major 计算；这只是二维纹理寻址规则，不表示三维位置按行、XYZ 或深度排列。[当前 SplatTransform SOG writer](https://github.com/playcanvas/splat-transform/blob/main/src/lib/writers/write-sog.ts)默认为 texel placement 生成 Morton permutation，但也明确接受调用者提供的完整 permutation。公开 SOG v2 格式页没有把 Morton 写成 reader 有效性条件。
- **Streamed SOG v1**：[公开格式页](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/streamed-sog/)进一步规定 leaf 的 `offset/count` 选择 chunk storage 中的连续 run；chunk 是引用它的 leaf runs 的完整拼接。**每个 run 内必须按 Morton 排列，但 run 边界之间没有任何全局顺序**。所以不能对整个 chunk 做一次全局 Morton 单调性检查，也不能把 run 拼接顺序解释成相机深度。
- **glTF/GLB + `KHR_gaussian_splatting`**：[Khronos 扩展](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_gaussian_splatting/README.md)把各属性作为同一个 `POINTS` primitive 的 vertex attributes，硬约束是相同 vertex index 的属性共同构成一个 Gaussian；它没有规定 accessor 元素按 Morton 或 XYZ 排列。默认 `sortingMethod` 是 `cameraDistance`：渲染时计算 Gaussian 到当前相机原点的向量长度并由远到近排序。这里的 `cameraDistance` 明确是**运行时渲染排序**，不是要求 GLB buffer 预先按某个相机排列。

本仓库也把这三层分开：[`SplatChunk+sortByLocality.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatChunk+sortByLocality.swift)在加载后同步重排基础属性和 SH，用 Morton 改善内存 locality；[`SplatSorter.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatSorter.swift)则在相机或 chunk 改变后重新计算距离并产生由远到近的渲染索引。前者不会让后者变得多余。Morton 的量化、bit interleave、边界与 chunk 设计见 [LARGE-SCENE-RENDERING.md 的“离线空间布局与 Morton/Z-order 顺序”](LARGE-SCENE-RENDERING.md#离线空间布局与-mortonz-order-顺序)，本文件不重复算法推导。

## 标准/原始 3DGS PLY

### 它是什么

PLY 是灵活的 Polygon File Format 容器。3DGS 生态通常所称“标准 PLY”，更准确地说是**原始 INRIA 实现形成的事实 schema**，并不是 PLY 标准后来新增了一种高斯对象。[官方 `GaussianModel.save_ply`](https://github.com/graphdeco-inria/gaussian-splatting/blob/main/scene/gaussian_model.py) 把每个高斯写成一个 `vertex`，典型属性为：

```text
element vertex N
property float x
property float y
property float z
property float nx
property float ny
property float nz
property float f_dc_0
property float f_dc_1
property float f_dc_2
property float f_rest_0
...
property float f_rest_44
property float opacity
property float scale_0
property float scale_1
property float scale_2
property float rot_0
property float rot_1
property float rot_2
property float rot_3
```

`nx/ny/nz` 在原始 3DGS 导出中通常是占位零法线，渲染高斯不依赖它们。文件可以是 ASCII、binary little-endian 或 binary big-endian，但二进制小端最常见。ASCII 便于肉眼检查，体积和解析成本也更高。

### 重要 schema 变体

| 变体 | 识别信号 | 代价或失败模式 |
| --- | --- | --- |
| 完整 INRIA SH3 | `f_dc_0...2` + `f_rest_0...44` | 全精度、可编辑，但每高斯数据多、加载慢 |
| SH0 精简 PLY | 有 `f_dc_0...2`，没有 `f_rest_*` | 丢失视角相关颜色；适合轻量查看器和移动端 |
| SH1/SH2 PLY | `f_rest_*` 分别有 9/24 个值 | 语义合理但并非所有 reader 支持；本仓库 reader 当前接受这两种数量，分别映射到 SH1/SH2 |
| RGB PLY | `red/green/blue` 替代 `f_dc_*` | 可能是 8 位 RGB，也可能是工具特有 float 域；不能假设有 SH |
| 2DGS PLY | 常见只有 `scale_0/scale_1`，无 `scale_2` | 需要 2DGS 投影/滤波路径；传统 3DGS reader 常直接报缺字段 |
| 带模型注释的 PLY | 例如 `comment SplatRenderMode: mip | 2dgs` 或 `comment antialiased 0 | 1` | 注释不是 PLY 核心标准；不认识的 reader 可能忽略，图像会偏糊或产生尺度伪影 |
| PlayCanvas compressed PLY | PLY 容器内是 chunk + packed vertex schema | 不是把普通 PLY 用 ZIP 压一下；标准 INRIA reader 不能直接读 |

[PlayCanvas 的 PLY 文档](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/ply/)把 PLY定位为源数据、编辑和交换格式。它最大的优势是字段透明、全精度和工具覆盖广；主要成本是文件大、网络交付差、ASCII 尤其慢，而且原生 PLY 没有统一的空间分块和 LOD 索引。

## antimatter15 `.splat`

[antimatter15/splat](https://github.com/antimatter15/splat) 为浏览器查看设计了非常简单的顺序记录格式。每个高斯固定 32 字节：

| 字节 | 内容 | 数值域 |
| --- | --- | --- |
| 0–11 | `x, y, z` 三个 Float32 | 位置 |
| 12–23 | `scale_x, scale_y, scale_z` 三个 Float32 | **线性**尺度 |
| 24–27 | `r, g, b, alpha` 四个 UInt8 | sRGB 基础色与线性 Alpha |
| 28–31 | 四个 UInt8 | 量化的单位四元数，传统布局按 `(w,x,y,z)` 解码 |

它没有文件头、版本号、SH、坐标系、LOD 树或自描述字段。优点是 reader 极小、固定步长、能在顺序下载时尽早显示；官方查看器也明确支持渐进加载。代价是只有 SH0，颜色、Alpha 和旋转被量化，文件内部无法说明变体。

适合兼容早期 WebGL 查看器和实现极简加载器，不适合保留高阶 SH、编辑母版或长期归档。一个名字为 `.splat` 的文件仍可能包含别的布局，文件长度能被 32 整除只是必要条件。

## GaussianSplats3D `.ksplat`

[mkkellogg/GaussianSplats3D](https://github.com/mkkellogg/GaussianSplats3D) 的 `.ksplat` 是面向该 Three.js renderer 内部缓冲的项目专用格式。其设计目标是避免加载 PLY 后再做完整重排和内存转换，因此在该查看器中加载快。

参考实现提供压缩等级 0、1、2：等级 1 把位置、尺度、旋转和 SH 从 32 位压到 16 位；等级 2 进一步把 SH 压到 8 位。参考 renderer 使用 degree 0–2 的 SH。压缩等级、Alpha 剔除阈值、场景中心、block/bucket 参数都会影响输出，不能把所有 `.ksplat` 当成一个固定“每点多少字节”的简单结构。

它适合已有 GaussianSplats3D 部署。成本是互操作性弱、编辑困难、没有跨生态标准 LOD；官方 README 还明确说明项目已不再活跃开发，并把“大场景分段与 LOD”列为未来工作。

## Niantic `.spz`

[nianticlabs/spz](https://github.com/nianticlabs/spz) 是开放源码、带版本的压缩格式，保留位置、尺度、旋转、Alpha、颜色与 SH，并通过量化和压缩流降低磁盘/网络体积。v3/v4 的旋转采用单位四元数“smallest three”表示；v4 使用带目录的 NGSP 容器和 Zstandard 流，早期版本使用 legacy gzip 路径。实际 reader 必须检查版本，不能只检查 `.spz`。

SPZ 默认物理存储坐标系是 RUB（Right, Up, Back）；官方库允许在 pack/unpack 时指定来源和目标坐标系。v4 还可携带 vendor extension，例如显式坐标系描述。一个未启用 extension 支持的 reader 可能跳过扩展并继续加载，而坐标系解释仍可能因此错误，所以“成功返回点数组”并不保证空间语义正确。

SPZ 是有损量化格式。官方项目把它定位为在视觉差异较小的前提下显著小于原始 PLY，但压缩率取决于点数、SH degree、属性分布、版本与压缩器；不能对任意场景承诺固定比例。它适合 Niantic/Scaniverse 生态、移动或网络传输，以及希望采用开放版本化压缩格式的场景。代价是需要专门解码器和压缩库，运行时 CPU/内存峰值取决于是否保留量化 GPU 布局。

## PlayCanvas `.compressed.ply`

`.compressed.ply` 仍以 PLY 作为容器，但使用 PlayCanvas 的 packed chunk + vertex schema，对位置、旋转、尺度、颜色和 SH 做分块量化，并按适合 runtime 的顺序存储。它的优势是：

- 仍可利用 PLY header 做格式自描述与探测；
- 比全 Float32 INRIA PLY 更小，并能按 chunk 延迟读取/解量化；
- PlayCanvas/SuperSplat 工具链可直接编辑、读取与重新导出。

它的关键成本也来自“看起来仍是 PLY”：只实现 INRIA `vertex` 浮点属性的 reader 会把它当作缺字段文件，而不是自动解压。文件名以 `.ply` 结尾绝不证明本仓库或另一个 PLY reader 能读；应检查 header 中的 element/property schema，或交给明确支持 compressed PLY 的工具。

它是量化格式，转换回标准 PLY 只会把已经量化的数据展开成 Float32，不会恢复丢失的精度。适合 PlayCanvas 兼容 runtime、比原始 PLY 更轻的单文件交付；若目标是极致 Web 体积或超大场景流式加载，SOG/Streamed SOG 更合适。

## PlayCanvas SOG

### bundled `.sog` 与 unbundled `meta.json` + WebP

[SOG v2 规范](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/sog/)把 SOG（Spatially Ordered Gaussians）定义为面向运行时交付的有损量化格式。每个高斯被映射到多张属性图中的同一个像素位置：

本节的 [`meta.json`](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/sog/) 以及下节的 [`lod-meta.json`](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/streamed-sog/) 都是 PlayCanvas 外部格式规定的发布产物文件名；示例目录与命令展示上游格式的可用布局，不表示本仓库包含这些文件。

```text
meta.json
means_l.webp
means_u.webp
scales.webp
quats.webp
sh0.webp
shN_centroids.webp   # 有高阶 SH 时
shN_labels.webp      # 有高阶 SH 时
```

位置跨两张图以每轴 16 位量化；尺度和 SH 使用 codebook；高阶 SH 还使用 palette/label；旋转采用 26 位 smallest-three。规范要求这些 WebP 使用**无损**编码，因为 WebP 像素本身承载的是量化整数，再做一次有损图像压缩会破坏结构数据。SOG 的量化过程已经有损，“无损 WebP”只是避免第二次不可控损坏。

两种封装共享同一语义：

- **unbundled**：以 `meta.json` 为入口，旁边放多张 WebP。便于 CDN 分文件缓存、调试和按资源请求，但部署时必须保持相对路径和 MIME/CORS 正确。
- **bundled `.sog`**：一个不再二次压缩的 ZIP 容器，根目录包含同样的 `meta.json` 与资源。便于复制和单 URL 加载，但 reader 要先读 ZIP 目录，单包本身不是多 LOD 协议。

SOG v2 坐标系为右手系，`x` 向右、`y` 向上、`z` 向后。四元数语义按 `(w,x,y,z)` 排列。`meta.json` 能保存 `model`/antialias 等模型信息；具体版本字段必须检查，不能让 v1/v2 reader 靠文件名猜测。

### Streamed SOG：`lod-meta.json`

[Streamed SOG v1 规范](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/streamed-sog/)是另一层组织方式，不是把一个 `.sog` 打开 HTTP Range 就自动得到 LOD。入口固定为 `lod-meta.json`，包含空间树、每级点数、chunk 文件表和每个叶节点在各 LOD 中的连续范围。各 chunk 是普通 **unbundled SOG** 目录：

```text
scene/
├── lod-meta.json
├── 0_0/meta.json
├── 0_0/*.webp
├── 0_1/meta.json
├── 0_1/*.webp
├── 1_0/meta.json
├── 1_0/*.webp
└── env/meta.json       # 可选、始终加载的远景环境
```

LOD 0 是最高细节，更大的 LOD 编号更粗。viewer 根据相机和空间树选择每个区域的细节，动态加载/卸载 chunk。它是本文格式中唯一明确提供**空间分块 + 多 LOD + 按需装卸协议**的选项，适合数千万高斯或超过设备常驻内存的场景。成本是构建流水线最复杂、文件数量多、需要服务器正确支持静态资源/缓存/CORS，且编辑时通常仍回到 PLY 母版。

## glTF/GLB + `KHR_gaussian_splatting`

[KhronosGroup/glTF 的 `KHR_gaussian_splatting`](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_gaussian_splatting) 把高斯作为 glTF `POINTS` primitive 的属性存储，并定义位置、线性非负尺度、线性 $[0,1]$ 不透明度、单位四元数、SH degree 0–3、kernel、颜色空间、投影和排序语义。它的价值是让高斯进入 glTF 的 scene/node/transform/buffer/accessor 体系，也允许同一资产组织普通 mesh 与 splat 内容。

按本文沿用的外部资料核对日期 **2026-08-17**，该扩展的官方状态是 **Release Candidate**，不是已被所有 glTF 查看器普遍实现的稳定基线。此日期只标记既有外部资料的核对时点，不等于本仓库 2026-08-27 的源码基线。普通 glTF loader 若不认识扩展，最多会按点云 fallback；即使能显示点，也不代表执行了高斯投影、排序和 Alpha 合成。

还要区分三件事：

- `.glb` 只说明是二进制 glTF 容器，不说明里面含高斯；必须检查 `extensionsUsed`/`extensionsRequired`、primitive mode 和属性语义。
- 含 `KHR_gaussian_splatting` 也不说明某个现有 engine 已实现该 RC 版本；扩展 schema 和实现版本都要核对。
- 基础 RC 扩展不是 SOG/Streamed SOG 的压缩或 LOD 协议。未使用额外压缩扩展时，体积倾向接近全属性 interchange 数据，而不是超压缩交付格式。

选择 GLB 的理由是新项目希望接入标准化 glTF scene graph、混合 mesh/splat、资产管线和未来互操作。成本是当前支持面仍在增长，工具版本差异明显，且它不是自动解决移动内存或超大场景流式问题的方案。

## 能力与取舍矩阵

下面的“体积趋势”只比较同一场景、相近点数和 SH 的常见结果，不是承诺固定压缩率。任何剔除、降 SH、LOD 合并或异常属性分布都会改变比较。

| 格式 | 保真度与 SH | 典型体积趋势 | 加载/解码成本 | 渐进与 LOD |
| --- | --- | --- | --- | --- |
| 原始 INRIA PLY | 全 Float32；常见 SH0–SH3；最适合作母版 | 最大；ASCII 通常更大 | 解析和内存流量高；ASCII 最慢 | 容器本身无空间 LOD；顺序解析不等于可淘汰流式场景 |
| antimatter15 `.splat` | SH0；颜色/Alpha/四元数量化，位置和尺度 Float32 | 明显小于完整 SH PLY；点记录固定 32 B | 很低，固定步长 | 支持顺序渐进显示；无多 LOD/空间树 |
| `.ksplat` | 依压缩级别量化；参考 renderer 支持 SH0–SH2 | 中到小，取决于等级、SH 和剔除阈值 | 在 GaussianSplats3D 中低，布局贴近内部缓冲 | 无标准空间 LOD；官方仍把大场景 streaming/LOD 列为未来工作 |
| SPZ | 有损量化；版本化，支持 SH 与模型标志 | 小；通常显著小于 Float32 PLY | 需版本解析和 gzip/Zstd；若直接保留量化布局可降低 GPU 上传成本 | 单文件本身无空间 LOD |
| PlayCanvas compressed PLY | 有损分块量化，可保留 SH | 小于原始 PLY，通常不如 SOG 激进 | 需专用 packed PLY reader；可按 chunk 解量化 | chunk 读取有利于加载，但无相机驱动的多 LOD 树 |
| bundled/unbundled SOG | 有损量化、codebook/palette，支持高阶 SH | 很小，面向 Web 交付 | 解 WebP + codebook；数据可贴近纹理布局 | 单级；unbundled 可分资源请求，但不是 LOD |
| Streamed SOG | 每级 SOG 有损，粗 LOD 还包含几何/属性简化 | 总数据可能含多级副本；当前视角下载量小 | reader 和调度最复杂；峰值可受预算控制 | **原生空间 chunk + 多 LOD + 按需加载/卸载** |
| GLB + KHR RC | 基础扩展可用 Float/归一化属性，SH0–SH3；是否量化看 accessor/附加扩展 | 基础未压缩时偏大 | glTF 解析成熟，但 splat reader/render path 仍需专门实现 | 基础扩展无统一 splat LOD streaming |

| 格式 | 可编辑性 | 互操作性 | 成熟度（外部资料核对日：2026-08-17） | 最适合 |
| --- | --- | --- | --- | --- |
| 原始 INRIA PLY | 高，字段透明 | 3DGS 事实交换基线，但 schema 有变体 | 高、最广泛 | 研究、编辑、归档母版、跨工具交换 |
| `.splat` | 低 | 旧 Web viewer 较广；表达能力低 | 成熟但 legacy | 极简/旧查看器、SH0 顺序下载 |
| `.ksplat` | 低 | 主要限 GaussianSplats3D 生态 | 项目专用；官方项目不再活跃开发 | 既有 GaussianSplats3D 部署 |
| SPZ | 中低，通常先解到 PLY | Niantic 与采用 SPZ 的引擎 | 开放、版本化，v4 仍需 reader 版本匹配 | Niantic 生态、移动/网络压缩交换 |
| compressed PLY | 中，SuperSplat 可直接处理 | PlayCanvas 生态好，通用 PLY reader 差 | 活跃、项目约定 | PlayCanvas 单文件运行时资产 |
| SOG | 低，通常从 PLY 再生成 | PlayCanvas 生态强，其他 reader 需专门实现 | 活跃、已有 v2 规范 | Web/CDN、快速运行时交付 |
| Streamed SOG | 很低，属于发布产物 | 需要明确实现该协议 | 活跃、已有 v1 规范 | 超大场景、受限内存、相机驱动流式 |
| KHR GLB | 中；可用 glTF 工具检查结构 | 潜力最高，现实支持仍不普遍 | **Release Candidate** | 新标准试点、glTF scene graph、混合资产 |

## 抗锯齿、2DGS 与标签保真

抗锯齿训练模型和 2DGS 不只是“相同点数据换个标签”。不同训练核可能要求 renderer 在屏幕空间协方差、最低 kernel 尺寸或投影方式上采取对应算法。

[SplatTransform 官方说明](https://github.com/playcanvas/splat-transform#antialiased-and-2dgs-scenes)当前会读取：

- PLY 的 `comment SplatRenderMode: default | mip | 2dgs`；
- Postshot 风格 `comment antialiased 0 | 1`；
- 缺少 `scale_2` 的 PLY（判为 2DGS）；
- SPZ antialiased header bit；
- SOG `meta.json` 的模型字段。

写出时，PLY/compressed PLY、SOG 和 SPZ 能保留的标签并不相同；SPZ 会警告其不能表达 2DGS，某些其他输出会静默丢弃标签。基础 `KHR_gaussian_splatting` RC 也不应被当作这些工具特有 antialias/2DGS 标签的通用替代。转换后必须检查工具的 `--info` 输出并在目标 renderer 实机对照，不要因为文件成功写出就宣布保真。

## 哪些东西不是可直接渲染的训练场景

### 普通点云 PLY

只有 `x/y/z`、法线和 `red/green/blue` 的扫描点云缺少各向异性尺度、四元数和不透明度，不能直接按训练后的 3DGS 渲染。给每个点补常量尺度/旋转/Alpha 可以制造一种“点云转 splat”的视觉近似，但它不是训练结果，也不会凭空产生视角相关外观。

### COLMAP 文件

`cameras.bin/txt`、`images.bin/txt`、`points3D.bin/txt` 记录相机标定、位姿和稀疏重建点，是训练输入/初始化数据。原始 INRIA 工程中的 `input.ply` 通常也是 COLMAP 稀疏点云缓存，不是 `point_cloud/iteration_*/point_cloud.ply` 训练结果。它们缺少完整的每高斯尺度、旋转、Alpha 和 SH。

### 训练 checkpoint

例如 Graphdeco 的 `chkpnt*.pth` 保存优化器和张量状态，供继续训练；它不是 viewer 通用资产。必须用对应训练代码恢复并导出 PLY，不能仅改扩展名。

### 项目目录

包含照片、相机 JSON、配置、数据库、checkpoint、PLY 和日志的训练项目文件夹也不是单一 renderable scene。viewer 通常只需要其中某次迭代导出的高斯文件；相机路径等可作为附加功能另行导入。

快速判断可用 [SplatTransform](https://github.com/playcanvas/splat-transform) 的结构检查：

```bash
npx -y @playcanvas/splat-transform@3.3.0 scene.ply --info null
npx -y @playcanvas/splat-transform@3.3.0 scene.ply --stats null
```

`--info`/`--stats` 会报告格式与 `gaussian` 判定，但最终仍应在目标 reader 和 renderer 中做视觉验证。

## 使用 SplatTransform 转换

本项目的下载脚本已经固定使用 `@playcanvas/splat-transform@3.3.0`。以下命令沿用同一版本以获得可复现行为；`-w` 表示允许覆盖已存在的输出。工具的官方格式表是：PLY、compressed PLY、SOG、Streamed SOG 和 SPZ 可读写；`.splat`、`.ksplat` 只可读；GLB 只可写。

### 先做无损方向的规范化与检查

```bash
# 标准 PLY 重新写成标准 PLY；不会主动恢复源文件已经丢失的信息
npx -y @playcanvas/splat-transform@3.3.0 -w input.ply normalized.ply
```

即使 PLY→PLY 使用 Float32 字段，也要比较点数、SH degree、模型标签、坐标系和图像结果；不同 schema 的规范化可能丢掉工具不认识的自定义属性。

### 从 legacy `.splat` 或 `.ksplat` 恢复为 PLY

```bash
npx -y @playcanvas/splat-transform@3.3.0 -w legacy.splat restored-from-splat.ply
npx -y @playcanvas/splat-transform@3.3.0 -w scene.ksplat restored-from-ksplat.ply
```

- `.splat` 原本没有高阶 SH；写成 PLY 后也不能恢复。
- `.splat` 的 8 位颜色/Alpha/四元数和 `.ksplat` 的压缩级别量化会被展开为浮点数，但精度不会回来。
- SplatTransform 不写 `.splat` 或 `.ksplat`。若确实要生成 `.ksplat`，应使用 GaussianSplats3D 官方转换器，并明确压缩等级、Alpha 阈值和 SH degree。

### SPZ

```bash
# 默认写 SPZ v4；有损量化
npx -y @playcanvas/splat-transform@3.3.0 -w source.ply delivery.spz

# 解开为标准 PLY；不会逆转 SPZ 已发生的量化
npx -y @playcanvas/splat-transform@3.3.0 -w delivery.spz restored-from-spz.ply
```

失败重点：reader 版本不匹配、忽略坐标系 extension、旧 gzip 与新 Zstd 路径不兼容、模型标签被目标端忽略。

### compressed PLY

```bash
# 标准 PLY → PlayCanvas packed/quantized PLY（有损）
npx -y @playcanvas/splat-transform@3.3.0 -w \
  source.ply source.compressed.ply

# 展开回标准 INRIA 风格 PLY（量化损失仍在）
npx -y @playcanvas/splat-transform@3.3.0 -w \
  source.compressed.ply restored-from-compressed.ply
```

失败重点：目标 reader 只认识标准 `vertex` Float32 schema；不要因为输出仍含 `.ply` 后缀就跳过兼容性测试。

### bundled 与 unbundled SOG

```bash
# 单文件 bundle（有损量化）
npx -y @playcanvas/splat-transform@3.3.0 -w source.ply web/scene.sog

# 多文件目录；入口文件名必须是 meta.json
npx -y @playcanvas/splat-transform@3.3.0 -w source.ply web/scene/meta.json

# 两种 SOG 都可展开回 PLY，但无法恢复量化与 SH palette 聚类损失
npx -y @playcanvas/splat-transform@3.3.0 -w \
  web/scene.sog restored-from-sog.ply
npx -y @playcanvas/splat-transform@3.3.0 -w \
  web/scene/meta.json restored-from-unbundled-sog.ply
```

SOG 压缩可用 GPU，也可用 `-g cpu` 强制 CPU；后者通常更慢。unbundled 部署时必须上传 `meta.json` 引用的全部 WebP，不能只复制入口 JSON。

### Streamed SOG

先生成多个 LOD PLY，再把每个输入标记为对应等级：

```bash
# 第一步会改变点数和细节，是明确的有损简化
npx -y @playcanvas/splat-transform@3.3.0 -w source.ply -d 50% lod1.ply
npx -y @playcanvas/splat-transform@3.3.0 -w source.ply -d 25% lod2.ply

# 第二步建立空间树和 SOG chunks；入口必须恰好名为 lod-meta.json
npx -y @playcanvas/splat-transform@3.3.0 -w \
  source.ply -l 0 \
  lod1.ply -l 1 \
  lod2.ply -l 2 \
  web/streamed/lod-meta.json

# 只抽取最高细节 LOD 回 PLY
npx -y @playcanvas/splat-transform@3.3.0 -w \
  web/streamed/lod-meta.json --select-lod 0 restored-lod0.ply
```

LOD 转换的主要成本不只是量化，还有 decimation 对几何、Alpha 和颜色表示的近似。发布前应分别测试近景切换、远景覆盖、chunk 边界、网络失败重试与设备内存预算。

### GLB + `KHR_gaussian_splatting`

```bash
# SplatTransform 当前支持写 GLB，不支持把 GLB 作为输入
npx -y @playcanvas/splat-transform@3.3.0 -w source.ply scene.glb
```

该命令生成带 `KHR_gaussian_splatting` 的 GLB。它不是通用“转回 PLY”工作流，因为当前 SplatTransform 格式表将 `.glb` 标为 output-only。发送给用户前，应在目标引擎实际版本中验证 RC 扩展；普通 glTF 模型查看器可能只显示点或完全忽略高斯效果。

### 为 GaussianSplatMobile 生成最稳妥的输入

本仓库当前 PLY reader 接受连续、Float32 的 0、9、24、45 个 `f_rest_*` 标量，分别对应 SH0、SH1、SH2、SH3。若来源是未知 PLY 变体或压缩交付格式，最稳妥的兼容转换仍是显式降到 SH0：

```bash
npx -y @playcanvas/splat-transform@3.3.0 -w \
  input.ksplat --filter-harmonics 0 \
  GaussianSplatMobile/Resources/sample_scene.ply
```

这是**有损**选择：degree 1–3 的视角相关颜色会被删除。若要保留高阶项，应确认输出包含连续的 `f_rest_0...8`、`0...23` 或 `0...44` Float32，并在真机比较方向和颜色。

## 按目标选择格式

### 研究与编辑

选择原始、完整、binary little-endian PLY 作为工作母版；保存训练器版本、坐标系、色彩空间、相机数据和 checksum。不要只留下 compressed PLY、SPZ、SOG 或高压缩 `.ksplat`。

### 归档交换

目前最稳健的是原始 INRIA 风格 PLY + 一份说明 schema/坐标系/SH/antialias 的元数据。GLB/KHR 很有前景，但 RC 阶段不应作为唯一长期副本；可以同时生成一份用于试点。

### Web 单场景

PlayCanvas runtime 优先 SOG；需要一个方便分享的文件时选 bundled `.sog`，需要 CDN 分文件缓存和可检查资源时选 unbundled SOG。旧 viewer 兼容才选 `.splat`；既有 GaussianSplats3D 部署才选 `.ksplat`。

### 移动端

先以目标 reader 的原生布局为准，再考虑磁盘大小。SPZ/SOG 的小文件不自动意味着低峰值内存：如果加载后全部解成 Float32 和 CPU 对象，峰值仍可能很高。应测量“下载/包体、解码临时内存、最终 GPU 布局、排序缓冲”四项。对本 App，现状是先转成受支持的标准 PLY 或 `.splat`。

### 超大场景

选 Streamed SOG 或自行实现同类空间分块/LOD 系统。普通 PLY 的分批 parser、`.splat` 的顺序显示、compressed PLY 的 chunk 解码都不等于相机驱动的常驻集管理。

### 旧查看器

按其原生格式选择 `.splat` 或 `.ksplat`，并主动降低 SH/点数。保留 PLY 母版，避免将兼容输出变成唯一资产。

### 新标准与混合 3D 场景

试用 GLB + `KHR_gaussian_splatting`，特别是需要 glTF node transform、普通 mesh 与 splat 共同组织时；同时维护清晰的 fallback 与版本门槛。直到目标平台实际支持对应 RC schema 前，都不要把“.glb 能打开”等同于“高斯正确渲染”。

## 本仓库的精确支持矩阵

以下结论来自截至 2026-08-27 的当前仓库代码，不代表 upstream MetalSplatter 或 iOS 平台的一般能力：

| 输入 | 本 App 当前状态 | 代码依据与限制 |
| --- | --- | --- |
| 标准 3DGS PLY | **直接支持** | [`ContentView.swift`](../GaussianSplatMobile/UI/ContentView.swift) 优先加载完整的 `drjohnson_full_sh3.ply` 并以 `sample_scene.ply` 回退；[`SplatPLYSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPLYSceneReader.swift) 要求位置、三个尺度、Alpha、四元数和颜色字段，支持 SH0～SH3 |
| antimatter15 `.splat` | **vendored reader 直接支持，但 App 未把它作为当前资源入口** | [`AutodetectSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/AutodetectSceneReader.swift) 对 `.splat` 选择 [`DotSplatSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/DotSplatSceneReader.swift)；若实际使用还要同步修改资源引用和 [`ContentView.swift`](../GaussianSplatMobile/UI/ContentView.swift) 的扩展名 |
| SPZ | **不支持** | vendored [`Package.swift`](../Vendor/MetalSplatter/Package.swift) 排除 [`SPZSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SPZSceneReader.swift) 与 [`SPZSceneWriter.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SPZSceneWriter.swift)；[`AutodetectSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/AutodetectSceneReader.swift) 对 `.spz` 明确抛出 `cannotDetermineFormat` |
| `.ksplat` | **不支持** | [`SplatFileFormat.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatFileFormat.swift) 和 [`AutodetectSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/AutodetectSceneReader.swift) 没有 ksplat 分支；先转换为兼容 PLY/`.splat` 或新增 reader |
| PlayCanvas `.compressed.ply` | **不支持** | 当前 [`SplatPLYSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPLYSceneReader.swift) 只映射标准逐 `vertex` Float32 属性，不实现 packed chunk schema；先展开为标准 PLY |
| bundled/unbundled/Streamed SOG | **不支持** | 当前 reader 没有 ZIP、外部 SOG 规定的 `meta.json`/WebP 与 `lod-meta.json`、空间树或 LOD 解析路径；需转换或完整新增 reader 与流式资源管理 |
| GLB + `KHR_gaussian_splatting` | **不支持** | [`SplatFileFormat.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatFileFormat.swift) 和 [`AutodetectSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/AutodetectSceneReader.swift) 没有 glTF/GLB parser 或 KHR 属性映射；需转换或新增 reader，且要选定 RC schema 版本 |

bundle 仍包含轻量 [`sample_scene.ply`](../GaussianSplatMobile/Resources/sample_scene.ply)，它是 binary little-endian、175,745 个高斯、9,842,082 字节、SH0。压力验证资源 [`drjohnson_full_sh3.ply`](../ValidationAssets/drjohnson_full_sh3.ply) 是未经裁剪的 3,177,554 个高斯、SH3；[`project.pbxproj`](../GaussianSplatMobile.xcodeproj/project.pbxproj) 的 Resources build phase 同时复制两者，App 优先选择验证资源。

当前 [`SplatPLYSceneReader.swift`](../Vendor/MetalSplatter/SplatIO/Sources/SplatPLYSceneReader.swift) 的更细边界是：

- `vertex` 中位置、尺度、Alpha 和四元数都必须是 Float32；
- INRIA 字段中 `scale_*` 按 log-scale 解码，`opacity` 按 logit 解码，`rot_0...3` 按 `(w,x,y,z)` 读取；
- 颜色接受 `f_dc_0...2` Float32、legacy Float32 `red/green/blue`，或 UInt8 `red/green/blue`；
- `f_rest_*` 必须是连续 Float32，数量只能是 0、9、24、45，分别映射 SH0、SH1、SH2、SH3；
- 普通点云 PLY、2DGS 缺 `scale_2` PLY、compressed PLY，以及仅仅改名为 `.ply` 的其他数据都会失败或被错误解释。

应用现由 [`SceneChunkLoader.swift`](../GaussianSplatMobile/Renderer/SceneChunkLoader.swift) 通过异步 `read()` 按 65,536 点分批编码多个 [`SplatChunk`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatChunk.swift)，不会走整场 `readAll()` 或聚合为单个 chunk；[`SplatSorter.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatSorter.swift) 与 [`SplatRenderer.swift`](../Vendor/MetalSplatter/MetalSplatter/Sources/SplatRenderer.swift) 把排序和绘制限制为有界候选集，但所有 chunk 的全量属性仍常驻，没有 Streamed SOG 的按需下载、LOD 或内存淘汰能力。运行时现状见 [MILLION-SPLAT-IMPLEMENTATION.md](MILLION-SPLAT-IMPLEMENTATION.md)。
