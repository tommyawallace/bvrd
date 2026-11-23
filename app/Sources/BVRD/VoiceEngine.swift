import AppKit
import AVFoundation
import Foundation
import ServiceManagement

/// settings.json
struct SpeechSettings: Codable, Equatable {
    var voice = "builtin"
    var speed = 1.0
    var idleMinutes = 30.0
    var finishedSetup = false

    enum CodingKeys: String, CodingKey {
        case voice, speed
        case idleMinutes = "idle_minutes"
        case finishedSetup = "finished_setup"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpeechSettings()
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? d.voice
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        idleMinutes = try c.decodeIfPresent(Double.self, forKey: .idleMinutes) ?? d.idleMinutes
        finishedSetup = try c.decodeIfPresent(Bool.self, forKey: .finishedSetup) ?? d.finishedSetup
    }
}

/// Saved when you confirm you can clone a voice.
struct VoiceConsent: Codable, Hashable {
    var agreed: Bool
    var timestamp: String
}

/// One voice in voices.json.
struct VoiceInfo: Codable, Hashable {
    var title: String?
    var description: String?
    var source: String?
    var url: String?
    var starter: Bool?
    var consent: VoiceConsent?
}

struct Voice: Identifiable, Hashable {
    enum Kind { case builtin, starter, user }

    let name: String
    let kind: Kind
    var info: VoiceInfo?

    var id: String { name }
    var isUserVoice: Bool { kind == .user }

    var displayName: String {
        if let title = info?.title { return title }
        return kind == .builtin ? "Built-in" : name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var detail: String {
        if let description = info?.description { return description }
        return kind == .builtin ? "The standard voice" : "Cloned from your audio file"
    }

    static let builtin = Voice(name: "builtin", kind: .builtin)
}

enum VoiceError: LocalizedError {
    case invalidName, nameTaken(String), tooShort(Double), conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Please enter a name for the voice."
        case .nameTaken(let n): return "A voice named \"\(n)\" already exists."
        case .tooShort(let s): return String(format: "That recording is only %.1f seconds. Use at least 6 seconds. 10 to 20 is a good length.", s)
        case .conversionFailed(let msg): return "Couldn't read that audio file. \(msg)"
        }
    }
}

@MainActor
final class VoiceEngine: ObservableObject {
    static let defaultSample = "Hi there! This is how I sound reading your text aloud. Pretty natural, right?"

    @Published var settings = SpeechSettings()
    @Published private(set) var voices: [Voice] = [.builtin]
    @Published private(set) var isSpeaking = false
    @Published private(set) var modelLoaded = false
    @Published private(set) var modelLoading = false
    @Published var activeVoiceID: String?
    @Published var errorMessage: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var readShortcut = VoiceEngine.loadShortcut()
    @Published private(set) var hasAccessibility = SelectionReader.hasPermission

    let downloader = ModelDownloader()

    private let serverURL = URL(string: "http://127.0.0.1:59125")!
    private var server: Process?
    private var startingServer: Task<Bool, Never>?
    private var graceUntil: Date?
    private var timer: Timer?

    init() {
        try? FileManager.default.createDirectory(at: AppInfo.userVoicesURL, withIntermediateDirectories: true)
        loadSettings()
        refreshVoices()
        registerHotKey()
        downloader.onInstalled = { [weak self] in self?.warmUp() }
        warmUp()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollStatus() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server?.terminate() }
        }
    }

    // MARK: Settings

    func loadSettings() {
        guard let data = try? Data(contentsOf: AppInfo.settingsURL),
              let decoded = try? JSONDecoder().decode(SpeechSettings.self, from: data) else { return }
        settings = decoded
    }

    func saveSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: AppInfo.supportURL, withIntermediateDirectories: true)
            try encoder.encode(settings).write(to: AppInfo.settingsURL)
        } catch {
            errorMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    func isDefault(_ voice: Voice) -> Bool { settings.voice == voice.name }

    var defaultVoice: Voice { voices.first { $0.name == settings.voice } ?? .builtin }

    func setDefault(_ voice: Voice) {
        settings.voice = voice.name
        saveSettings()
    }

    func finishSetup() {
        settings.finishedSetup = true
        saveSettings()
    }

    func setIdleMinutes(_ minutes: Double) {
        settings.idleMinutes = minutes
        saveSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Voices

    private static func voiceInfoURL(in folder: URL) -> URL { folder.appendingPathComponent("voices.json") }

    private static func loadVoiceInfo(in folder: URL) -> [String: VoiceInfo] {
        guard let data = try? Data(contentsOf: voiceInfoURL(in: folder)) else { return [:] }
        return (try? JSONDecoder().decode([String: VoiceInfo].self, from: data)) ?? [:]
    }

    private func saveUserVoiceInfo(_ info: [String: VoiceInfo]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(info).write(to: Self.voiceInfoURL(in: AppInfo.userVoicesURL))
    }

    private static func voiceNames(in folder: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "wav" }.map { $0.deletingPathExtension().lastPathComponent }
    }

    func refreshVoices() {
        let starterInfo = Self.loadVoiceInfo(in: AppInfo.bundledVoicesURL)
        let userInfo = Self.loadVoiceInfo(in: AppInfo.userVoicesURL)
        let userNames = Set(Self.voiceNames(in: AppInfo.userVoicesURL))
        let starters = Self.voiceNames(in: AppInfo.bundledVoicesURL)
            .filter { !userNames.contains($0) }
            .map { Voice(name: $0, kind: .starter, info: starterInfo[$0]) }
        let users = userNames.map { Voice(name: $0, kind: .user, info: userInfo[$0]) }
        voices = [.builtin] + (starters + users).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func addVoice(from source: URL, named rawName: String, description: String, consentedAt: Date) async throws {
        let name = rawName.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        guard !name.isEmpty, name != Voice.builtin.name else { throw VoiceError.invalidName }
        guard !voices.contains(where: { $0.name == name }) else { throw VoiceError.nameTaken(name) }
        let destination = AppInfo.userVoicesURL.appendingPathComponent("\(name).wav")

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        do {
            let file = try AVAudioFile(forReading: source)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            if seconds < 6 { throw VoiceError.tooShort(seconds) }
        } catch let error as VoiceError {
            throw error
        } catch {
            throw VoiceError.conversionFailed(error.localizedDescription)
        }

        try? FileManager.default.createDirectory(at: AppInfo.userVoicesURL, withIntermediateDirectories: true)
        let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")
        let args = [source.path, "-o", destination.path, "-f", "WAVE", "-d", "LEI16@24000", "-c", "1"]
        let (status, _, err) = await Task.detached { Self.run(afconvert, args) }.value
        guard status == 0 else { throw VoiceError.conversionFailed(err) }
        var info = Self.loadVoiceInfo(in: AppInfo.userVoicesURL)
        info[name] = VoiceInfo(
            title: rawName.trimmingCharacters(in: .whitespaces),
            description: description,
            consent: VoiceConsent(agreed: true, timestamp: ISO8601DateFormatter().string(from: consentedAt))
        )
        saveUserVoiceInfo(info)
        refreshVoices()
    }

    func deleteVoice(_ voice: Voice) {
        guard voice.isUserVoice else { return }
        let url = AppInfo.userVoicesURL.appendingPathComponent("\(voice.name).wav")
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errorMessage = "Couldn't delete \(voice.displayName): \(error.localizedDescription)"
                    return
                }
                var info = Self.loadVoiceInfo(in: AppInfo.userVoicesURL)
                info[voice.name] = nil
                self.saveUserVoiceInfo(info)
                if self.settings.voice == voice.name {
                    self.settings.voice = Voice.builtin.name
                    self.saveSettings()
                }
                self.refreshVoices()
            }
        }
    }

    /// Rename a voice you added. The file name stays, so the default voice still points at it.
    func updateVoice(_ voice: Voice, title: String, description: String) {
        guard voice.isUserVoice else { return }
        var info = Self.loadVoiceInfo(in: AppInfo.userVoicesURL)
        var entry = info[voice.name] ?? VoiceInfo()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.title = trimmedTitle.isEmpty ? nil : trimmedTitle
        entry.description = trimmedDescription.isEmpty ? nil : trimmedDescription
        info[voice.name] = entry
        saveUserVoiceInfo(info)
        refreshVoices()
    }

    func revealInFinder(_ voice: Voice) {
        guard voice.isUserVoice else { return }
        NSWorkspace.shared.activateFileViewerSelecting([AppInfo.userVoicesURL.appendingPathComponent("\(voice.name).wav")])
    }

    // MARK: Voice server

    /// Start loading the model in the background.
    func warmUp() {
        guard downloader.isInstalled else { return }
        Task { _ = await ensureServer() }
    }

    private func ensureServer() async -> Bool {
        if let startingServer { return await startingServer.value }
        let task = Task<Bool, Never> {
            if await fetchStatus() != nil { return true }
            if server?.isRunning != true { launchServer() }
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(300))
                if await fetchStatus() != nil { return true }
                if server?.isRunning != true { break }
            }
            errorMessage = "The voice engine didn't start. Details are in \(AppInfo.logsURL.appendingPathComponent("speakd.log").path)."
            return false
        }
        startingServer = task
        let ok = await task.value
        startingServer = nil
        return ok
    }

    private func launchServer() {
        try? FileManager.default.createDirectory(at: AppInfo.logsURL, withIntermediateDirectories: true)
        let logURL = AppInfo.logsURL.appendingPathComponent("speakd.log")
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()

        let process = Process()
        process.executableURL = AppInfo.pythonURL
        process.arguments = ["-I", "-B", AppInfo.serverScriptURL.path]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
            "BVRD_MODEL_DIR": AppInfo.modelURL.path,
            "BVRD_VOICE_DIRS": [AppInfo.userVoicesURL.path, AppInfo.bundledVoicesURL.path].joined(separator: ":"),
            "BVRD_PLAYER": AppInfo.playerURL.path,
            "BVRD_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier),
            "SPEAKD_PORT": String(serverURL.port ?? 59125),
            "SPEAKD_IDLE_MINUTES": String(Int(settings.idleMinutes)),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        do {
            try process.run()
            server = process
        } catch {
            errorMessage = "Couldn't start the voice engine: \(error.localizedDescription)"
        }
    }

    private func fetchStatus() async -> [String: Any]? {
        var request = URLRequest(url: serverURL.appendingPathComponent("status"))
        request.timeoutInterval = 0.5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @discardableResult
    private func post(_ path: String, _ body: [String: Any] = [:], timeout: TimeInterval = 10) async -> (Int, [String: Any]?) {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (0, nil) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func unloadModel() {
        Task { await post("quit") }
    }

    // MARK: Speaking

    static let speedPresets: [(label: String, value: Double)] = [
        ("Slow (0.75×)", 0.75), ("Relaxed (0.9×)", 0.9), ("Normal (1×)", 1.0),
        ("Brisk (1.15×)", 1.15), ("Fast (1.3×)", 1.3), ("Very Fast (1.5×)", 1.5),
    ]

    func setSpeed(_ speed: Double) {
        settings.speed = min(2.0, max(0.5, (speed * 20).rounded() / 20))
        saveSettings()
    }

    func play(_ text: String, voice: Voice) {
        speak(text, voice: voice)
    }

    func readClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "The clipboard is empty. Copy some text first."
            return
        }
        speak(text, voice: defaultVoice)
    }

    private func speak(_ text: String, voice: Voice) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard downloader.isInstalled else {
            errorMessage = "Finish setup first: open \(AppInfo.name) and download the voice model."
            NSSound.beep()
            return
        }
        beginSpeaking(voice.id)
        let payload: [String: Any] = ["text": text, "voice": voice.name, "speed": settings.speed]
        Task {
            guard await ensureServer() else { return endSpeaking() }
            let (code, reply) = await post("speak", payload, timeout: 15)
            if code != 200 {
                errorMessage = reply?["error"] as? String ?? "Speech failed."
                endSpeaking()
            }
        }
    }

    func stop() {
        endSpeaking()
        Task { await post("stop", timeout: 2) }
    }

    private func beginSpeaking(_ voiceID: String) {
        errorMessage = nil
        activeVoiceID = voiceID
        graceUntil = Date().addingTimeInterval(8)
    }

    private func endSpeaking() {
        graceUntil = nil
        activeVoiceID = nil
    }

    private func pollStatus() async {
        let status = await fetchStatus()
        let ready = status?["ready"] as? Bool ?? false
        let speaking = status?["speaking"] as? Bool ?? false

        modelLoaded = ready
        modelLoading = status != nil && !ready
        hasAccessibility = SelectionReader.hasPermission
        isSpeaking = speaking
        if let error = status?["error"] as? String {
            errorMessage = error
        }
        if speaking {
            graceUntil = nil
        } else if modelLoading || startingServer != nil {
            return
        } else if let grace = graceUntil, Date() < grace {
            return
        } else {
            activeVoiceID = nil
        }
    }

    // MARK: Highlighted text

    private static let shortcutKey = "readShortcut"
    private static let readHotKeyID: UInt32 = 1

    private static func loadShortcut() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: shortcutKey),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .defaultRead }
        return shortcut
    }

    func registerHotKey() {
        let ok = HotKeys.register(id: Self.readHotKeyID, readShortcut) { [weak self] in
            self?.toggleReadSelection()
        }
        if !ok {
            errorMessage = "\(readShortcut.displayString) is already used by another app. Pick a different shortcut in Settings."
        }
    }

    /// Don't fire the shortcut while it's being changed.
    func suspendHotKey() {
        HotKeys.unregister(id: Self.readHotKeyID)
    }

    func setReadShortcut(_ shortcut: Shortcut) {
        readShortcut = shortcut
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: Self.shortcutKey)
        errorMessage = nil
        registerHotKey()
    }

    /// Read the selection, or stop if already reading.
    func toggleReadSelection(delay: Duration = .zero) {
        if isSpeaking || activeVoiceID != nil {
            stop()
            return
        }
        guard SelectionReader.hasPermission else {
            SelectionReader.requestPermission()
            errorMessage = "\(AppInfo.name) needs Accessibility access to read highlighted text. Turn it on in System Settings, then try again."
            return
        }
        Task {
            try? await Task.sleep(for: delay)
            guard let text = await SelectionReader.selectedText(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                return
            }
            speak(text, voice: defaultVoice)
        }
    }

    nonisolated static func run(_ executable: URL, _ args: [String]) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}
