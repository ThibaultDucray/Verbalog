import SwiftUI
import VerbalogCore

struct RecordingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecordingController
    @FocusState private var inputFocused: Bool
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var editingDetails = false

    private var meta: SessionMeta? {
        recorder.sessionID.flatMap { model.meta($0) }
    }

    private var capturesSystem: Bool {
        meta?.mode.capturesSystem ?? true
    }

    /// Kept in sight, so a wrong type or count from the start form gets noticed.
    private var detailsSummary: String {
        guard let meta else { return "" }
        var parts = [meta.mode.title, MeetingLanguage.normalized(meta.languages ?? []).map { $0.uppercased() }.joined(separator: "+")]
        if meta.mode != .visio, let count = meta.room_count { parts.append(L("\(count) in the room")) }
        if meta.mode != .presentiel, let count = meta.remote_count { parts.append(L("\(count) remote")) }
        let names = meta.participants ?? []
        parts.append(names.isEmpty ? L("no names") : names.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if recorder.isMicMuted {
                mutedBanner
                Divider()
            }
            if !recorder.warnings.isEmpty {
                WarningList(warnings: recorder.warnings).padding(10)
            }
            HSplitView {
                liveColumn.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                notesColumn.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(recorder.title)
        .onAppear { inputFocused = true }
        .alert("Meeting Title", isPresented: $editingTitle) {
            TextField("Title", text: $titleDraft)
            Button("Rename") { recorder.rename(titleDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editingDetails) {
            if let meta {
                MeetingDetailsSheet(form: MeetingForm(details: meta), capturesSystem: recorder.capturesSystem) {
                    recorder.updateDetails($0)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            HStack(spacing: 7) {
                Circle()
                    .fill(recorder.isPaused ? Color.orange : Color.red)
                    .frame(width: 11, height: 11)
                Text(recorder.isPaused ? "PAUSE" : "REC")
                    .font(.callout.weight(.semibold))
                Text(TimeFormat.hms(recorder.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    titleDraft = recorder.title
                    editingTitle = true
                } label: {
                    Text(recorder.title).lineLimit(1).font(.headline)
                }
                .buttonStyle(.plain)
                .help("Rename")
                Button {
                    editingDetails = true
                } label: {
                    Label(detailsSummary, systemImage: "person.2")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Change the meeting type and participants")
            }
            Spacer()
            if recorder.isMicMuted {
                Label("Muted", systemImage: "mic.slash.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                LevelMeter(title: L("Mic"), level: recorder.levels.mic)
            }
            if capturesSystem {
                LevelMeter(title: L("System"), level: recorder.levels.system)
            }
            Button(recorder.isMicMuted ? "Unmute Mic" : "Mute Mic", systemImage: recorder.isMicMuted ? "mic.fill" : "mic.slash") {
                recorder.setMicMuted(!recorder.isMicMuted)
            }
            .help("Stop recording your mic only (⌃⌥M from any app). This doesn't mute you in the call.")
            Button(recorder.isPaused ? "Resume" : "Pause", systemImage: recorder.isPaused ? "play.fill" : "pause.fill") {
                recorder.togglePause(!recorder.isPaused)
            }
            Button("End", systemImage: "stop.fill") {
                Task { await recorder.stop() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(recorder.phase == .stopping)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var mutedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash.fill")
            Text("Mic muted: what's said into it isn't being recorded.")
                .font(.callout.weight(.semibold))
            Spacer()
            Button("Unmute Mic") { recorder.setMicMuted(false) }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.25))
    }

    private var liveColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live").font(.headline)
                Text("provisional, no speakers").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            if let status = recorder.liveStatus {
                Text(status).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            LiveTranscriptList(segments: recorder.live, follow: true)
        }
    }

    private var notesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notes").font(.headline).padding(12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if recorder.notes.isEmpty {
                            legend
                        }
                        ForEach(recorder.notes) { note in
                            NoteRow(t: note.t, kind: note.kind, text: note.body).id(note.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: recorder.notes.count) {
                    if let last = recorder.notes.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: NoteKind.classify(recorder.draft, namingPatterns: model.configValue("speakers", "naming_patterns", default: [])).symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField("Note, then Return", text: $recorder.draft)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit {
                        recorder.submitDraft()
                        inputFocused = true
                    }
            }
            .padding(12)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("The timestamp is taken at the first keystroke. Return on an empty line creates a bookmark. ⌃⌥N opens the note field from any app.")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                legendRow("!", "action")
                legendRow("#", "decision")
                legendRow("?", "question")
                legendRow("~", "private note, never exported")
                legendRow("@Jim", "the person speaking is Jim")
                legendRow("@Jim+", "the next person to speak is Jim")
                legendRow("/mute", "stop recording the mic, /unmute to resume (⌃⌥M from any app)")
                legendRow("/pause", "also /resume, /stop, /title, /participants")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func legendRow(_ prefix: String, _ meaning: LocalizedStringKey) -> some View {
        GridRow {
            Text(prefix).font(.system(.callout, design: .monospaced))
            Text(meaning)
        }
    }
}

/// Type, counts and names, editable while recording. The title has its own editor.
struct MeetingDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var form: MeetingForm
    private let original: MeetingForm
    private let capturesSystem: Bool
    private let save: (MeetingForm) -> Void

    init(form: MeetingForm, capturesSystem: Bool, save: @escaping (MeetingForm) -> Void) {
        _form = State(initialValue: form)
        original = form
        self.capturesSystem = capturesSystem
        self.save = save
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    MeetingTypePicker(mode: $form.mode)
                    LanguagesPicker(title: "Languages spoken", languages: $form.languages)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("These values apply to the whole recording when it's processed.")
                        LanguagesHint()
                        if let notice = modeNotice {
                            Label(notice, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ParticipantsSection(form: $form)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(form)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(form == original)
            }
            .padding(14)
        }
        .frame(width: 480, height: 540)
    }

    private var modeNotice: String? {
        if form.mode.capturesSystem && !capturesSystem {
            return L("System audio starts when you save: remote voices before that weren't recorded.")
        }
        if form.mode == .presentiel && original.mode != .presentiel {
            return L("In Person ignores the system audio, including what's already been recorded.")
        }
        return nil
    }
}

struct NoteRow: View {
    let t: Double
    let kind: NoteKind
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TimeFormat.hms(t))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
                .accessibilityLabel(kind.title)
            Text(text.isEmpty ? kind.title : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct LiveTranscriptList: View {
    let segments: [LiveSegment]
    var follow = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if segments.isEmpty {
                        Text("Text appears here as soon as someone speaks.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(TimeFormat.hms(segment.start))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Image(systemName: segment.track == "mic" ? "mic" : "speaker.wave.2")
                                .font(.caption)
                                .foregroundStyle(segment.track == "mic" ? Color.blue : Color.teal)
                                .accessibilityLabel(segment.track == "mic" ? "Mic" : "System")
                            Text(segment.text).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .id(segment.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .onChange(of: segments.count) {
                if follow, let last = segments.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
