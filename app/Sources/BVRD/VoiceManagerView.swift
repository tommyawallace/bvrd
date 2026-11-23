import SwiftUI
import UniformTypeIdentifiers

struct VoiceManagerView: View {
    @EnvironmentObject private var engine: VoiceEngine
    @State private var sampleText = VoiceEngine.defaultSample
    @State private var search = ""
    @State private var showingAddVoice = false
    @State private var droppedFile: URL?

    private var sections: [(title: String, voices: [Voice])] {
        let filtered = search.isEmpty ? engine.voices : engine.voices.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)
        }
        return [
            ("Built-in", filtered.filter { $0.kind == .builtin }),
            ("Starter Voices", filtered.filter { $0.kind == .starter }),
            ("Your Voices", filtered.filter { $0.kind == .user }),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.voices) { voice in
                            VoiceRow(voice: voice, sampleText: sampleText)
                        }
                        if section.title == "Your Voices" {
                            addVoiceHint
                        }
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                droppedFile = url
                showingAddVoice = true
                return true
            }
            Divider()
            StatusBar()
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search voices")
        .toolbar {
            ToolbarItemGroup {
                if engine.isSpeaking {
                    Button {
                        engine.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop reading")
                }
                Button {
                    droppedFile = nil
                    showingAddVoice = true
                } label: {
                    Label("Add Voice", systemImage: "plus")
                }
                .help("Clone a new voice from a recording")
            }
        }
        .sheet(isPresented: $showingAddVoice) {
            AddVoiceView(initialFile: droppedFile)
                .environmentObject(engine)
        }
        .onAppear {
            engine.refreshVoices()
            engine.warmUp()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter text to hear it read aloud. Try adding tags like [laugh], [sigh], [chuckle], or [gasp].")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top) {
                TextField("Type something to preview…", text: $sampleText, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                if sampleText != VoiceEngine.defaultSample {
                    Button("Reset") { sampleText = VoiceEngine.defaultSample }
                        .controlSize(.small)
                }
            }

            SpeedControl()
        }
        .padding()
    }

    private var addVoiceHint: some View {
        Button {
            droppedFile = nil
            showingAddVoice = true
        } label: {
            Label("Add a voice: drop an audio file here", systemImage: "plus.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

struct SpeedControl: View {
    @EnvironmentObject private var engine: VoiceEngine
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise").foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { dragging ?? engine.settings.speed }, set: { dragging = $0 }),
                in: 0.5...2.0,
                onEditingChanged: { editing in
                    if !editing, let value = dragging {
                        engine.setSpeed(value)
                        dragging = nil
                    }
                }
            )
            Image(systemName: "hare").foregroundStyle(.secondary)
            Text(String(format: "%.2f×", dragging ?? engine.settings.speed))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            Button("Reset") { engine.setSpeed(1.0) }
                .controlSize(.small)
                .disabled(abs(engine.settings.speed - 1.0) < 0.01)
        }
        .help("Reading speed for every voice, the hotkey, and the menu bar")
    }
}

struct VoiceRow: View {
    @EnvironmentObject private var engine: VoiceEngine
    let voice: Voice
    let sampleText: String
    @State private var editing = false
    @State private var confirmingDelete = false

    private var isActive: Bool { engine.activeVoiceID == voice.id }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isActive {
                    engine.stop()
                } else {
                    engine.play(sampleText, voice: voice)
                }
            } label: {
                Image(systemName: isActive ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(isActive ? Color.red : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(isActive ? "Stop" : "Preview this voice")

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.displayName).font(.headline)
                Text(voice.detail).font(.caption).foregroundStyle(.secondary)
                if let source = voice.info?.source {
                    Text(source).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }

            if isActive && !engine.modelLoaded {
                ProgressView().controlSize(.small)
                Text("Loading voice engine…").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if engine.isDefault(voice) {
                Label("Default", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Button("Set as Default") { engine.setDefault(voice) }
                    .controlSize(.small)
            }

            if voice.isUserVoice {
                Menu {
                    manageItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Rename, show in Finder, or delete this voice")
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Set as Default") { engine.setDefault(voice) }
            if let link = voice.info?.url, let url = URL(string: link) {
                Button("View Original Recording") { NSWorkspace.shared.open(url) }
            }
            if voice.isUserVoice {
                Divider()
                manageItems
            }
        }
        .sheet(isPresented: $editing) {
            EditVoiceView(voice: voice)
                .environmentObject(engine)
        }
        .confirmationDialog("Delete “\(voice.displayName)”?", isPresented: $confirmingDelete) {
            Button("Delete Voice", role: .destructive) { engine.deleteVoice(voice) }
        } message: {
            Text("The recording moves to the Trash, so you can restore it from there if you change your mind.")
        }
    }

    @ViewBuilder private var manageItems: some View {
        Button("Edit Name & Description…") { editing = true }
        Button("Show in Finder") { engine.revealInFinder(voice) }
        Divider()
        Button("Delete Voice…", role: .destructive) { confirmingDelete = true }
    }
}

struct EditVoiceView: View {
    @EnvironmentObject private var engine: VoiceEngine
    @Environment(\.dismiss) private var dismiss
    let voice: Voice
    @State private var title: String
    @State private var description: String

    init(voice: Voice) {
        self.voice = voice
        _title = State(initialValue: voice.displayName)
        _description = State(initialValue: voice.info?.description ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Voice").font(.title2.bold())
            Form {
                TextField("Name", text: $title)
                TextField("Description", text: $description, prompt: Text("Optional"))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    engine.updateVoice(voice, title: title, description: description)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var engine: VoiceEngine

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(engine.isSpeaking ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            if let error = engine.errorMessage {
                Text(error).foregroundStyle(.red).lineLimit(1)
            } else {
                Text(engine.isSpeaking ? "Reading…" : "Ready")
            }
            if engine.modelLoaded {
                Text("· Voice engine loaded").foregroundStyle(.secondary)
                Button("Unload") { engine.unloadModel() }
                    .controlSize(.small)
                    .help("Free the memory now. It reloads automatically next time.")
            }
            Spacer()
            Text("Default: \(engine.defaultVoice.displayName)")
                .foregroundStyle(.secondary)
            Text("·  \(engine.readShortcut.displayString) reads highlighted text").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
