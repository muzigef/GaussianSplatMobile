import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.GaussianSplatMobile"

    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    static let state = Logger(subsystem: subsystem, category: "State")
    static let loading = Logger(subsystem: subsystem, category: "SceneLoading")
    static let rendering = Logger(subsystem: subsystem, category: "Rendering")
    static let camera = Logger(subsystem: subsystem, category: "Camera")
}
