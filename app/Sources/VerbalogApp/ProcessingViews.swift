import AVFoundation
import MediaPlayer
import SwiftUI
import VerbalogCore

struct ProcessingView: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    let job: JobProgress
    @State private var live: [LiveSegment] = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.meta(id)?.title ?? "").font(.title2.weight(.semibold))
                HStack {
                    ProgressView(value: job.fraction)
                    Text("\(Int(job.fraction * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelJob(id) }
                }
                Text(job.label).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            if live.isEmpty {
                ContentUnavailableView(
                    "Processing locally",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("Nothing leaves this Mac. An hour-long meeting takes a few minutes.")
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Provisional transcript, until the final version is ready")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                    LiveTranscriptList(segments: live)
                }
            }
        }
        .navigationTitle(model.meta(id)?.title ?? L("Processing"))
        .task { live = model.store.liveSegments(id: id) }
    }
}

/// Recorded but not transcribed: a failure, or a recording recovered after a crash.
struct PendingView: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.title).font(.title2.weight(.semibold))
            if session.status == .failed, let error = session.error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .symbolRenderingMode(.multicolor)
                    .textSelection(.enabled)
            }
            WarningList(warnings: session.warnings ?? [])
            if model.doctor?.canTranscribe == false {
                Label("The Whisper model isn't downloaded.", systemImage: "arrow.down.circle")
                Button("Open Status & Models") { model.selection = .setup }
            }
            if model.store.hasAudio(id: session.id) {
                Text("The audio is kept on this Mac, ready to be transcribed.")
                    .foregroundStyle(.secondary)
                Button("Start Processing", systemImage: "play.fill") { model.process(session.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.doctor?.canTranscribe == false)
            } else {
                Text("No audio for this meeting.").foregroundStyle(.secondary)
            }
            let live = model.store.liveSegments(id: session.id)
            if !live.isEmpty {
                Divider()
                Text("Provisional transcript").font(.headline)
                LiveTranscriptList(segments: live)
            }
            Spacer()
            Button("Delete This Meeting", role: .destructive) { model.delete(session.id) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(session.title)
    }
}

/// Plays a few seconds around a quote, while the audio still exists (it's deleted after this screen).
@MainActor
final class SnippetPlayer: ObservableObject {
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    private static let clipSeconds = 5.0

    func toggle(key: String, url: URL, at time: Double) {
        let wasPlaying = playing == key
        stop()
        guard !wasPlaying, let audio = try? AVAudioPlayer(contentsOf: url) else { return }
        audio.currentTime = max(0, time)
        announcePlayback()
        audio.play()
        player = audio
        playing = key
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.clipSeconds))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        player?.stop()
        player = nil
        playing = nil
        withdrawPlayback()
    }

    /// Some Bluetooth headphones (seen on a Sony WH-CH520) stay silent after connecting until
    /// they're told playback started, which macOS only does for the Now Playing app. The title
    /// is generic because this info reaches Control Center and the headset.
    private func announcePlayback() {
        let center = MPNowPlayingInfoCenter.default()
        for command in Self.commands {
            command.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.stop() }
                return .success
            }
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Verbalog",
            MPMediaItemPropertyPlaybackDuration: Self.clipSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        center.playbackState = .playing
    }

    private func withdrawPlayback() {
        for command in Self.commands { command.removeTarget(nil) }
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }

    private static var commands: [MPRemoteCommand] {
        let center = MPRemoteCommandCenter.shared()
        return [center.togglePlayPauseCommand, center.pauseCommand, center.playCommand]
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionMeta

    @State private var transcript: Transcript?
    @State private var names: [String: String] = [:]
    @State private var mergedInto: [String: String] = [:]
    @StateObject private var player = SnippetPlayer()

    private var labels: [String] {
        guard let transcript else { return [] }
        // Unnamed first: that's what needs attention. Then longest talkers.
        return transcript.speakers.keys.sorted { a, b in
            let sa = transcript.speakers[a]!, sb = transcript.speakers[b]!
            if (sa.name == nil) != (sb.name == nil) { return sa.name == nil }
            return sa.talk_seconds > sb.talk_seconds
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Speakers to Identify").font(.title2.weight(.semibold))
                    Text("Leave empty to keep “Speaker”. The audio is deleted once you confirm this screen.")
                        .foregroundStyle(.secondary)
                    if let warnings = transcript?.warnings {
                        WarningList(warnings: warnings)
                    }
                    conflicts
                    ForEach(labels, id: \.self) { label in
                        if let speaker = transcript?.speakers[label] {
                            speakerCard(label, speaker)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Confirm and Export", systemImage: "checkmark") { finish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .navigationTitle(session.title)
        .task {
            transcript = model.store.transcript(id: session.id)
            for (label, speaker) in transcript?.speakers ?? [:] {
                names[label] = speaker.name ?? ""
            }
        }
        .onDisappear { player.stop() }
    }

    @ViewBuilder
    private var conflicts: some View {
        let items = transcript?.conflicts ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hints to check").font(.headline)
                ForEach(items, id: \.self) { conflict in
                    Label(describe(conflict), systemImage: "exclamationmark.bubble")
                        .font(.callout)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func describe(_ conflict: SpeakerConflict) -> String {
        let time = TimeFormat.hms(conflict.t)
        let speakers = conflict.labels.map { transcript?.speakers[$0]?.display ?? $0 }.joined(separator: L(" or "))
        switch conflict.kind {
        case "contradiction":
            let previous = conflict.previous ?? L("something else")
            return L("[\(time)] “\(conflict.name)” given for \(speakers), already named \(previous).")
        case "ambiguous":
            return L("[\(time)] “\(conflict.name)”: two voices active at once (\(speakers)).")
        default:
            return L("[\(time)] “\(conflict.name)”: nobody was speaking at that moment.")
        }
    }

    private func speakerCard(_ label: String, _ speaker: Speaker) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(speaker.display).font(.headline)
                Text("\(TimeFormat.minutes(speaker.talk_seconds)) of speech").font(.callout).foregroundStyle(.secondary)
                if speaker.source == "voiceprint" {
                    Label("Voiceprint", systemImage: "person.badge.shield.checkmark").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                mergeMenu(label)
            }
            ForEach(speaker.samples, id: \.self) { sample in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    let key = "\(label)-\(sample.t)"
                    Button {
                        player.toggle(key: key, url: model.store.audioURL(id: session.id, track: sample.track ?? speaker.track), at: sample.t)
                    } label: {
                        Image(systemName: player.playing == key ? "stop.circle" : "play.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Listen to 5 seconds")
                    .accessibilityLabel(player.playing == key ? "Stop" : "Listen to 5 seconds")
                    Text(TimeFormat.hms(sample.t)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text("“\(sample.text)”").textSelection(.enabled)
                }
            }
            if let target = mergedInto[label] {
                Label("Same person as \(transcript?.speakers[target]?.display ?? target)", systemImage: "arrow.triangle.merge")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("Name", text: Binding(get: { names[label] ?? "" }, set: { names[label] = $0 }), prompt: Text(speaker.display))
                        .textFieldStyle(.roundedBorder)
                    let expected = session.participants ?? []
                    if !expected.isEmpty {
                        Menu("Participants") {
                            ForEach(expected, id: \.self) { person in
                                Button(person) { names[label] = person }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func mergeMenu(_ label: String) -> some View {
        Menu("Merge") {
            if mergedInto[label] != nil {
                Button("Undo Merge") { mergedInto[label] = nil }
            }
            ForEach(labels.filter { $0 != label && mergedInto[$0] == nil }, id: \.self) { other in
                Button("Same person as \(transcript?.speakers[other]?.display ?? other)") {
                    mergedInto[label] = other
                    // Anything pointing here now follows along, so a merge never leads to a merged label.
                    for (key, value) in mergedInto where value == label { mergedInto[key] = other }
                }
            }
        }
        .fixedSize()
    }

    private func finish() {
        player.stop()
        let cleaned = names.mapValues { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.value.isEmpty }
        let merges = mergedInto.map { [$0.value, $0.key] }
        model.finalize(session.id, names: cleaned, merges: merges)
    }
}
