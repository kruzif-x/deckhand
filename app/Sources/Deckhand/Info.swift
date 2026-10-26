// Info.swift — version string shown in Settings/About, read from the bundle.
import Foundation

enum AppInfo {
    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return short
    }

    static var isBeta: Bool { version.contains("b") }
}
