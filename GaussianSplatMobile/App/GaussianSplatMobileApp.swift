import SwiftUI

@main
struct GaussianSplatMobileApp: App {
    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        AppLog.lifecycle.notice(
            "Application launched version=\(version, privacy: .public) build=\(build, privacy: .public)"
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
