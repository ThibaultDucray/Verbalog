// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VerbalogCaptureKit
import VerbalogCore

/// A meeting recorded elsewhere (a call's recording, a voice memo, a dictaphone) brought in
/// as an audio or video file, then processed like any other.
struct ImportView: View {
    @EnvironmentObject private var model: AppModel

    @State private var file: URL?
    @State private var date = Date()
    @State private var form = MeetingForm()
    @State private var importing = false
    @State private var targeted = false

    var body: some View {
        Form {
            Section {
                if let file {
                    LabeledContent("File") {
                        HStack {
                            Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Button("Choose Another…") { choose() }
                        }
                    }
                    TextField("Title", text: $form.title, prompt: Text(file.deletingPathExtension().lastPathComponent))
                    DatePicker("Meeting date", selection: $date)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Drop an audio or video file here").font(.headline)
                        Text("WAV, M4A, MP3, AIFF, FLAC, or a video such as MP4 or MOV").font(.caption).foregroundStyle(.secondary)
                        Button("Choose a File…") { choose() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .background(targeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
            } footer: {
                Text("Verbalog transcribes a copy and deletes it afterwards, like any recording. Your file is left as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if file != nil {
                Section {
                    LanguagesPicker(title: "Languages spoken", languages: $form.languages)
                    Picker("People speaking", selection: $form.roomCount) {
                        Text("Unknown").tag(Int?.none)
                        ForEach(1...30, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    TextField("Expected participants", text: $form.participants, prompt: Text("Sophie, Marc, Jim…"))
                } header: {
                    Text("Meeting")
                } footer: {
                    Text("All voices are on one track, so Verbalog separates them by sound alone: knowing how many people speak helps a lot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    start()
                } label: {
                    if importing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Import and Transcribe", systemImage: "waveform")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(file == nil || importing || model.doctor?.canTranscribe == false)
            }
            .padding(14)
            .background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            use(url)
            return true
        } isTargeted: { targeted = $0 }
        .navigationTitle("Import Recording")
        .task {
            if model.config.isEmpty { await model.refreshConfig() }
            form.languages = MeetingLanguage.normalized(model.configValue("transcription", "languages", default: ["fr", "en"]))
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url)
    }

    private func use(_ url: URL) {
        file = url
        // The file's own date is usually when the meeting took place.
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        date = values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private func start() {
        guard let file else { return }
        importing = true
        Task {
            do {
                try await model.importRecording(file, form: form, date: date)
            } catch {
                model.errorMessage = error.localizedDescription
            }
            importing = false
        }
    }
}
