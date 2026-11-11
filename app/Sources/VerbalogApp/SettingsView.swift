import AppKit
import SwiftUI
import VerbalogCaptureKit
import VerbalogCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            LLMSettings().tabItem { Label("LLM", systemImage: "sparkles") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
            VoiceprintSettings().tabItem { Label("Voiceprints", systemImage: "person.wave.2") }
        }
        .frame(width: 620, height: 520)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var userName = ""

    var body: some View {
        Form {
            LanguagePicker()
            TextField("Your Name", text: $userName, prompt: Text("Camille"))
                .onSubmit { model.setConfig("general", "user_name", userName) }
                .onChange(of: userName) { model.setConfig("general", "user_name", userName) }
            LabeledContent("Transcripts Folder") {
                HStack {
                    Text(model.configValue("general", "output_dir", default: "~/Verbalog"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }
            if model.doctor?.outputDirCloudSynced == true {
                Label("This folder syncs to the cloud: transcripts would leave this Mac.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
            Picker("Default meeting type", selection: binding("session", "default_mode", "visio")) {
                ForEach(MeetingMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            LanguagesPicker(title: "Default meeting languages", languages: Binding(
                get: { MeetingLanguage.normalized(model.configValue("transcription", "languages", default: ["fr", "en"])) },
                set: { model.setConfig("transcription", "languages", $0) }
            ))
            Toggle("Reuse audio sources from the last meeting", isOn: binding("session", "remember_last", true))
            Toggle("Live transcript during meetings", isOn: binding("transcription", "live_enabled", true))
            Picker("Note timestamps", selection: binding("notes", "anchor", "first_keystroke")) {
                Text("At first keystroke").tag("first_keystroke")
                Text("When saved").tag("enter")
            }
            Toggle("Keep audio after transcription (not recommended)", isOn: binding("general", "keep_audio", false))
            TextField("Whisper model", text: binding("transcription", "model", ""))
            TextField("Diarization model", text: binding("diarization", "model", ""))
        }
        .formStyle(.grouped)
        .task {
            await model.refreshConfig()
            userName = model.configValue("general", "user_name", default: "")
        }
    }

    private func binding<T>(_ section: String, _ key: String, _ fallback: T) -> Binding<T> {
        Binding(
            get: { model.configValue(section, key, default: fallback) },
            set: { model.setConfig(section, key, $0) }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setConfig("general", "output_dir", url.path)
    }
}

private struct LanguagePicker: View {
    @EnvironmentObject private var model: AppModel
    @State private var chosen = AppModel.interfaceLanguage

    var body: some View {
        Picker("Language", selection: $chosen) {
            // Each in its own language, so it can be found whichever one is showing.
            Text(verbatim: "English").tag("en")
            Text(verbatim: "Français").tag("fr")
        }
        .onChange(of: chosen) { model.setInterfaceLanguage(chosen) }
        if chosen != AppModel.interfaceLanguage {
            HStack {
                Text("Restart Verbalog to apply the new language.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restart Now") { model.relaunch() }
                    .disabled(model.recorder.isActive || !model.jobs.isEmpty)
            }
        }
    }
}

private struct LLMSettings: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("customLLMName") private var customName = ""
    @AppStorage("customLLMURL") private var customURL = ""
    @State private var apiKey = ""
    @State private var prompt = ""

    private var promptURL: URL { model.store.home.appendingPathComponent("prompts/synthese.md") }

    var body: some View {
        Form {
            Section("Your LLM") {
                TextField("Name", text: $customName, prompt: Text("My LLM"))
                TextField("Address", text: $customURL, prompt: Text("https://…"))
                Text("Added to the “Copy and open” buttons in the send window, next to Claude, ChatGPT, Gemini and Mistral.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Summary Prompt") {
                TextEditor(text: $prompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 130)
                HStack {
                    Picker("Output language", selection: Binding(
                        get: { model.configValue("claude", "output_language", default: "fr") },
                        set: { model.setConfig("claude", "output_language", $0) }
                    )) {
                        ForEach(MeetingLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Reset") {
                        try? FileManager.default.removeItem(at: promptURL)
                        prompt = model.defaultPrompt
                    }
                    Button("Save") { savePrompt() }
                }
            }
            Section("Claude API (optional)") {
                SecureField("API key", text: $apiKey, prompt: Text(model.hasSecret(.anthropicKey) ? "Saved in Keychain" : "sk-ant-…"))
                HStack {
                    Button("Save Key") {
                        model.setSecret(.anthropicKey, value: apiKey)
                        apiKey = ""
                    }
                    .disabled(apiKey.isEmpty)
                    if model.hasSecret(.anthropicKey) {
                        Button("Delete Key", role: .destructive) { model.setSecret(.anthropicKey, value: "") }
                    }
                }
                TextField("Model", text: Binding(
                    get: { model.configValue("claude", "model", default: "claude-opus-5-5") },
                    set: { model.setConfig("claude", "model", $0) }
                ))
                Text("Before sending anything, check the retention policy and applicable DPA with your account administrator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refreshConfig()
            prompt = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? model.defaultPrompt
        }
    }

    private func savePrompt() {
        do {
            try FileManager.default.createDirectory(at: promptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct PrivacySettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var sensitive = ""
    @State private var glossary = ""

    private var sensitiveURL: URL { expand(model.configValue("privacy", "sensitive_file", default: "~/.verbalog/sensitive.txt")) }
    private var glossaryURL: URL { expand(model.configValue("transcription", "glossary_file", default: "~/.verbalog/glossary.txt")) }

    private func expand(_ path: String) -> URL {
        model.store.resolve(path)
    }

    var body: some View {
        Form {
            Toggle("Pseudonymize by default before sending", isOn: Binding(
                get: { model.configValue("privacy", "pseudonymize", default: true) },
                set: { model.setConfig("privacy", "pseudonymize", $0) }
            ))
            Section {
                TextEditor(text: $sensitive)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 120)
                    .onChange(of: sensitive) { save(sensitive, to: sensitiveURL) }
            } header: {
                Text("Sensitive Terms")
            } footer: {
                Text("One term per line, optionally with a category: “CLIENT: Acme”, “PROJET: Phoenix”. Participants, emails, phone numbers and amounts are handled automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $glossary)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 90)
                    .onChange(of: glossary) { save(glossary, to: glossaryURL) }
            } header: {
                Text("Business Glossary")
            } footer: {
                Text("Client names, acronyms, technical terms: helps Whisper recognize them and steadies switches between French and English.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refreshConfig()
            sensitive = (try? String(contentsOf: sensitiveURL, encoding: .utf8)) ?? ""
            glossary = (try? String(contentsOf: glossaryURL, encoding: .utf8)) ?? ""
        }
    }

    private func save(_ text: String, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct VoiceprintSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var prints: [[String: Any]] = []
    @State private var enrolling = false

    var body: some View {
        Form {
            Section {
                if prints.isEmpty {
                    Text("No voiceprints saved.").foregroundStyle(.secondary)
                }
                ForEach(prints.indices, id: \.self) { index in
                    let name = prints[index]["name"] as? String ?? ""
                    HStack {
                        Text(name)
                        if prints[index]["self"] as? Bool == true {
                            Text("vous").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { remove(name) }
                    }
                }
                Button("Record a Voiceprint…", systemImage: "mic.badge.plus") { enrolling = true }
                    .disabled(model.doctor?.canDiarize != true || model.recorder.isActive)
            } header: {
                Text("Voiceprints")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    if model.doctor?.canDiarize != true {
                        Text("Requires the diarization model (see Status & Models).")
                    }
                    Text("Biometric data (GDPR, art. 9): encrypted on this Mac, deletable at any time. A colleague's explicit consent is mandatory. Without voiceprints, live naming and the review screen are enough.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .sheet(isPresented: $enrolling, onDismiss: { Task { await refresh() } }) {
            EnrollSheet().environmentObject(model)
        }
    }

    private func refresh() async {
        guard !FileManager.default.fileEnumerator(isEmptyAt: voiceprintsURL) else {
            prints = []
            return
        }
        model.ensureVoiceprintKey()
        let result = try? await model.backend.run(["enroll", "--list"])
        prints = result?["voiceprints"] as? [[String: Any]] ?? []
    }

    private var voiceprintsURL: URL {
        model.store.resolve(model.configValue("speakers", "voiceprints_dir", default: "~/.verbalog/voiceprints"))
    }

    private func remove(_ name: String) {
        let client = model.backend
        Task {
            do {
                _ = try await client.run(["enroll", "--delete", name])
            } catch {
                model.errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }
}

extension FileManager {
    fileprivate func fileEnumerator(isEmptyAt url: URL) -> Bool {
        ((try? contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
    }
}

private struct EnrollSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSelf = true
    @State private var consent = false
    @State private var remaining: Int?
    @State private var levels = AudioLevels()
    @State private var saving = false

    private static let duration = 30
    private static let script = """
    Bonjour, je lis ce texte pour que Verbalog reconnaisse ma voix pendant les réunions. Je parle à mon rythme habituel, sans forcer ni ralentir, comme je le ferais autour d'une table avec des collègues.

    Hello, I am reading this text so that the application can recognize my voice in meetings. I speak at my usual pace, the way I would when talking with colleagues around a table.
    """

    private var canStart: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (isSelf || consent) && remaining == nil && !saving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record a Voiceprint").font(.title2.weight(.semibold))
            TextField("Name", text: $name)
            Toggle("This is my own voice", isOn: $isSelf)
            if !isSelf {
                Toggle("This person has given explicit consent", isOn: $consent)
            }
            Text("Read aloud for \(Self.duration) seconds:").font(.callout).foregroundStyle(.secondary)
            Text(Self.script)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                LevelMeter(title: L("Mic"), level: levels.mic)
                if let remaining {
                    Text("\(remaining) s").monospacedDigit().font(.title3)
                }
                if saving {
                    ProgressView().controlSize(.small)
                    Text("Computing voiceprint…").font(.callout)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(remaining != nil || saving)
                Button("Start") { record() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func record() {
        let enrollName = name.trimmingCharacters(in: .whitespaces)
        let directory = model.store.home.appendingPathComponent("enroll-tmp")
        let session = CaptureSession(configuration: .init(directory: directory, captureSystem: false))
        session.onLevels = { value in
            Task { @MainActor in levels = value }
        }
        Task {
            // The recording is deleted as soon as the embedding exists, whatever happens.
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try await session.start()
                for second in stride(from: Self.duration, to: 0, by: -1) {
                    remaining = second
                    try await Task.sleep(for: .seconds(1))
                }
                remaining = nil
                await session.stop()
                saving = true
                model.ensureVoiceprintKey()
                var arguments = ["enroll", "--name", enrollName, "--wav", directory.appendingPathComponent("mic.wav").path]
                arguments.append(isSelf ? "--self" : "--consent")
                _ = try await model.backend.run(arguments)
                saving = false
                dismiss()
            } catch {
                await session.stop()
                remaining = nil
                saving = false
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
