import Foundation

/// Name, version, and where files live. The name comes from the built app.
enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "BVRD"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    // ~/Library/Application Support/<name>, or BVRD_DATA_DIR for a test install.
    static let supportURL = ProcessInfo.processInfo.environment["BVRD_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
    static let modelURL = supportURL.appendingPathComponent("Model", isDirectory: true)
    static let userVoicesURL = supportURL.appendingPathComponent("Voices", isDirectory: true)
    static let settingsURL = supportURL.appendingPathComponent("settings.json")
    static let logsURL = supportURL.appendingPathComponent("logs", isDirectory: true)

    // Files shipped inside the app.
    static let resourcesURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    static let bundledVoicesURL = resourcesURL.appendingPathComponent("Voices", isDirectory: true)
    static let pythonURL = resourcesURL.appendingPathComponent("python/bin/python3")
    static let serverScriptURL = resourcesURL.appendingPathComponent("server/speakd.py")
    static let manifestURL = resourcesURL.appendingPathComponent("model_manifest.json")
    static let noticesURL = resourcesURL.appendingPathComponent("THIRD_PARTY_NOTICES.md")
    static let playerURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BVRDPlayer")
}
