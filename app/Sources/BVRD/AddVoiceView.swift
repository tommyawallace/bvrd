import SwiftUI
import UniformTypeIdentifiers

struct AddVoiceView: View {
    @EnvironmentObject private var engine: VoiceEngine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var file: URL?
    @State private var consent = false
    @State private var working = false
    @State private var error: String?

    init(initialFile: URL?) {
        _file = State(initialValue: initialFile)
        _name = State(initialValue: initialFile?.deletingPathExtension().lastPathComponent ?? "")
    }

    private var canAdd: Bool {
        !working && consent && file != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Voice").font(.title2.bold())
            Text("Choose an audio file of one person speaking clearly for 10 to 20 seconds, with no music or background noise.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    Text(file?.lastPathComponent ?? "Drop an audio file here")
                        .foregroundStyle(file == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose Audio File…", action: chooseFile)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    setFile(url)
                    return true
                }
                Text("Any common audio format works (WAV, MP3, M4A, AIFF…).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            TextField("Voice name", text: $name)
                .textFieldStyle(.roundedBorder)

            Toggle(isOn: $consent) {
                Text("I own this recording or have the speaker's permission to clone their voice.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    add()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Add Voice") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { setFile(url) }
    }

    private func setFile(_ url: URL) {
        file = url
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        error = nil
    }

    private func add() {
        guard let file, consent else { return }
        working = true
        error = nil
        Task {
            do {
                try await engine.addVoice(from: file, named: name, description: "Cloned from \(file.lastPathComponent)", consentedAt: Date())
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
