import AppKit
import SwiftUI

@main
struct BVRDApp: App {
    @StateObject private var engine = VoiceEngine()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            MainView()
                .environmentObject(engine)
                .environmentObject(engine.downloader)
                .frame(minWidth: 580, minHeight: 540)
        }
        .defaultSize(width: 660, height: 720)
        .commands { AppCommands() }

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .defaultSize(width: 640, height: 640)

        Settings {
            SettingsView()
                .environmentObject(engine)
        }

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(engine)
                .environmentObject(engine.downloader)
        } label: {
            Image(systemName: engine.isSpeaking ? "waveform.circle.fill" : "waveform")
        }
    }
}

/// Voice list, or first-launch setup until that's done.
struct MainView: View {
    @EnvironmentObject private var engine: VoiceEngine
    @EnvironmentObject private var downloader: ModelDownloader

    var body: some View {
        if downloader.isInstalled && engine.settings.finishedSetup {
            VoiceManagerView()
        } else {
            SetupView()
        }
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Acknowledgements") { openWindow(id: "acknowledgements") }
        }
    }
}

enum About {
    /// About window. Copyright comes from the built app, extra text from Credits.html.
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
