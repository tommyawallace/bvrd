import SwiftUI

/// First launch: download the model, allow Accessibility, try the shortcut.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case model, permission, tryIt

        var title: String {
            switch self {
            case .model: return "Voice Model"
            case .permission: return "Permission"
            case .tryIt: return "Try It"
            }
        }
    }

    @EnvironmentObject private var engine: VoiceEngine
    @EnvironmentObject private var downloader: ModelDownloader
    @State private var step = Step.model

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step)
                .padding(.top, 24)

            Spacer(minLength: 16)
            Group {
                switch step {
                case .model: ModelStep()
                case .permission: PermissionStep()
                case .tryIt: TryItStep()
                }
            }
            .frame(maxWidth: 460)
            Spacer(minLength: 16)

            Divider()
            HStack {
                if step != .model {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .model }
                }
                Spacer()
                footerButton
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var footerButton: some View {
        switch step {
        case .model:
            if downloader.isInstalled {
                Button("Continue") { step = .permission }
                    .keyboardShortcut(.defaultAction)
            } else if isDownloading {
                EmptyView()
            } else {
                Button(isFailed ? "Try Again" : "Continue") { downloader.start() }
                    .keyboardShortcut(.defaultAction)
            }
        case .permission:
            Button(engine.hasAccessibility ? "Continue" : "Skip for Now") { step = .tryIt }
                .keyboardShortcut(engine.hasAccessibility ? .defaultAction : nil)
        case .tryIt:
            Button("Start Using \(AppInfo.name)") { engine.finishSetup() }
                .keyboardShortcut(.defaultAction)
                .disabled(!downloader.isInstalled)
        }
    }

    private var isFailed: Bool {
        if case .failed = downloader.state { return true }
        return false
    }

    private var isDownloading: Bool {
        downloader.state == .downloading || downloader.state == .verifying
    }
}

private struct StepIndicator: View {
    let current: SetupView.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupView.Step.allCases, id: \.self) { step in
                if step != .model {
                    Rectangle().fill(.quaternary).frame(width: 28, height: 1)
                }
                HStack(spacing: 6) {
                    Image(systemName: step.rawValue < current.rawValue ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle.fill")
                        .foregroundStyle(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.5))
                    Text(step.title)
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
                .font(.callout)
            }
        }
    }
}

/// Download the model. It keeps going during the next steps.
private struct ModelStep: View {
    @EnvironmentObject private var downloader: ModelDownloader

    private var totalText: String { ByteCountFormatter.string(fromByteCount: downloader.totalBytes, countStyle: .file) }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Welcome to \(AppInfo.name)").font(.largeTitle.bold())

            Text("\(AppInfo.name) reads highlighted text aloud. It needs a one-time \(totalText) voice model before it can speak.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DownloadStatus()
                .frame(maxWidth: 420)

            Text("Voice model: Chatterbox Turbo by Resemble AI (MIT License), downloaded from Hugging Face.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Accessibility, so the shortcut can read selected text.
private struct PermissionStep: View {
    @EnvironmentObject private var engine: VoiceEngine
    @State private var asked = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: engine.hasAccessibility ? "checkmark.shield.fill" : "hand.raised.fill")
                .font(.system(size: 56))
                .foregroundStyle(engine.hasAccessibility ? Color.green : Color.accentColor)

            Text("Read Text in Any App").font(.largeTitle.bold())

            Text("To read text you've highlighted in other apps, macOS needs you to allow \(AppInfo.name) in Accessibility settings. \(AppInfo.name) only looks at the selected text, and only when you press its shortcut.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if engine.hasAccessibility {
                Label("Allowed. You're all set.", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    instruction(1, "Click Open System Settings below.")
                    instruction(2, "Turn on the switch next to \(AppInfo.name). macOS may ask for your password.")
                    instruction(3, "Come back here. This page updates by itself.")
                }
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                Button {
                    if asked {
                        SelectionReader.openAccessibilitySettings()
                    } else {
                        SelectionReader.requestPermission()
                        asked = true
                    }
                } label: {
                    Text("Open System Settings").padding(.horizontal, 8)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Text("If \(AppInfo.name) is already switched on but this page doesn't change, turn it off and on again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").bold().monospacedDigit()
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Show the shortcut and play a sample.
private struct TryItStep: View {
    @EnvironmentObject private var engine: VoiceEngine
    @EnvironmentObject private var downloader: ModelDownloader

    private let sample = "Hi! Highlight text in any app and press the shortcut, and I'll read it to you."

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("You're Ready").font(.largeTitle.bold())

            VStack(spacing: 6) {
                Text("Highlight text in any app, then press")
                    .foregroundStyle(.secondary)
                Text(engine.readShortcut.displayString)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                Text("Press it again to stop. You can change the shortcut in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if downloader.isInstalled {
                Button {
                    if engine.isSpeaking {
                        engine.stop()
                    } else {
                        engine.play(sample, voice: engine.defaultVoice)
                    }
                } label: {
                    Label(engine.isSpeaking ? "Stop" : "Hear a Sample", systemImage: engine.isSpeaking ? "stop.fill" : "play.fill")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)

                if engine.activeVoiceID != nil && !engine.modelLoaded {
                    Text("Loading the voice engine… the first time takes a few seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Finishing the voice model download…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    DownloadStatus()
                }
                .frame(maxWidth: 420)
            }

            if !engine.hasAccessibility {
                Label("The shortcut needs Accessibility permission. You can allow it later in Settings.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("\(AppInfo.name) lives in the menu bar too, so you can close this window anytime.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }
}

/// Download button, progress, and errors.
private struct DownloadStatus: View {
    @EnvironmentObject private var downloader: ModelDownloader

    private var totalText: String { ByteCountFormatter.string(fromByteCount: downloader.totalBytes, countStyle: .file) }

    var body: some View {
        switch downloader.state {
        case .notInstalled:
            EmptyView()

        case .downloading:
            VStack(spacing: 8) {
                ProgressView(value: Double(downloader.receivedBytes), total: Double(max(downloader.totalBytes, 1)))
                HStack {
                    Text(progressText).monospacedDigit()
                    Spacer()
                    Button("Cancel") { downloader.cancel() }
                        .controlSize(.small)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

        case .verifying:
            VStack(spacing: 8) {
                ProgressView(value: Double(downloader.receivedBytes), total: Double(max(downloader.totalBytes, 1)))
                Text("Checking the download…").font(.callout).foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Downloads pick up where they left off.").font(.caption).foregroundStyle(.secondary)
            }

        case .installed:
            Label("Voice model installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var progressText: String {
        let done = ByteCountFormatter.string(fromByteCount: downloader.receivedBytes, countStyle: .file)
        var text = "\(done) of \(totalText)"
        if downloader.bytesPerSecond > 0 {
            let speed = ByteCountFormatter.string(fromByteCount: Int64(downloader.bytesPerSecond), countStyle: .file)
            let remaining = Double(downloader.totalBytes - downloader.receivedBytes) / downloader.bytesPerSecond
            text += " · \(speed)/s · \(Self.timeLeft(remaining))"
        }
        return text
    }

    private static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes == 1 ? "about 1 minute left" : "about \(minutes) minutes left"
    }
}
