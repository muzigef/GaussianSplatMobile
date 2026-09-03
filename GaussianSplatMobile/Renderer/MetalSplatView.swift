import MetalKit
import SwiftUI

@MainActor
struct MetalSplatView: UIViewRepresentable {
    let modelURL: URL?
    let loadRequestID: UUID
    let camera: OrbitCamera
    let status: RenderStatus

    final class Coordinator {
        var renderer: GaussianSplatRenderer?
        var loadingTask: Task<Void, Never>?
        var loadedRequestID: UUID?

        deinit {
            AppLog.lifecycle.debug("Metal view coordinator deinitialized; cancelling scene load")
            loadingTask?.cancel()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        AppLog.lifecycle.debug("Creating MTKView")
        let view = MTKView(frame: .zero)
        guard let renderer = GaussianSplatRenderer(view: view, camera: camera, status: status) else {
            AppLog.rendering.fault("Unable to create GaussianSplatRenderer")
            return view
        }

        context.coordinator.renderer = renderer
        view.delegate = renderer
        AppLog.rendering.info("MTKView delegate installed")
        loadIfNeeded(context.coordinator)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        loadIfNeeded(context.coordinator)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        AppLog.lifecycle.info("Dismantling MTKView; cancelling scene load")
        view.delegate = nil
        coordinator.loadingTask?.cancel()
    }

    private func loadIfNeeded(_ coordinator: Coordinator) {
        guard let modelURL else {
            AppLog.loading.error("Default scene is unavailable")
            status.fail(message: "App 包中缺少 sample_scene.ply，请重新安装应用")
            return
        }
        guard let renderer = coordinator.renderer else { return }
        guard coordinator.loadedRequestID != loadRequestID else { return }

        coordinator.loadedRequestID = loadRequestID
        coordinator.loadingTask?.cancel()

        AppLog.loading.notice(
            "Scheduling scene load file=\(modelURL.lastPathComponent, privacy: .public)"
        )
        coordinator.loadingTask = Task {
            await renderer.load(url: modelURL)
        }
    }
}
