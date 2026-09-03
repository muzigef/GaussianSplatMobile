import Foundation
@preconcurrency import Metal
import MetalSplatter
import simd
import SplatIO

/// Bounded-memory scene ingestion for large Graphdeco PLY files.
///
/// At most `pointsPerChunk` decoded `SplatPoint` values are retained before
/// they are encoded into their final Metal buffers. The returned scene owns
/// only `SplatChunk` buffers; it never owns a full-scene `[SplatPoint]`.
enum SceneChunkLoader {
    static let pointsPerChunk = 65_536

    struct LoadedScene: @unchecked Sendable {
        let chunks: [SplatChunk]
        let splatCount: Int
        let center: SIMD3<Float>
        let radius: Float
        let shDegree: SHDegree
        let attributeByteCount: Int64
    }

    enum Error: LocalizedError {
        case emptyScene
        case mixedSphericalHarmonics(expected: SHDegree, actual: SHDegree, pointIndex: Int)

        var errorDescription: String? {
            switch self {
            case .emptyScene:
                return "3DGS 文件中没有可渲染的高斯点"
            case let .mixedSphericalHarmonics(expected, actual, pointIndex):
                return "同一场景包含不同 SH 阶数：第 \(pointIndex) 点为 SH\(actual.rawValue)，期望 SH\(expected.rawValue)"
            }
        }
    }

    nonisolated static func load(url: URL, device: MTLDevice) async throws -> LoadedScene {
        let reader = try AutodetectSceneReader(url)
        AppLog.loading.debug(
            "Scene reader selected type=\(String(describing: type(of: reader)), privacy: .public) chunk_splats=\(pointsPerChunk, privacy: .public)"
        )

        var chunks: [SplatChunk] = []
        var pendingPoints: [SplatPoint] = []
        pendingPoints.reserveCapacity(pointsPerChunk)

        var count = 0
        var mean = SIMD3<Float>.zero
        var squaredDistanceAccumulator: Float = 0
        var sceneSHDegree: SHDegree?

        for try await batch in try await reader.read() {
            try Task.checkCancellation()
            for point in batch {
                let pointDegree = point.color.shDegree
                if let sceneSHDegree, pointDegree != sceneSHDegree {
                    throw Error.mixedSphericalHarmonics(
                        expected: sceneSHDegree,
                        actual: pointDegree,
                        pointIndex: count
                    )
                }
                sceneSHDegree = pointDegree

                // Welford's online update computes center and variance without
                // a second pass or storing the complete point array.
                count += 1
                let delta = point.position - mean
                mean += delta / Float(count)
                let deltaAfterMeanUpdate = point.position - mean
                squaredDistanceAccumulator += simd_dot(delta, deltaAfterMeanUpdate)

                pendingPoints.append(point)
                if pendingPoints.count == pointsPerChunk {
                    let pointsToEncode = pendingPoints
                    pendingPoints = []
                    pendingPoints.reserveCapacity(pointsPerChunk)
                    let chunk = try SplatChunk(device: device, from: pointsToEncode)
                    chunk.sortByLocality()
                    chunks.append(chunk)

                    if chunks.count == 1 || chunks.count.isMultiple(of: 8) {
                        AppLog.loading.info(
                            "Scene upload progress chunks=\(chunks.count, privacy: .public) splats=\(count, privacy: .public) metal_bytes=\(device.currentAllocatedSize, privacy: .public)"
                        )
                    }
                }
            }
        }

        if !pendingPoints.isEmpty {
            let chunk = try SplatChunk(device: device, from: pendingPoints)
            chunk.sortByLocality()
            chunks.append(chunk)
        }

        guard count > 0, let shDegree = sceneSHDegree else {
            throw Error.emptyScene
        }

        let rootMeanSquareRadius = sqrt(max(0, squaredDistanceAccumulator / Float(count)))
        let baseBytes = Int64(count * MemoryLayout<EncodedSplatPoint>.stride)
        let shBytes = Int64(count * shDegree.extraCoefficientCount * 3 * MemoryLayout<Float16>.stride)

        return LoadedScene(
            chunks: chunks,
            splatCount: count,
            center: mean,
            radius: max(rootMeanSquareRadius * 2.5, 0.1),
            shDegree: shDegree,
            attributeByteCount: baseBytes + shBytes
        )
    }
}
