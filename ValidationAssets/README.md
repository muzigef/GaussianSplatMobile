# 完整 SH3 验证资产

运行 [`download_validation_scene.sh`](../Scripts/download_validation_scene.sh) 生成：

- [`drjohnson_full_sh3.ply`](./drjohnson_full_sh3.ply)：Dr Johnson iteration 30000 的完整 3,177,554 条记录，不做裁剪；
- [`drjohnson_full_sh3.json`](./drjohnson_full_sh3.json)：点数、SH degree、record stride、文件大小、SHA-256 和来源清单。

来源为 Hugging Face 数据集 [`pjramg/gaussian_splatting`](https://huggingface.co/datasets/pjramg/gaussian_splatting)，其 dataset card 说明模型由官方 Graphdeco 3D Gaussian Splatting 方法生成。使用或再分发前，请同时检查该数据集当前许可、原始场景数据许可，并引用 3DGS 论文与官方实现。

该完整 SH3 文件为 788,034,924 字节（约 752 MiB），只用于 iPhone 压力验证，不进入 App bundle。App 默认加载 [`sample_scene.ply`](../GaussianSplatMobile/Resources/sample_scene.ply)。需要进行 300 万点验收时，将完整文件传到 iPhone 的“文件”App，再从查看器右上角文件按钮导入；详细步骤见 [`ACCEPTANCE.md`](./ACCEPTANCE.md)。工程中的文件引用仅方便开发时定位资产，不属于 Copy Bundle Resources，因此物理文件不存在也不影响 App 构建。
