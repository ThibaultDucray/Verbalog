import SwiftUI
import VerbalogCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecordingController
    @State private var search = ""

    private var filtered: [SessionMeta] {
        guard !search.isEmpty else { return model.sessions }
        return model.sessions.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("New Meeting", systemImage: "plus.circle.fill")
                    .tag(Selection.newMeeting)
                    .selectionDisabled(recorder.isActive)
                    .foregroundStyle(recorder.isActive ? .secondary : .primary)

                Section("Meetings") {
                    if filtered.isEmpty {
                        Text(search.isEmpty ? "No meetings yet" : "No results")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    ForEach(filtered) { session in
                        SessionRow(session: session)
                            .tag(Selection.session(session.id))
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .safeAreaInset(edge: .bottom) { statusFooter }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            detail
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case nil:
            ContentUnavailableView {
                Label("Verbalog", systemImage: "waveform")
            } description: {
                Text("Capture, transcribe and annotate your meetings. Audio never leaves this Mac.")
            } actions: {
                Button("New Meeting") { model.selection = .newMeeting }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.isActive)
            }
        case .newMeeting:
            NewMeetingView()
        case .setup:
            SetupView()
        case .session(let id):
            MeetingContainer(id: id)
                .id(id)
        }
    }

    private var issueCount: Int {
        guard model.backend.isInstalled else { return 1 }
        guard let doctor = model.doctor else { return 0 }
        return [
            !doctor.canTranscribe, !doctor.canDiarize, doctor.fileVault == false, doctor.outputDirCloudSynced, !doctor.userNameSet,
        ].filter { $0 }.count
    }

    private var statusFooter: some View {
        Button {
            model.selection = .setup
        } label: {
            HStack(spacing: 6) {
                Image(systemName: issueCount == 0 ? "checkmark.seal" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issueCount == 0 ? Color.secondary : Color.orange)
                Text(issueCount == 0 ? "Status & Models" : "\(issueCount) item(s) to fix")
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                badge
                if let date = session.createdDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                if let duration = session.duration, duration > 0 {
                    Text("· \(TimeFormat.minutes(duration))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var badge: some View {
        if model.recorder.sessionID == session.id {
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        } else if model.jobs[session.id] != nil {
            ProgressView().controlSize(.mini)
        } else {
            switch session.status {
            case .review: Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .recorded, .recording, .processing: Image(systemName: "hourglass").foregroundStyle(.orange)
            case .done: EmptyView()
            }
        }
    }
}

/// One meeting, in whichever state of its life it's in.
struct MeetingContainer: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecordingController
    let id: String

    var body: some View {
        if recorder.sessionID == id {
            RecordingView()
        } else if let job = model.jobs[id] {
            ProcessingView(id: id, job: job)
        } else if let session = model.meta(id) {
            switch session.status {
            case .done:
                MeetingDetailView(session: session)
            case .review:
                ReviewView(session: session)
            case .recorded, .recording, .processing, .failed:
                PendingView(session: session)
            }
        } else {
            ContentUnavailableView("Meeting not found", systemImage: "questionmark.folder")
        }
    }
}

// MARK: Small shared pieces

struct LevelMeter: View {
    let title: String
    let level: Float

    private var active: Int {
        // -60 dB to -6 dB across the segments, so that normal speech lands mid-scale.
        Int(((max(-60, min(-6, level)) + 60) / 54 * 8).rounded())
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < active ? (index >= 7 ? Color.orange : Color.green) : Color.secondary.opacity(0.2))
                        .frame(width: 7, height: 12)
                }
            }
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) level")
        .accessibilityValue("\(active) of 8")
    }
}

struct WarningList: View {
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension NoteKind {
    var symbol: String {
        switch self {
        case .note: "note.text"
        case .action: "checkmark.circle"
        case .decision: "checkmark.seal"
        case .question: "questionmark.circle"
        case .speaker: "person.wave.2"
        case .private: "lock"
        case .bookmark: "bookmark"
        }
    }

    var tint: Color {
        switch self {
        case .note: .secondary
        case .action: .blue
        case .decision: .green
        case .question: .orange
        case .speaker: .purple
        case .private: .gray
        case .bookmark: .pink
        }
    }
}

enum SpeakerColor {
    private static let palette: [Color] = [.blue, .teal, .purple, .orange, .pink, .indigo, .green, .brown]

    static func color(for label: String, in labels: [String]) -> Color {
        let index = labels.sorted().firstIndex(of: label) ?? 0
        return palette[index % palette.count]
    }
}
