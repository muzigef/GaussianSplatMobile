import Foundation
@preconcurrency import Metal
import MetalKit
import MetalSplatter
import simd
import SplatIO
import UIKit

private final class SortLogGate: @unchecked Sendable {
    struct Event {
        let isFirstSort: Bool
        let shouldWarnAboutSlowSort: Bool
    }

    private let lock = NSLock()
    private var hasLoggedFirstSort = false
    private var lastSlowSortWarning = Date.distantPast

    func event(for duration: TimeInterval) -> Event {
        lock.lock()
        defer { lock.unlock() }

        let isFirstSort = !hasLoggedFirstSort
        hasLoggedFirstSort = true

        let now = Date()
        let shouldWarn = duration >= 0.05 && now.timeIntervalSince(lastSlowSortWarning) >= 5
        if shouldWarn {
            lastSlowSortWarning = now
        }

        return Event(isFirstSort: isFirstSort, shouldWarnAboutSlowSort: shouldWarn)
    }
}

@MainActor
final class GaussianSplatRenderer: NSObject, MTKViewDelegate {
    private enum PerformanceTarget {
        static let framesPerSecond = 60
        static let initialCandidateSplats = 1_000_000
        static let minimumCandidateSplats = 250_000
        static let maximumCandidateSplats = 1_250_000
        static let budgetChangeInterval: TimeInterval = 3
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let camera: OrbitCamera
    private let status: RenderStatus

    private var renderer: SplatRenderer?
    private var drawableSize = CGSize.zero
    private var renderedFrameCount = 0
    private var frameRateWindowStart = CACurrentMediaTime()
    private var accumulatedGPUTime: TimeInterval = 0
    private var lastCandidateBudgetChange = CACurrentMediaTime()
    private var loadedSplatCount = 0
    private var currentCandidateBudget = PerformanceTarget.initialCandidateSplats
    private var reportedRenderError = false
    private var loggedFirstRenderedFrame = false

    init?(view: MTKView, camera: OrbitCamera, status: RenderStatus) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            AppLog.rendering.fault("Metal device or command queue creation failed")
            status.fail(message: "当前设备不支持 Metal")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.camera = camera
        self.status = status
        super.init()

        commandQueue.label = "3DGS Render Command Queue"
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = PerformanceTarget.framesPerSecond
        view.clearColor = MTLClearColor(red: 0.025, green: 0.03, blue: 0.045, alpha: 1)
        drawableSize = view.drawableSize
        AppLog.rendering.notice(
            "Metal renderer initialized device=\(device.name, privacy: .public) preferred_fps=\(view.preferredFramesPerSecond, privacy: .public)"
        )
    }

    func load(url: URL) async {
        status.beginLoading()
        renderer = nil
        reportedRenderError = false
        loggedFirstRenderedFrame = false
        let startedAt = Date()
        AppLog.loading.notice("Scene load started file=\(url.lastPathComponent, privacy: .public)")

        do {
            let decodeStartedAt = Date()
            let loadedScene = try await Task.detached(priority: .userInitiated) { [device] in
                try await SceneChunkLoader.load(url: url, device: device)
            }.value
            try Task.checkCancellation()
            let decodeElapsedText = String(format: "%.3f", Date().timeIntervalSince(decodeStartedAt))
            let centerText = String(
                format: "(%.3f, %.3f, %.3f)",
                loadedScene.center.x,
                loadedScene.center.y,
                loadedScene.center.z
            )
            AppLog.loading.notice(
                "Scene decoded splats=\(loadedScene.splatCount, privacy: .public) chunks=\(loadedScene.chunks.count, privacy: .public) sh_degree=\(loadedScene.shDegree.rawValue, privacy: .public) center=\(centerText, privacy: .public) radius=\(loadedScene.radius, privacy: .public) attribute_bytes=\(loadedScene.attributeByteCount, privacy: .public) elapsed_seconds=\(decodeElapsedText, privacy: .public)"
            )

            currentCandidateBudget = min(
                loadedScene.splatCount,
                PerformanceTarget.initialCandidateSplats
            )
            loadedSplatCount = loadedScene.splatCount

            let splatRenderer = try SplatRenderer(
                device: device,
                colorFormat: .bgra8Unorm_srgb,
                depthFormat: .invalid,
                sampleCount: 1,
                maxViewCount: 1,
                maxSimultaneousRenders: 3,
                maximumRenderedSplatCount: currentCandidateBudget,
                highQualityDepth: false,
                clearColor: MTLClearColor(red: 0.025, green: 0.03, blue: 0.045, alpha: 1)
            )

            let status = status
            let sortLogGate = SortLogGate()
            splatRenderer.onSortComplete = { [weak status] duration in
                let milliseconds = duration * 1_000
                let durationText = String(format: "%.2f", milliseconds)
                let logEvent = sortLogGate.event(for: duration)
                if logEvent.isFirstSort {
                    AppLog.rendering.notice(
                        "Initial camera depth sort completed duration_ms=\(durationText, privacy: .public)"
                    )
                } else if logEvent.shouldWarnAboutSlowSort {
                    AppLog.rendering.warning(
                        "Camera depth sort completed slowly duration_ms=\(durationText, privacy: .public)"
                    )
                }
                Task { @MainActor in
                    status?.recordSortDuration(duration)
                }
            }

            let uploadStartedAt = Date()
            AppLog.loading.info(
                "Registering GPU chunks chunks=\(loadedScene.chunks.count, privacy: .public) splats=\(loadedScene.splatCount, privacy: .public) candidate_budget=\(self.currentCandidateBudget, privacy: .public) locality_sort=already_completed"
            )
            await splatRenderer.addChunks(loadedScene.chunks, sortByLocality: false)
            try Task.checkCancellation()
            let uploadElapsedText = String(format: "%.3f", Date().timeIntervalSince(uploadStartedAt))
            AppLog.loading.notice(
                "GPU chunks ready splats=\(loadedScene.splatCount, privacy: .public) chunks=\(loadedScene.chunks.count, privacy: .public) candidate_budget=\(self.currentCandidateBudget, privacy: .public) metal_bytes=\(self.device.currentAllocatedSize, privacy: .public) recommended_working_set=\(self.device.recommendedMaxWorkingSetSize, privacy: .public) elapsed_seconds=\(uploadElapsedText, privacy: .public)"
            )

            camera.frame(sceneCenter: loadedScene.center, radius: loadedScene.radius)
            renderer = splatRenderer

            let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            status.finishLoading(
                splatCount: loadedScene.splatCount,
                byteCount: byteCount,
                elapsed: Date().timeIntervalSince(startedAt),
                shDegree: Int(loadedScene.shDegree.rawValue),
                chunkCount: loadedScene.chunks.count,
                candidateSplatCount: currentCandidateBudget,
                attributeByteCount: loadedScene.attributeByteCount
            )
            let totalElapsedText = String(format: "%.3f", Date().timeIntervalSince(startedAt))
            AppLog.loading.notice(
                "Scene load completed file=\(url.lastPathComponent, privacy: .public) splats=\(loadedScene.splatCount, privacy: .public) chunks=\(loadedScene.chunks.count, privacy: .public) candidate_budget=\(self.currentCandidateBudget, privacy: .public) bytes=\(byteCount, privacy: .public) elapsed_seconds=\(totalElapsedText, privacy: .public)"
            )
        } catch is CancellationError {
            AppLog.loading.notice("Scene load cancelled file=\(url.lastPathComponent, privacy: .public)")
            return
        } catch {
            AppLog.loading.error(
                "Scene load failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            status.fail(error)
        }
    }

    func draw(in view: MTKView) {
        guard drawableSize.width > 0, drawableSize.height > 0,
              let renderer,
              renderer.isReadyToRender,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let aspectRatio = Float(drawableSize.width / drawableSize.height)
        let clip = camera.clipPlanes
        let projection = perspectiveRightHanded(
            verticalFieldOfView: camera.verticalFieldOfView,
            aspectRatio: aspectRatio,
            nearZ: clip.near,
            farZ: clip.far
        )
        let viewport = MTLViewport(
            originX: 0,
            originY: 0,
            width: drawableSize.width,
            height: drawableSize.height,
            znear: 0,
            zfar: 1
        )
        let descriptor = SplatRenderer.ViewportDescriptor(
            viewport: viewport,
            projectionMatrix: projection,
            viewMatrix: camera.viewMatrix,
            screenSize: SIMD2(Int(drawableSize.width), Int(drawableSize.height))
        )

        commandBuffer.label = "3DGS Frame"
        do {
            let didRender = try renderer.render(
                viewports: [descriptor],
                colorTexture: drawable.texture,
                colorStoreAction: .store,
                depthTexture: nil,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                to: commandBuffer
            )

            guard didRender else {
                commandBuffer.commit()
                return
            }

            commandBuffer.present(drawable)
            commandBuffer.addCompletedHandler { [weak self] completedBuffer in
                let gpuDuration: TimeInterval
                if completedBuffer.gpuEndTime > completedBuffer.gpuStartTime {
                    gpuDuration = completedBuffer.gpuEndTime - completedBuffer.gpuStartTime
                } else {
                    gpuDuration = 0
                }
                Task { @MainActor in
                    self?.recordCompletedFrame(gpuDuration: gpuDuration)
                }
            }
            commandBuffer.commit()
            if !loggedFirstRenderedFrame {
                loggedFirstRenderedFrame = true
                AppLog.rendering.notice(
                    "First frame submitted drawable_width=\(Int(self.drawableSize.width), privacy: .public) drawable_height=\(Int(self.drawableSize.height), privacy: .public)"
                )
            }
        } catch {
            if !reportedRenderError {
                reportedRenderError = true
                AppLog.rendering.error(
                    "Render submission failed error=\(error.localizedDescription, privacy: .public)"
                )
                status.fail(error)
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
        AppLog.rendering.debug(
            "Drawable size changed width=\(Int(size.width), privacy: .public) height=\(Int(size.height), privacy: .public)"
        )
    }

    private func recordCompletedFrame(gpuDuration: TimeInterval) {
        renderedFrameCount += 1
        accumulatedGPUTime += gpuDuration
        let now = CACurrentMediaTime()
        let elapsed = now - frameRateWindowStart
        guard elapsed >= 0.75 else { return }

        let framesPerSecond = Int((Double(renderedFrameCount) / elapsed).rounded())
        let averageGPUTime = renderedFrameCount > 0
            ? accumulatedGPUTime / Double(renderedFrameCount)
            : 0
        status.recordFrameRate(framesPerSecond, gpuSeconds: averageGPUTime)
        adjustCandidateBudgetIfNeeded(
            framesPerSecond: framesPerSecond,
            averageGPUTime: averageGPUTime,
            now: now
        )
        renderedFrameCount = 0
        accumulatedGPUTime = 0
        frameRateWindowStart = now
    }

    private func adjustCandidateBudgetIfNeeded(
        framesPerSecond: Int,
        averageGPUTime: TimeInterval,
        now: CFTimeInterval
    ) {
        guard let renderer,
              loadedSplatCount > PerformanceTarget.minimumCandidateSplats,
              now - lastCandidateBudgetChange >= PerformanceTarget.budgetChangeInterval else {
            return
        }

        let upperBound = min(loadedSplatCount, PerformanceTarget.maximumCandidateSplats)
        var nextBudget = currentCandidateBudget
        if framesPerSecond < 55 {
            nextBudget = max(
                PerformanceTarget.minimumCandidateSplats,
                Int(Double(currentCandidateBudget) * 0.8)
            )
        } else if framesPerSecond >= 59,
                  averageGPUTime > 0,
                  averageGPUTime < 0.012,
                  currentCandidateBudget < upperBound {
            nextBudget = min(upperBound, Int(Double(currentCandidateBudget) * 1.1))
        }

        guard nextBudget != currentCandidateBudget else { return }
        currentCandidateBudget = nextBudget
        lastCandidateBudgetChange = now
        renderer.setMaximumRenderedSplatCount(nextBudget)
        status.recordCandidateSplatCount(nextBudget)
        AppLog.rendering.notice(
            "Adaptive candidate budget changed splats=\(nextBudget, privacy: .public) completed_fps=\(framesPerSecond, privacy: .public) average_gpu_ms=\(averageGPUTime * 1_000, privacy: .public)"
        )
    }
}
