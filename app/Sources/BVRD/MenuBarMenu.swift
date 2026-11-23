import AppKit
import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject private var engine: VoiceEngine
    @EnvironmentObject private var downloader: ModelDownloader
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !downloader.isInstalled || !engine.settings.finishedSetup {
            Button("Finish Setup…") { openMainWindow() }
            Divider()
        }

        Button("Read Selected Text    \(engine.readShortcut.displayString)") {
            engine.toggleReadSelection(delay: .milliseconds(150))
        }
        Button("Read Clipboard") { engine.readClipboard() }
        Button("Stop Reading") { engine.stop() }
            .disabled(!engine.isSpeaking)

        Divider()

        Text("Default voice: \(engine.defaultVoice.displayName)")
        Menu("Voices") {
            voiceSection(nil, engine.voices.filter { $0.kind == .builtin })
            voiceSection("Starter Voices", engine.voices.filter { $0.kind == .starter })
            voiceSection("Your Voices", engine.voices.filter { $0.kind == .user })
        }

        Menu("Speed: \(String(format: "%.2g×", engine.settings.speed))") {
            ForEach(VoiceEngine.speedPresets, id: \.value) { preset in
                Button {
                    engine.setSpeed(preset.value)
                } label: {
                    if abs(engine.settings.speed - preset.value) < 0.01 {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
        }

        Divider()

        Button("Open Voice Manager…") { openMainWindow() }
        SettingsLink { Text("Settings…") }
        if engine.modelLoaded {
            Button("Unload Voice Engine (frees memory)") { engine.unloadModel() }
        }

        Divider()

        Button("About \(AppInfo.name)") { About.show() }
        Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    @ViewBuilder
    private func voiceSection(_ title: String?, _ voices: [Voice]) -> some View {
        if !voices.isEmpty {
            if let title {
                Section(title) { ForEach(voices) { voiceButton($0) } }
            } else {
                ForEach(voices) { voiceButton($0) }
            }
        }
    }

    private func voiceButton(_ voice: Voice) -> some View {
        Button {
            engine.setDefault(voice)
        } label: {
            if engine.isDefault(voice) {
                Label(voice.displayName, systemImage: "checkmark")
            } else {
                Text(voice.displayName)
            }
        }
    }
}
