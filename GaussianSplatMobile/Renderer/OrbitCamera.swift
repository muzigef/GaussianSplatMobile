import Combine
import CoreGraphics
import simd

@MainActor
final class OrbitCamera: ObservableObject {
    let verticalFieldOfView: Float = 60 * .pi / 180

    private static let buttonRotationStep: Float = 15 * .pi / 180
    private static let buttonZoomFactor: Float = 1.2

    private(set) var target = SIMD3<Float>.zero
    private(set) var sceneRadius: Float = 1
    private(set) var yaw: Float = 3.0
    private(set) var pitch: Float = -0.1
    private(set) var distance: Float = 5

    private var fittedDistance: Float = 5
    private var orbitGestureStart: SIMD2<Float>?
    private var zoomGestureStart: Float?

    func frame(sceneCenter: SIMD3<Float>, radius: Float) {
        target = sceneCenter
        sceneRadius = max(radius, 0.1)
        fittedDistance = max(sceneRadius * 3.3, 0.5)
        let centerText = String(
            format: "(%.3f, %.3f, %.3f)",
            sceneCenter.x,
            sceneCenter.y,
            sceneCenter.z
        )
        AppLog.camera.notice(
            "Camera framed scene center=\(centerText, privacy: .public) radius=\(self.sceneRadius, privacy: .public) fitted_distance=\(self.fittedDistance, privacy: .public)"
        )
        reset()
    }

    func reset() {
        // Most INRIA-style captures use a camera convention where the useful
        // front view is near the model's negative Z side.
        yaw = 3.0
        pitch = -0.1
        distance = fittedDistance
        orbitGestureStart = nil
        zoomGestureStart = nil
        AppLog.camera.info(
            "Camera reset yaw=\(self.yaw, privacy: .public) pitch=\(self.pitch, privacy: .public) distance=\(self.distance, privacy: .public)"
        )
    }

    func updateOrbit(translation: CGSize) {
        if orbitGestureStart == nil {
            orbitGestureStart = SIMD2(yaw, pitch)
        }
        guard let start = orbitGestureStart else { return }

        yaw = start.x + Float(translation.width) * 0.006
        pitch = min(max(start.y + Float(translation.height) * 0.006, -1.45), 1.45)
    }

    func endOrbit() {
        AppLog.camera.debug(
            "Orbit gesture ended yaw=\(self.yaw, privacy: .public) pitch=\(self.pitch, privacy: .public)"
        )
        orbitGestureStart = nil
    }

    /// Applies one deterministic button step while preserving the same pitch
    /// limits used by the drag gesture. Positive yaw/pitch values correspond
    /// to dragging right/down respectively.
    func rotate(yawSteps: Int = 0, pitchSteps: Int = 0) {
        orbitGestureStart = nil
        let fullTurn = 2 * Float.pi
        yaw = (yaw + Float(yawSteps) * Self.buttonRotationStep)
            .truncatingRemainder(dividingBy: fullTurn)
        pitch = min(
            max(pitch + Float(pitchSteps) * Self.buttonRotationStep, -1.45),
            1.45
        )
        AppLog.camera.debug(
            "Camera button rotation yaw=\(self.yaw, privacy: .public) pitch=\(self.pitch, privacy: .public)"
        )
    }

    func updateZoom(magnification: CGFloat) {
        if zoomGestureStart == nil {
            zoomGestureStart = distance
        }
        guard let start = zoomGestureStart else { return }

        let scale = max(Float(magnification), 0.05)
        distance = min(max(start / scale, sceneRadius * 0.15), sceneRadius * 20)
    }

    func endZoom() {
        AppLog.camera.debug("Zoom gesture ended distance=\(self.distance, privacy: .public)")
        zoomGestureStart = nil
    }

    /// `steps > 0` zooms in; `steps < 0` zooms out. Each step changes the
    /// camera distance by 20% and uses the gesture path's scene-relative limits.
    func zoom(steps: Int) {
        guard steps != 0 else { return }
        zoomGestureStart = nil
        let factor = pow(Self.buttonZoomFactor, Float(steps))
        distance = min(
            max(distance / factor, sceneRadius * 0.15),
            sceneRadius * 20
        )
        AppLog.camera.debug(
            "Camera button zoom steps=\(steps, privacy: .public) distance=\(self.distance, privacy: .public)"
        )
    }

    var viewMatrix: simd_float4x4 {
        let moveCameraBack = matrixTranslation(0, 0, -distance)
        let orbitX = matrixRotation(radians: pitch, axis: SIMD3<Float>(1, 0, 0))
        let orbitY = matrixRotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0))
        let commonPLYUpCalibration = matrixRotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
        let centerScene = matrixTranslation(-target.x, -target.y, -target.z)

        return moveCameraBack * orbitX * orbitY * commonPLYUpCalibration * centerScene
    }

    var clipPlanes: (near: Float, far: Float) {
        let near = max(0.01, distance - sceneRadius * 3)
        let far = max(near + 10, distance + sceneRadius * 5)
        return (near, far)
    }
}
