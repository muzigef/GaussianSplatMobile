# Third-party notices

## MetalSplatter

- Project: <https://github.com/scier/MetalSplatter>
- Project-recorded vendored provenance: revision `2b965de1934de38dda1c71cf90bf798aa948a14c`
- License: MIT
- Copyright: Sean Cier

The vendored `Package.swift` currently declares only targets contained inside `Vendor/MetalSplatter`; this project has no `Package.resolved` entry or external package checkout to notice separately.

The vendored directory does not contain independent Git metadata with which to re-prove that revision from the current checkout.

<!-- VERIFY: Compare Vendor/MetalSplatter against upstream revision 2b965de1934de38dda1c71cf90bf798aa948a14c before relying on the recorded revision as a content identity. -->

## SplatTransform

- Project: <https://github.com/playcanvas/splat-transform>
- Version used by the reproducible download script: `3.3.0`
- License: MIT

SplatTransform is only a development-time conversion tool and is not linked into the iOS application.

## Bundled trained 3DGS scene

- Archive: <https://projects.markkellogg.org/downloads/gaussian_splat_data.zip>
- Archive publisher/project: <https://github.com/mkkellogg/GaussianSplats3D>
- Source entry: `bonsai/bonsai_trimmed.ksplat`
- Source entry SHA-256: `161922dd7b5667ad1881ca3105e183d4da3b2f2fc4595c9e129fd772542cae43`
- Converted asset: `sample_scene.ply`
- Converted asset SHA-256: `5108445bc1594d6b6c5cb862b8c5084caf339e742b397f2295230684e576989b`
- Gaussian count: 175,745
- Spherical harmonics: degree 0

The bundled file is a trained and trimmed Gaussian Splatting result, not a source COLMAP point cloud. The scene originates from the Bonsai capture used by the public GaussianSplats3D demo; review upstream dataset/model terms before redistributing it in a commercial product.

## Bundled Dr Johnson SH3 validation asset

- Dataset: [`pjramg/gaussian_splatting`](https://huggingface.co/datasets/pjramg/gaussian_splatting)
- Source file: [`FO_dataset/drjohnson/point_cloud/iteration_30000/point_cloud.ply`](https://huggingface.co/datasets/pjramg/gaussian_splatting/blob/main/FO_dataset/drjohnson/point_cloud/iteration_30000/point_cloud.ply)
- Generation provenance: the dataset card and project manifest identify the model as trained with the [official Graphdeco 3D Gaussian Splatting implementation](https://github.com/graphdeco-inria/gaussian-splatting)
- Bundled asset: `ValidationAssets/drjohnson_full_sh3.ply`
- Gaussian count: 3,177,554 (complete source PLY; no vertex cropping)
- Spherical harmonics: degree 3
- Bundled asset SHA-256: `92f4898839ec4ad7f197cf6c74b89918b35ea712b4e41435593ccb152d22b7f5`
- Local provenance and validation details: [`ValidationAssets/README.md`](ValidationAssets/README.md) and [`ValidationAssets/drjohnson_full_sh3.json`](ValidationAssets/drjohnson_full_sh3.json)

The Xcode target copies this complete validation PLY into the app bundle alongside `sample_scene.ply`. The approximately 752 MiB Dr Johnson asset is included only for iPhone stress validation; this packaging arrangement is not recommended for production distribution.

This repository does not establish or grant a license for the Dr Johnson dataset, the original scene, or the trained asset. Before using or redistributing it, check the dataset's current license and the original scene's license. This notice records provenance only and is not authorization to redistribute the asset.
