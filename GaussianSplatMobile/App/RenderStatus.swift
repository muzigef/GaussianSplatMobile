import Combine
import Foundation

@MainActor
final class RenderStatus: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var splatCount = 0
    @Published private(set) var framesPerSecond = 0
    @Published private(set) var averageGPUMilliseconds: Double?
    @Published private(set) var lastSortMilliseconds: Double?
    @Published private(set) var candidateSplatCount = 0
    @Published private(set) var shDegree = 0
    @Published private(set) var chunkCount = 0
    @Published private(set) var loadSummary = ""

    func beginLoading() {
        AppLog.state.info("Render state changed to loading")
        phase = .loading
        splatCount = 0
        framesPerSecond = 0
        averageGPUMilliseconds = nil
        lastSortMilliseconds = nil
        candidateSplatCount = 0
        loadSummary = "正在解析训练结果并上传 GPU"
    }

    func finishLoading(splatCount: Int,
                       byteCount: Int64,
                       elapsed: TimeInterval,
                       shDegree: Int,
                       chunkCount: Int,
                       candidateSplatCount: Int,
                       attributeByteCount: Int64) {
        self.splatCount = splatCount
        self.shDegree = shDegree
        self.chunkCount = chunkCount
        self.candidateSplatCount = candidateSplatCount
        loadSummary = String(
            format: "SH%d · %d chunks · 文件 %.1f / 属性 %.1f MiB · %.2f 秒",
            shDegree,
            chunkCount,
            Double(byteCount) / 1_048_576.0,
            Double(attributeByteCount) / 1_048_576.0,
            elapsed
        )
        phase = .ready
        let elapsedText = String(format: "%.3f", elapsed)
        AppLog.state.notice(
            "Render state changed to ready splats=\(splatCount, privacy: .public) bytes=\(byteCount, privacy: .public) elapsed_seconds=\(elapsedText, privacy: .public)"
        )
    }

    func fail(_ error: Error) {
        AppLog.state.error("Render state changed to failed error=\(error.localizedDescription, privacy: .public)")
        phase = .failed(error.localizedDescription)
    }

    func fail(message: String) {
        AppLog.state.error("Render state changed to failed error=\(message, privacy: .public)")
        phase = .failed(message)
    }

    func recordFrameRate(_ value: Int, gpuSeconds: TimeInterval) {
        framesPerSecond = value
        averageGPUMilliseconds = gpuSeconds > 0 ? gpuSeconds * 1_000 : nil
    }

    func recordCandidateSplatCount(_ value: Int) {
        candidateSplatCount = value
    }

    func recordSortDuration(_ seconds: TimeInterval) {
        lastSortMilliseconds = seconds * 1_000
    }
}
