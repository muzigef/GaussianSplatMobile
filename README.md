# GaussianSplatMobile

一个面向 iPhone 的原生 3D Gaussian Splatting（3DGS）查看器。工程使用 SwiftUI + Metal，Target 只打包轻量 SH0 样例；完整 SH3 压力场景作为外部验收资产按需导入。

## 直接运行

1. 用 Xcode 打开 `GaussianSplatMobile.xcodeproj`。
2. 在 Target → Signing & Capabilities 中选择你的 Team，并把 Bundle Identifier 改成自己的唯一标识。
3. 选择一台安装 iOS 18 或更高版本的 iPhone。
4. 运行共享的 `GaussianSplatMobile` Scheme。该 Scheme 的 Run 配置已经设为 Release，以避免大型 PLY 在 Debug 下解析过慢。
5. 若要测真实性能，请在安装后停止 Xcode 调试，再从手机主屏幕启动 App。

工程已内置 [MetalSplatter](https://github.com/scier/MetalSplatter) 本地 Swift Package，项目记录的 vendored provenance 为提交 `2b965de`，因此构建 App 不需要联网。当前 vendored 目录不含独立 Git 元数据；若需要证明内容与该上游提交逐字一致，应按 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 中的 `VERIFY` 提示另行比对。为减少依赖，内置版本保留 PLY 与 `.splat` 读取器，不包含可选的 SPZ 读写器和命令行转换器。

## 操作

- 单指拖动：绕场景旋转。
- 双指捏合：缩放。
- 底部六个相机按钮：向左、向上、向下、向右旋转，以及缩小、放大；场景未进入就绪态时整组禁用。
- 双击画面或点右上角取景框：重置视角。
- 点右上角文件按钮：从“文件”中导入训练后的 `.ply` 或 `.splat` 场景；加载期间会暂时禁用再次导入。
- 底部状态卡在加载时显示进度指示和“正在解析训练结果并上传 GPU”；加载完成后显示高斯总数、SH 阶数、chunk 总数、文件/属性内存大小和总耗时。
- 只有就绪态才显示按已完成 Metal command buffer 统计的 FPS、当前绘制候选数，以及有样本时的平均 GPU 耗时和最近一次深度排序耗时。逐批进度不会实时显示在界面中；首个 chunk 及之后每 8 个 chunk 的累计点数和 Metal 分配量写入运行日志。

## 数据

App 启动时从 bundle 加载 [`sample_scene.ply`](GaussianSplatMobile/Resources/sample_scene.ply)，不会自动下载大型模型。完整的 [`drjohnson_full_sh3.ply`](ValidationAssets/drjohnson_full_sh3.ply) 不进入 Copy Bundle Resources；通过 [`download_validation_scene.sh`](Scripts/download_validation_scene.sh) 单独获取后，应传到 iPhone 的“文件”App，再从查看器右上角导入。下载脚本会验证固定点数、SH3 schema、精确大小和预置 SHA-256，并更新 [`drjohnson_full_sh3.json`](ValidationAssets/drjohnson_full_sh3.json)。

轻量回退资源 `sample_scene.ply` 来自 [GaussianSplats3D 的公开演示数据包](https://projects.markkellogg.org/downloads/gaussian_splat_data.zip) 中的 Bonsai 精简模型。[`download_sample.sh`](Scripts/download_sample.sh) 通过 HTTP Range 只取压缩包中的目标条目，再用 [SplatTransform](https://github.com/playcanvas/splat-transform) 转成标准 3DGS PLY，并覆盖上述回退文件：

- 175,745 个训练后的高斯；
- 位置、旋转四元数、三个尺度、透明度；
- 零阶球谐（SH degree 0）基础颜色；
- 文件 9.4 MB，SHA-256 为 `5108445bc1594d6b6c5cb862b8c5084caf339e742b397f2295230684e576989b`。

按需重新获取资源可执行：

```bash
./Scripts/download_validation_scene.sh
./Scripts/download_sample.sh
```

300 万点场景的完整验收步骤和通过条件见 [`ValidationAssets/ACCEPTANCE.md`](ValidationAssets/ACCEPTANCE.md)。

## 渲染原理

每个三维高斯具有中心、透明度、颜色和一个 $3\times3$ 协方差矩阵。矩阵可以理解为一张同时记录三个空间方向“扩散大小与倾斜关系”的表。渲染时，三维协方差被投影为屏幕上的二维椭圆：

$$
\Sigma_{2D} = J W \Sigma_{3D} W^T J^T
$$

读作“二维协方差等于投影雅可比矩阵、视图旋转、三维协方差以及相应转置矩阵依次相乘”。$\Sigma_{3D}$ 是训练得到的三维形状，$W$ 是世界空间到相机空间的旋转，$J$ 是透视投影的雅可比矩阵；雅可比矩阵描述三维位置发生微小变化时，屏幕坐标会怎样变化。代码中的实际计算位于 MetalSplatter 的 Metal 顶点阶段。

覆盖同一个像素的高斯按相机深度排序，再进行透明度合成：

$$
C = \sum_{i=1}^{N} c_i\alpha_i \prod_{j=1}^{i-1}(1-\alpha_j)
$$

读作“最终颜色等于每个高斯的颜色乘透明度，再乘前面所有高斯尚未遮住的比例，最后求和”。$c_i$ 是第 $i$ 个高斯的颜色，$\alpha_i$ 是它在当前像素的透明度，$N$ 是覆盖该像素的高斯数量。分子、分母没有出现在这个公式中；$\sum$ 表示累加，$\prod$ 表示连续相乘。

## 性能设计

- Metal 直接绘制，不经过 SceneKit/RealityKit 的通用网格层。
- PLY 在后台以异步 batch 读取；加载器的 `pendingPoints` 每累计最多 65,536 点就直接编码为一个紧凑 Metal chunk，尾批可更小，场景由多个 chunk 组成且不主动聚合完整的 `[SplatPoint]` 副本。上游 `AsyncThrowingStream` 当前没有有界 buffering/backpressure，仍可能排队多个待消费 batch。
- 渲染路径支持 SH0～SH3；高阶球谐的附加系数使用 `Float16`。
- 上传前按 Morton code 重排高斯，提升相邻像素访问时的缓存局部性。
- 相机相关的排序在后台持续更新，渲染可复用最近一份有效排序结果；排序和每帧绘制只处理有界候选集。
- 候选上限以 `min(场景点数, 1,000,000)` 初始化。对大型场景，它依据已完成帧 FPS 与平均 GPU 时间按预算调节，范围为 250,000～1,250,000，且不会超过场景总点数。
- 三缓冲允许 CPU 与 GPU 流水执行。
- 查看器不请求深度纹理，避免不必要的高质量深度合成开销。
- MTKView 将首选帧率设为 60 FPS，把它作为目标而非保证；界面显示的是实际完成帧统计值，不会请求设备最高刷新率。

实际帧率仍取决于 iPhone GPU、分辨率、温度以及模型高斯数量。这里的“分批加载”只限制 loader 的显式 pending 数组和逐 chunk 临时结构，并生成多个常驻 chunk；由于 reader stream 无背压，它不保证整个解析管线的 CPU 峰值恒定。加载完成后所有 chunk 属性仍驻留在内存/GPU 中，它也不是按需磁盘驻留或 tile streaming。

## 更换自己的模型

要临时查看自己的模型，直接使用右上角文件按钮导入，不需要修改工程。要替换内置冒烟样例，可替换 [`sample_scene.ply`](GaussianSplatMobile/Resources/sample_scene.ply)。输入必须是训练后的 3DGS PLY；例如，普通 COLMAP 点云 `my_colmap_points.ply` 不能直接作为输入。内置读取器也支持 `.splat`。

第三方许可与数据来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
