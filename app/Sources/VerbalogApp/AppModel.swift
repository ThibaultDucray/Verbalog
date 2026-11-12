// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import VerbalogCaptureKit
import VerbalogCore

enum Selection: Hashable {
    case newMeeting
    case importRecording
    case setup
    case session(String)
}

struct JobProgress {
    var label: String
    var fraction: Double
    var task: Task<Void, Never>?
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = SessionStore()
    let recorder = RecordingController()
    let support = SupportModel()

    @Published var sessions: [SessionMeta] = []
    @Published var selection: Selection?
    @Published var jobs: [String: JobProgress] = [:]
    @Published var doctor: DoctorReport?
    @Published var config: [String: Any] = [:]
    @Published var defaultPrompt = ""
    @Published var errorMessage: String?
    @Published var setupRunning = false
    @Published var setupLog = ""
    @Published var setupFailures: [String: String] = [:]

    private var cachedSecrets: [Keychain.Item: String] = [:]
    private var secretsLoaded = false
    private var unsavedConfig: [String: [String: Any]] = [:]
    private var configSaver: Task<Void, Never>?

    private init() {
        recorder.model = self
    }

    // MARK: Lifecycle

    func launch() {
        store.recoverInterrupted(activeIDs: [])
        reloadSessions()
        // Not the new-meeting form: its level test would switch the mic on just by opening the app.
        selection = sessions.first.map { .session($0.id) }
        if backend.isInstalled {
            Task {
                await refreshConfig()
                syncBackendLanguage()
                await refreshDoctor()
            }
        } else {
            selection = .setup
        }
    }

    func prepareForQuit() async {
        if recorder.isActive { await recorder.stop(processAfterwards: false) }
        for (id, job) in jobs {
            job.task?.cancel()
            try? store.update(id: id, ["status": SessionStatus.recorded.rawValue])
        }
    }

    func reloadSessions() {
        sessions = store.list()
    }

    func meta(_ id: String) -> SessionMeta? {
        sessions.first { $0.id == id }
    }

    // MARK: Backend

    nonisolated static func repoRoot() -> URL {
        if let path = ProcessInfo.processInfo.environment["VERBALOG_ROOT"] {
            return URL(fileURLWithPath: path)
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "VerbalogRepoRoot") as? String {
            return URL(fileURLWithPath: path)
        }
        // `swift run`: walk up from the executable to the repository.
        var url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("pyproject.toml").path) {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// A release carries the backend and uv; a development build runs the repository's.
    nonisolated static let backendLayout: BackendLayout = {
        let bundle = Bundle.main.bundleURL
        let backend = bundle.appendingPathComponent("Contents/Resources/backend")
        let uv = bundle.appendingPathComponent("Contents/Helpers/uv")
        guard
            ProcessInfo.processInfo.environment["VERBALOG_ROOT"] == nil,
            FileManager.default.fileExists(atPath: backend.appendingPathComponent("uv.lock").path),
            FileManager.default.isExecutableFile(atPath: uv.path)
        else { return .development(root: repoRoot()) }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return .bundled(
            backend: backend,
            uv: uv,
            support: library.appendingPathComponent("Application Support/Verbalog"),
            caches: library.appendingPathComponent("Caches/Verbalog")
        )
    }()

    var backend: BackendClient {
        loadSecretsIfNeeded()
        var environment: [String: String] = [:]
        for (item, value) in cachedSecrets { environment[item.environmentName] = value }
        return BackendClient(layout: Self.backendLayout, environment: environment)
    }

    private func loadSecretsIfNeeded() {
        guard !secretsLoaded else { return }
        secretsLoaded = true
        for item in Keychain.Item.allCases where Keychain.has(item) {
            cachedSecrets[item] = Keychain.get(item)
        }
    }

    func setSecret(_ item: Keychain.Item, value: String) {
        do {
            try Keychain.set(item, value: value)
            cachedSecrets[item] = value.isEmpty ? nil : value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func hasSecret(_ item: Keychain.Item) -> Bool {
        loadSecretsIfNeeded()
        return cachedSecrets[item] != nil
    }

    func ensureVoiceprintKey() {
        guard !hasSecret(.voiceprintKey) else { return }
        do {
            cachedSecrets[.voiceprintKey] = try Keychain.ensureVoiceprintKey()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Language

    /// What this launch is actually showing, as resolved by macOS from the bundle's localizations.
    nonisolated static var interfaceLanguage: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true ? "fr" : "en"
    }

    /// macOS reads AppleLanguages once per launch, hence the restart. The backend follows through the config.
    func setInterfaceLanguage(_ language: String) {
        UserDefaults.standard.set([language], forKey: "AppleLanguages")
        setConfig("general", "language", language)
    }

    /// Backend messages and exports must match the interface, even if macOS picked the language.
    private func syncBackendLanguage() {
        if configValue("general", "language", default: "") != Self.interfaceLanguage {
            setConfig("general", "language", Self.interfaceLanguage)
        }
    }

    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    func refreshDoctor() async {
        guard backend.isInstalled else { return }
        if let fields = try? await backend.run(["doctor"]) {
            doctor = DoctorReport(fields)
        }
    }

    // MARK: Config

    func refreshConfig() async {
        guard let result = try? await backend.run(["config"]) else { return }
        config = result["config"] as? [String: Any] ?? [:]
        defaultPrompt = result["default_prompt"] as? String ?? ""
    }

    func configValue<T>(_ section: String, _ key: String, default fallback: T) -> T {
        (config[section] as? [String: Any])?[key] as? T ?? fallback
    }

    func setConfig(_ section: String, _ key: String, _ value: Any) {
        var values = config[section] as? [String: Any] ?? [:]
        values[key] = value
        config[section] = values
        unsavedConfig[section, default: [:]][key] = value
        guard configSaver == nil else { return }
        configSaver = Task {
            await saveConfig()
            configSaver = nil
        }
    }

    /// One save at a time, so the last value typed is the one kept. Changes made during a save
    /// are grouped into the next one: text fields report every keystroke.
    private func saveConfig() async {
        while !unsavedConfig.isEmpty {
            let changes = unsavedConfig
            unsavedConfig = [:]
            guard
                let data = try? JSONSerialization.data(withJSONObject: changes),
                let json = String(data: data, encoding: .utf8)
            else { continue }
            do {
                _ = try await backend.run(["config", "--set", json])
                await refreshDoctor()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Processing

    /// A recording made elsewhere: copied into a new meeting as its only track, then processed
    /// like an in-person meeting, every voice told apart by diarization. The file itself is only read.
    func importRecording(_ file: URL, form: MeetingForm, date: Date) async throws {
        let trimmed = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = try store.create(
            title: trimmed.isEmpty ? file.deletingPathExtension().lastPathComponent : trimmed,
            mode: .presentiel,
            headset: false,
            roomCount: form.roomCount,
            remoteCount: nil,
            participants: [String].participants(from: form.participants),
            languages: form.languages,
            micDevice: nil,
            systemSource: nil,
            now: date
        )
        do {
            let duration = try await AudioImporter.convert(from: file, to: store.audioURL(id: meta.id, track: "mic"))
            try store.update(id: meta.id, [
                "status": SessionStatus.recorded.rawValue,
                "duration": duration,
                "imported": true,
                "started_epoch_ms": Int64(date.timeIntervalSince1970 * 1000),
            ])
        } catch {
            // Only the meeting folder just created: never the file being imported.
            try? FileManager.default.removeItem(at: store.directory(meta.id))
            throw error
        }
        reloadSessions()
        selection = .session(meta.id)
        process(meta.id)
    }

    func process(_ id: String) {
        guard jobs[id] == nil else { return }
        runJob(id, label: L("Preparing…"), arguments: ["process", id], failureStatus: .failed)
    }

    func finalize(_ id: String, names: [String: String], merges: [[String]]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: ["names": names, "merges": merges]),
            let decisions = String(data: data, encoding: .utf8)
        else { return }
        runJob(id, label: L("Export…"), arguments: ["finalize", id, "--decisions", decisions], failureStatus: nil)
    }

    private func runJob(_ id: String, label: String, arguments: [String], failureStatus: SessionStatus?) {
        let client = backend
        jobs[id] = JobProgress(label: label, fraction: 0)
        let task = Task { [weak self] in
            do {
                _ = try await client.run(arguments) { [weak self] event in
                    guard event.name == "progress" else { return }
                    let label = event.fields["label"] as? String ?? ""
                    let fraction = event.fields["fraction"] as? Double ?? 0
                    Task { @MainActor [weak self] in
                        self?.jobs[id]?.label = label
                        self?.jobs[id]?.fraction = fraction
                    }
                }
                // Processing ends in review when speakers need naming; done means exported.
                if self?.store.load(id: id)?.status == .done {
                    self?.support.meetingCompleted(id)
                }
            } catch is CancellationError {
                try? self?.store.update(id: id, ["status": SessionStatus.recorded.rawValue])
            } catch {
                self?.handleJobFailure(id, error, failureStatus)
            }
            self?.jobs[id] = nil
            self?.reloadSessions()
        }
        jobs[id]?.task = task
    }

    private func handleJobFailure(_ id: String, _ error: Error, _ status: SessionStatus?) {
        if let status {
            // Usually already recorded by the backend; not if the process itself crashed.
            try? store.update(id: id, ["status": status.rawValue, "error": error.localizedDescription])
        } else {
            errorMessage = error.localizedDescription
        }
    }

    func cancelJob(_ id: String) {
        jobs[id]?.task?.cancel()
    }

    // MARK: Session actions

    func runSimple(_ arguments: [String]) {
        let client = backend
        Task {
            do {
                _ = try await client.run(arguments)
            } catch {
                errorMessage = error.localizedDescription
            }
            reloadSessions()
        }
    }

    func delete(_ id: String) {
        let alert = NSAlert()
        alert.messageText = L("Permanently delete this meeting?")
        alert.informativeText = L("The transcript, notes, summary and any audio will be erased. This can't be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selection = nil
        runSimple(["delete", id])
    }

    func purgeAudio(_ id: String) {
        let alert = NSAlert()
        alert.messageText = L("Delete this meeting's audio?")
        alert.informativeText = L("Automatic validation had kept the audio. Without it, this meeting can't be transcribed again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Delete Audio"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runSimple(["purge-audio", id])
    }

    // MARK: Setup

    func installBackend() {
        setupRunning = true
        setupLog = ""
        let client = BackendClient(layout: Self.backendLayout)
        Task {
            do {
                try await client.install { line in
                    Task { @MainActor in self.appendSetupLog(line) }
                }
                await refreshConfig()
                await refreshDoctor()
            } catch {
                errorMessage = error.localizedDescription
            }
            setupRunning = false
        }
    }

    func downloadModels() {
        setupRunning = true
        setupFailures = [:]
        setupLog = ""
        let client = backend
        Task {
            do {
                let result = try await client.run(["setup"]) { event in
                    guard event.name == "progress", let label = event.fields["label"] as? String else { return }
                    Task { @MainActor in self.appendSetupLog(label + "\n") }
                }
                setupFailures = result["failures"] as? [String: String] ?? [:]
                doctor = DoctorReport(result)
            } catch {
                errorMessage = error.localizedDescription
            }
            setupRunning = false
        }
    }

    private func appendSetupLog(_ text: String) {
        setupLog += text
        if setupLog.count > 20_000 { setupLog = String(setupLog.suffix(15_000)) }
    }

    // MARK: Files

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func saveFile(suggestedName: String, write: (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
