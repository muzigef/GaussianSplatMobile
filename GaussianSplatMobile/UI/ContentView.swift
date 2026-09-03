import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var camera = OrbitCamera()
    @StateObject private var status = RenderStatus()
    @State private var showsDetails = false
    @State private var showsSceneImporter = false
    @State private var importedModelURL: URL?
    @State private var securityScopedModelURL: URL?
    @State private var loadRequestID = UUID()

    private static let supportedSceneTypes: [UTType] = [
        UTType(filenameExtension: "ply") ?? .data,
        UTType(filenameExtension: "splat") ?? .data,
    ]

    private var activeModelURL: URL? {
        importedModelURL
            ?? Bundle.main.url(forResource: "sample_scene", withExtension: "ply")
    }

    private var activeModelName: String {
        activeModelURL?.lastPathComponent ?? "未找到场景文件"
    }

    var body: some View {
        ZStack {
            MetalSplatView(
                modelURL: activeModelURL,
                loadRequestID: loadRequestID,
                camera: camera,
                status: status
            )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(cameraGesture)
                .onTapGesture(count: 2) {
                    camera.reset()
                }

            LinearGradient(
                colors: [.black.opacity(0.58), .clear, .black.opacity(0.52)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                header
                Spacer()
                cameraControls
                statusCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showsDetails) {
            detailsView
        }
        .fileImporter(
            isPresented: $showsSceneImporter,
            allowedContentTypes: Self.supportedSceneTypes,
            allowsMultipleSelection: false,
            onCompletion: handleSceneImport
        )
        .onDisappear {
            releaseSecurityScopedModel()
        }
    }

    private var cameraGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                camera.updateOrbit(translation: value.translation)
            }
            .onEnded { _ in
                camera.endOrbit()
            }
            .simultaneously(with:
                MagnifyGesture()
                    .onChanged { value in
                        camera.updateZoom(magnification: value.magnification)
                    }
                    .onEnded { _ in
                        camera.endZoom()
                    }
            )
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("3DGS MOBILE")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(.cyan)
                Text("Metal 实时查看器")
                    .font(.headline)
            }

            Spacer()

            Button {
                showsSceneImporter = true
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(status.phase == .loading)
            .accessibilityLabel("导入 3DGS 场景")

            Button {
                camera.reset()
            } label: {
                Image(systemName: "viewfinder")
            }
            .buttonStyle(GlassButtonStyle())
            .accessibilityLabel("重置视角")

            Button {
                showsDetails = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(GlassButtonStyle())
            .accessibilityLabel("查看说明")
        }
    }

    private var cameraControls: some View {
        HStack(spacing: 8) {
            cameraControlButton(
                systemName: "arrow.left",
                accessibilityLabel: "向左旋转"
            ) {
                camera.rotate(yawSteps: -1)
            }
            cameraControlButton(
                systemName: "arrow.up",
                accessibilityLabel: "向上旋转"
            ) {
                camera.rotate(pitchSteps: -1)
            }
            cameraControlButton(
                systemName: "arrow.down",
                accessibilityLabel: "向下旋转"
            ) {
                camera.rotate(pitchSteps: 1)
            }
            cameraControlButton(
                systemName: "arrow.right",
                accessibilityLabel: "向右旋转"
            ) {
                camera.rotate(yawSteps: 1)
            }
            cameraControlButton(
                systemName: "minus.magnifyingglass",
                accessibilityLabel: "缩小"
            ) {
                camera.zoom(steps: -1)
            }
            cameraControlButton(
                systemName: "plus.magnifyingglass",
                accessibilityLabel: "放大"
            ) {
                camera.zoom(steps: 1)
            }
        }
        .disabled(status.phase != .ready)
        .opacity(status.phase == .ready ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("相机控制")
    }

    private func cameraControlButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(GlassButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var statusCard: some View {
        HStack(spacing: 12) {
            phaseIcon

            VStack(alignment: .leading, spacing: 4) {
                phaseTitle
                    .font(.subheadline.weight(.semibold))
                phaseSubtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if status.phase == .ready {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(status.framesPerSecond) FPS")
                        .font(.system(.subheadline, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                    Text("绘制 \(status.candidateSplatCount.formatted())")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let milliseconds = status.averageGPUMilliseconds {
                        Text(String(format: "GPU %.1f ms", milliseconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let milliseconds = status.lastSortMilliseconds {
                        Text(String(format: "排序 %.1f ms", milliseconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch status.phase {
        case .idle, .loading:
            ProgressView()
                .tint(.cyan)
        case .ready:
            Image(systemName: "cube.transparent.fill")
                .font(.title2)
                .foregroundStyle(.cyan)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var phaseTitle: some View {
        switch status.phase {
        case .idle:
            Text("准备加载")
        case .loading:
            Text("正在加载 3DGS")
        case .ready:
            Text("\(status.splatCount.formatted()) 个高斯")
        case .failed:
            Text("加载失败")
        }
    }

    @ViewBuilder
    private var phaseSubtitle: some View {
        switch status.phase {
        case .idle:
            Text("等待 Metal 渲染器启动")
        case .loading, .ready:
            Text(status.loadSummary)
        case .failed(let message):
            Text(message)
        }
    }

    private var detailsView: some View {
        NavigationStack {
            List {
                Section("操作") {
                    Label("单指拖动：环绕模型", systemImage: "hand.draw")
                    Label("双指捏合：拉近或远离", systemImage: "arrow.up.left.and.arrow.down.right")
                    Label("屏幕按钮：四向旋转、放大和缩小", systemImage: "cursorarrow.click")
                    Label("双击画面：重置视角", systemImage: "viewfinder")
                    Label("右上角文件按钮：导入 PLY 或 .splat 场景", systemImage: "doc.badge.plus")
                }

                Section("渲染路径") {
                    Text("PLY 按 65,536 点分批解析并直接转换为紧凑 Metal chunk，避免完整 SplatPoint 场景副本。全量属性常驻，排序和绘制采用有界候选集，并根据实际完成帧率动态调整候选数量。")
                }

                Section("样例") {
                    Text("当前文件 · \(activeModelName)")
                    Text("当前文件 · \(status.splatCount.formatted()) splats · SH\(status.shDegree) · \(status.chunkCount) chunks")
                    Text("工程只内置轻量 sample_scene.ply；完整的 317 万 SH3 验证文件需单独下载，再通过右上角文件按钮导入。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("关于此查看器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showsDetails = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func handleSceneImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }

            releaseSecurityScopedModel()
            if url.startAccessingSecurityScopedResource() {
                securityScopedModelURL = url
            }

            importedModelURL = url
            loadRequestID = UUID()
            camera.reset()
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.code != NSUserCancelledError else { return }
            status.fail(error)
        }
    }

    private func releaseSecurityScopedModel() {
        securityScopedModelURL?.stopAccessingSecurityScopedResource()
        securityScopedModelURL = nil
    }
}

private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
            .overlay {
                Circle().stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}
