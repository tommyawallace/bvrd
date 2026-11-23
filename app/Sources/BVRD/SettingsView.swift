import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var engine: VoiceEngine

    private let idleChoices: [Double] = [5, 15, 30, 60, 120]

    var body: some View {
        Form {
            Section("Default Voice") {
                LabeledContent("Voice", value: engine.defaultVoice.displayName)
                Text("Pick a voice in the Voice Manager or from the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Reading Speed") {
                SpeedControl()
                Text("Applies to every voice, the hotkey, and the menu bar. Voices keep their natural pitch when sped up or slowed down.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Voice Engine") {
                Picker("Keep loaded after last use", selection: Binding(
                    get: { engine.settings.idleMinutes },
                    set: { engine.setIdleMinutes($0) }
                )) {
                    ForEach(idleChoices, id: \.self) { Text("\(Int($0)) minutes").tag($0) }
                }
                Text("While loaded it uses a few GB of memory and starts reading quickly. After this long without use it unloads itself; the next read takes a few seconds longer to start. Changes apply the next time it loads.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Read Highlighted Text") {
                LabeledContent("Shortcut") { ShortcutRecorder() }
                if let message = engine.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Text("Highlight text in any app and press the shortcut to hear it in your default voice. Press it again to stop.")
                    .font(.caption).foregroundStyle(.secondary)
                if engine.hasAccessibility {
                    Label("Accessibility access is on", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    LabeledContent {
                        Button("Grant Access…") {
                            SelectionReader.requestPermission()
                            SelectionReader.openAccessibilitySettings()
                        }
                    } label: {
                        Label("Needs Accessibility access", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("macOS only lets apps read text you've highlighted in other apps with this permission. Turn on \(AppInfo.name) in Privacy & Security → Accessibility.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch \(AppInfo.name) at login", isOn: Binding(
                    get: { engine.launchAtLogin },
                    set: { engine.setLaunchAtLogin($0) }
                ))
                Text("The shortcut only works while \(AppInfo.name) is running.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Data folder") {
                    HStack {
                        Text(AppInfo.supportURL.path).lineLimit(1).truncationMode(.middle)
                        Button("Show") { NSWorkspace.shared.open(AppInfo.supportURL) }
                    }
                }
                Text("Your voices, settings, the downloaded voice model, and logs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct ShortcutRecorder: View {
    @EnvironmentObject private var engine: VoiceEngine
    @State private var recording = false
    @State private var monitor: Any?
    @State private var heldModifiers = ""
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Button {
                    if !recording { start() }
                } label: {
                    Text(recording ? (heldModifiers.isEmpty ? "Press a shortcut…" : heldModifiers + "…")
                                   : engine.readShortcut.displayString)
                        .frame(minWidth: 130)
                }
                if recording {
                    Button("Cancel", action: finish)
                } else if engine.readShortcut != .defaultRead {
                    Button("Reset to \(Shortcut.defaultRead.displayString)") { engine.setReadShortcut(.defaultRead) }
                }
            }
            if let hint {
                Text(hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { if recording { finish() } }
    }

    private func start() {
        recording = true
        heldModifiers = ""
        hint = "Hold ⌃, ⌥, or ⌘ (plus ⇧ if you like) and press a key. Esc on its own cancels. If nothing happens, another app or macOS already uses that combination; try a different one."
        engine.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                heldModifiers = Shortcut.symbols(for: event.modifierFlags)
                return event
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if Int(event.keyCode) == kVK_Escape && modifiers.isEmpty {
                finish()
            } else if let shortcut = Shortcut(event: event) {
                engine.setReadShortcut(shortcut)
                finish()
            } else {
                NSSound.beep()
                hint = "A shortcut needs at least one of ⌃, ⌥, or ⌘, so it doesn't get in the way of normal typing."
            }
            return nil
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        heldModifiers = ""
        hint = nil
        engine.registerHotKey()
    }
}
