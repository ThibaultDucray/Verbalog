// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import VerbalogCaptureKit
import VerbalogCore

struct LocalNote: Identifiable, Hashable {
    let id = UUID()
    let t: Double
    let text: String
    let kind: NoteKind

    /// What to show: the text without its type prefix.
    var body: String {
        switch kind {
        case .action, .decision, .question, .private:
            String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        default:
            text
        }
    }
}

struct MeetingForm: Equatable, Codable {
    var title = ""
    var mode: MeetingMode = .visio
    var headset = true
    var roomCount: Int?
    var remoteCount: Int?
    var participants = ""
    var languages = ["fr", "en"]
    var micDevice: String?
    var systemSource: String?

    // Remembered between meetings: only the audio setup is reused, and languages come from Settings.
    private enum CodingKeys: String, CodingKey {
        case title, mode, headset, roomCount, remoteCount, participants, micDevice, systemSource
    }
}

extension MeetingForm {
    /// What can still change once the meeting has started.
    init(details meta: SessionMeta) {
        self.init(
            title: meta.title,
            mode: meta.mode,
            headset: meta.headset ?? true,
            roomCount: meta.room_count,
            remoteCount: meta.remote_count,
            participants: (meta.participants ?? []).joined(separator: ", "),
            languages: MeetingLanguage.normalized(meta.languages ?? [])
        )
    }
}

/// The meeting in progress: capture, the clock, notes and the rolling transcript.
@MainActor
final class RecordingController: ObservableObject {
    enum Phase { case idle, recording, paused, stopping }

    weak var model: AppModel?

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sessionID: String?
    /// The meeting details sheet, also opened from the menu and with /details.
    @Published var editingDetails = false
    @Published private(set) var levels = AudioLevels()
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var notes: [LocalNote] = []
    @Published private(set) var live: [LiveSegment] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var liveStatus: String?
    @Published private(set) var isMicMuted = false
    /// The mic stopped recording anything, often because the call app took the headset.
    @Published private(set) var isMicLost = false
    private var attentionRequest: Int?
    @Published private(set) var capturesSystem = false
    @Published var title = ""

    /// The note being typed. Its timestamp is taken at the first keystroke, closer to
    /// the moment being commented on than the end of typing.
    @Published var draft = "" {
        didSet {
            if draft.isEmpty {
                draftAnchor = nil
            } else if draftAnchor == nil {
                draftAnchor = capture?.elapsed ?? 0
            }
        }
    }

    private var draftAnchor: Double?
    private var capture: CaptureSession?
    private var notesFile: NotesFile?
    private var clock: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var startedEpochMs: Int64 = 0

    var isActive: Bool { phase != .idle }
    var isPaused: Bool { phase == .paused }

    func start(form: MeetingForm) async throws {
        guard let model else { return }
        let participants = [String].participants(from: form.participants)
        let trimmed = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = try model.store.create(
            title: trimmed.isEmpty ? L("Meeting") : trimmed,
            mode: form.mode,
            headset: form.headset,
            roomCount: form.mode == .visio ? nil : form.roomCount,
            remoteCount: form.mode == .presentiel ? nil : form.remoteCount,
            participants: participants,
            languages: form.languages,
            micDevice: form.micDevice,
            systemSource: form.systemSource
        )
        let directory = model.store.directory(meta.id)
        let session = CaptureSession(configuration: .init(
            directory: directory,
            micDevice: form.micDevice,
            captureSystem: form.mode.capturesSystem,
            systemSource: form.systemSource
        ))
        session.onLevels = { [weak self] levels in
            Task { @MainActor in self?.levels = levels }
        }
        session.onWarning = { [weak self] message in
            Task { @MainActor in self?.warnings.append(message) }
        }
        session.onMicLost = { [weak self] lost in
            Task { @MainActor in self?.setMicLost(lost) }
        }

        do {
            let started = try await session.start()
            startedEpochMs = started.epochMs
            if let error = started.systemError {
                warnings = [L("System audio not captured: \(error.localizedDescription) Only the mic is being recorded.")]
            } else {
                warnings = []
            }
            try model.store.update(id: meta.id, ["started_epoch_ms": started.epochMs, "warnings": warnings])
            notesFile = try NotesFile(url: directory.appendingPathComponent("notes.jsonl"))
        } catch {
            await session.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        capture = session
        capturesSystem = form.mode.capturesSystem
        sessionID = meta.id
        title = meta.title
        notes = []
        live = []
        draft = ""
        liveStatus = nil
        elapsed = 0
        setMicMuted(false)
        phase = .recording
        model.reloadSessions()
        model.selection = .session(meta.id)

        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let capture = self.capture else { return }
                self.elapsed = capture.elapsed
            }
        }
        startLiveTranscript(id: meta.id)
    }

    private func startLiveTranscript(id: String) {
        guard let model, model.configValue("transcription", "live_enabled", default: true) else {
            liveStatus = L("Live transcript is turned off in Settings.")
            return
        }
        guard model.backend.isInstalled, model.doctor?.liveCached != false else {
            liveStatus = L("Live transcript model not downloaded: the text will appear after the meeting.")
            return
        }
        let client = model.backend
        liveStatus = L("Loading model…")
        liveTask = Task { [weak self] in
            do {
                _ = try await client.run(["live", id]) { [weak self] event in
                    Task { @MainActor [weak self] in self?.handleLive(event) }
                }
            } catch is CancellationError {
            } catch {
                // Only the preview is lost: the recording and the final transcript don't depend on it.
                self?.liveStatus = L("Live transcript unavailable: \(error.localizedDescription)")
            }
        }
    }

    private func handleLive(_ event: BackendEvent) {
        switch event.name {
        case "ready":
            liveStatus = nil
        case "live":
            guard
                let track = event.fields["track"] as? String,
                let start = event.fields["start"] as? Double,
                let end = event.fields["end"] as? Double,
                let text = event.fields["text"] as? String
            else { return }
            live.append(LiveSegment(track: track, start: start, end: end, text: text, lang: event.fields["lang"] as? String))
        case "warning":
            liveStatus = event.fields["message"] as? String
        default:
            break
        }
    }

    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        let anchor = draftAnchor
        draft = ""
        if text.hasPrefix("/") {
            runCommand(text)
            return
        }
        addNote(text, at: anchor)
    }

    private func addNote(_ text: String, at anchor: Double?) {
        guard let capture, let notesFile, let model else { return }
        let useFirstKeystroke = model.configValue("notes", "anchor", default: "first_keystroke") == "first_keystroke"
        let t = (useFirstKeystroke ? anchor : nil) ?? capture.elapsed
        let epoch = startedEpochMs + Int64(t * 1000)
        do {
            try notesFile.append(t: t, text: text, epochMs: epoch)
        } catch {
            warnings.append(L("Note not saved: \(error.localizedDescription)"))
            draft = text  // don't lose what was typed
            return
        }
        let patterns: [String] = model.configValue("speakers", "naming_patterns", default: [])
        notes.append(LocalNote(t: t, text: text, kind: NoteKind.classify(text, namingPatterns: patterns)))
    }

    private func runCommand(_ text: String) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "/stop":
            Task { await stop() }
        case "/pause":
            togglePause(true)
        case "/resume":
            togglePause(false)
        case "/mute":
            setMicMuted(true)
        case "/unmute":
            setMicMuted(false)
        case "/title" where !argument.isEmpty:
            rename(argument)
        case "/participants" where !argument.isEmpty:
            setParticipants(argument)
        case "/details", "/participants", "/languages", "/type":
            showDetails()
        default:
            warnings.append(L("Unknown command: \(parts[0]). Available: /stop, /pause, /resume, /mute, /unmute, /title, /participants, /details."))
        }
    }

    func togglePause(_ paused: Bool) {
        guard phase == .recording || phase == .paused else { return }
        capture?.setPaused(paused)
        phase = paused ? .paused : .recording
    }

    func setMicMuted(_ muted: Bool) {
        capture?.setMicMuted(muted)
        isMicMuted = muted
        updateBadge()
    }

    private func setMicLost(_ lost: Bool) {
        guard lost != isMicLost else { return }
        isMicLost = lost
        updateBadge()
        if lost {
            warnings.append(L("Your microphone stopped recording: your voice is missing from this point. Verbalog keeps trying to reconnect it."))
            // The call is in front: bounce the Dock icon until someone looks.
            attentionRequest = NSApp.requestUserAttention(.criticalRequest)
        } else {
            warnings.append(L("The microphone is recording again."))
            if let attentionRequest { NSApp.cancelUserAttentionRequest(attentionRequest) }
            attentionRequest = nil
        }
    }

    /// Losing speech without noticing is the worst outcome, so this shows even with the call in front.
    private func updateBadge() {
        NSApp.dockTile.badgeLabel = isMicMuted ? L("Muted") : isMicLost ? L("No mic") : nil
    }

    func rename(_ newTitle: String) {
        guard let id = sessionID else { return }
        title = newTitle
        try? model?.store.update(id: id, ["title": newTitle])
        model?.reloadSessions()
    }

    /// Opens the details sheet on the meeting in progress, whatever the window shows.
    func showDetails() {
        guard let id = sessionID, isActive else { return }
        model?.selection = .session(id)
        NSApp.activate()
        editingDetails = true
    }

    func setParticipants(_ text: String) {
        guard let id = sessionID else { return }
        try? model?.store.update(id: id, ["participants": [String].participants(from: text)])
        model?.reloadSessions()
    }

    /// Meetings change shape: someone joins remotely, the count was wrong. Processing reads these
    /// values once the meeting has ended, so they apply to the whole recording.
    func updateDetails(_ form: MeetingForm) {
        guard let id = sessionID, let model else { return }
        do {
            try model.updateDetails(id, form: form, includingTitle: false)
        } catch {
            warnings.append(L("Meeting details not saved: \(error.localizedDescription)"))
            return
        }

        // An in-person meeting had no system audio: start it now that remote people are expected.
        guard form.mode.capturesSystem, !capturesSystem, let capture else { return }
        capturesSystem = true
        Task {
            if let error = await capture.addSystemAudio() {
                warnings.append(L("System audio not captured: \(error.localizedDescription) Only the mic is being recorded."))
            }
        }
    }

    func stop(processAfterwards: Bool = true) async {
        guard let capture, let id = sessionID, phase != .stopping else { return }
        phase = .stopping
        // A note being typed when the meeting ends is still a note.
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty, !draft.hasPrefix("/") {
            submitDraft()
        }
        clock?.cancel()
        liveTask?.cancel()
        await capture.stop()
        setMicLost(false)
        setMicMuted(false)
        self.capture = nil
        capturesSystem = false
        notesFile = nil
        try? model?.store.update(id: id, ["status": SessionStatus.recorded.rawValue, "duration": elapsed, "warnings": warnings])
        sessionID = nil
        phase = .idle
        model?.reloadSessions()
        // Off in Settings: several meetings in a row, processed later from each one's page.
        if processAfterwards, model?.configValue("session", "auto_process", default: true) ?? true {
            model?.process(id)
        }
    }
}
