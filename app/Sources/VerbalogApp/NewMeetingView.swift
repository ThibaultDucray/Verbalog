// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import VerbalogCaptureKit
import VerbalogCore

struct NewMeetingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecordingController

    @State private var form = MeetingForm()
    @State private var devices: [AudioInputDevice] = []
    @State private var runningApps: [(id: String, name: String)] = []
    @State private var levels = AudioLevels()
    @State private var monitor: CaptureSession?
    @State private var monitorError: String?
    @State private var starting = false
    @State private var loaded = false

    private static let lastFormKey = "lastMeetingForm"

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $form.title, prompt: Text("Steering committee…"))
                    .font(.title3)
                MeetingTypePicker(mode: $form.mode)
                LanguagesPicker(title: "Languages spoken", languages: $form.languages)
            } footer: {
                LanguagesHint()
            }

            ParticipantsSection(form: $form)

            Section("Audio Sources") {
                Picker("Microphone input", selection: $form.micDevice) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                if form.mode.capturesSystem {
                    Picker("System audio", selection: $form.systemSource) {
                        Text("All Mac audio").tag(String?.none)
                        ForEach(runningApps, id: \.id) { app in
                            Text(app.name).tag(String?.some(app.id))
                        }
                    }
                }
                HStack(spacing: 20) {
                    LevelMeter(title: L("Mic"), level: levels.mic)
                    if form.mode.capturesSystem {
                        LevelMeter(title: L("System"), level: levels.system)
                    }
                }
                if let monitorError {
                    Label(monitorError, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                }
                if let tip = audioTip {
                    Label(tip, systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { footer }
        .navigationTitle("New Meeting")
        .task { await load() }
        .onDisappear { stopMonitor() }
        .onChange(of: form.mode) { restartMonitor() }
        .onChange(of: form.micDevice) { restartMonitor() }
        .onChange(of: form.systemSource) { restartMonitor() }
    }

    private var footer: some View {
        HStack {
            Label("Let participants know they're being recorded.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if model.doctor?.canTranscribe == false {
                Button("Download Models…") { model.selection = .setup }
            }
            Button {
                startMeeting()
            } label: {
                if starting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Start", systemImage: "record.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(starting || recorder.isActive)
        }
        .padding(14)
        .background(.bar)
    }

    private var audioTip: String? {
        switch form.mode {
        case .visio where !form.headset:
            L("Without a headset, the mic also picks up remote voices: duplicates are removed after the meeting.")
        case .presentiel:
            L("The Mac's mic is poor in a room: a USB conference mic in the middle of the table helps a lot.")
        case .hybride:
            L("Remote voices come out of the speakers and reach the mic too: duplicates are removed after the meeting.")
        default:
            nil
        }
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        devices = AudioDevices.inputs()
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

        if model.config.isEmpty { await model.refreshConfig() }
        form.mode = MeetingMode(rawValue: model.configValue("session", "default_mode", default: "visio")) ?? .visio
        form.languages = MeetingLanguage.normalized(model.configValue("transcription", "languages", default: ["fr", "en"]))
        let configuredMic: String = model.configValue("capture", "mic_device", default: "default")
        form.micDevice = configuredMic == "default" ? nil : AudioDevices.device(forUIDOrName: configuredMic)?.uid
        let configuredSource: String = model.configValue("capture", "system_source", default: "all")
        form.systemSource = runningApps.contains { $0.id == configuredSource } ? configuredSource : nil

        // Only the audio setup carries over. Counts and names left from another meeting are
        // easy to miss when starting in a hurry, and they mislead voice separation.
        if model.configValue("session", "remember_last", default: true),
           let data = UserDefaults.standard.data(forKey: Self.lastFormKey),
           let last = try? JSONDecoder().decode(MeetingForm.self, from: data) {
            // A device or app from last time may be gone.
            form.micDevice = last.micDevice.flatMap { mic in devices.contains { $0.uid == mic } ? mic : nil }
            form.systemSource = last.systemSource.flatMap { app in runningApps.contains { $0.id == app } ? app : nil }
        }
        startMonitor()
    }

    private func startMonitor() {
        guard !recorder.isActive else { return }
        let session = CaptureSession(configuration: .init(
            directory: nil,
            micDevice: form.micDevice,
            captureSystem: form.mode.capturesSystem,
            systemSource: form.systemSource
        ))
        session.onLevels = { value in
            Task { @MainActor in levels = value }
        }
        monitor = session
        monitorError = nil
        Task {
            do {
                let result = try await session.start()
                monitorError = result.systemError?.localizedDescription
            } catch {
                monitorError = error.localizedDescription
            }
        }
    }

    private func stopMonitor() {
        guard let session = monitor else { return }
        monitor = nil
        Task { await session.stop() }
    }

    private func restartMonitor() {
        guard loaded else { return }
        stopMonitor()
        levels = AudioLevels()
        startMonitor()
    }

    private func startMeeting() {
        starting = true
        let current = monitor
        monitor = nil
        Task {
            // The test stream must be gone before the real one claims the same devices.
            await current?.stop()
            if let data = try? JSONEncoder().encode(form) {
                UserDefaults.standard.set(data, forKey: Self.lastFormKey)
            }
            do {
                try await recorder.start(form: form)
            } catch {
                model.errorMessage = error.localizedDescription
                startMonitor()
            }
            starting = false
        }
    }
}

/// Shared by the new-meeting form and the details editor during a meeting.
struct MeetingTypePicker: View {
    @Binding var mode: MeetingMode

    var body: some View {
        Picker("Meeting Type", selection: $mode) {
            ForEach(MeetingMode.allCases) { mode in
                VStack(alignment: .leading) {
                    Text(mode.title)
                    Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                }
                .tag(mode)
            }
        }
        .pickerStyle(.radioGroup)
    }
}

/// Any number can be ticked, but at least one stays.
struct LanguagesPicker: View {
    let title: LocalizedStringKey
    @Binding var languages: [String]

    var body: some View {
        LabeledContent(title) {
            // One row when there's room, two otherwise (the Settings window is narrower).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { boxes(MeetingLanguage.allCases) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) { boxes(Array(MeetingLanguage.allCases.prefix(4))) }
                    HStack(spacing: 12) { boxes(Array(MeetingLanguage.allCases.dropFirst(4))) }
                }
            }
        }
    }

    private func boxes(_ languages: [MeetingLanguage]) -> some View {
        ForEach(languages) { language in
            Toggle(language.title, isOn: Binding(
                get: { self.languages.contains(language.rawValue) },
                set: { ticked in
                    let codes = ticked ? self.languages + [language.rawValue] : self.languages.filter { $0 != language.rawValue }
                    if !codes.isEmpty { self.languages = MeetingLanguage.normalized(codes) }
                }
            ))
            .toggleStyle(.checkbox)
        }
    }
}

struct LanguagesHint: View {
    var body: some View {
        Text("Tick only the languages actually spoken: each extra one makes detection less sure. With a single language, everything is transcribed in it.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct ParticipantsSection: View {
    @Binding var form: MeetingForm

    var body: some View {
        Section {
            if form.mode != .presentiel {
                Toggle("I'm wearing a headset", isOn: $form.headset)
            }
            if form.mode != .visio {
                countPicker("People in the room (including me)", selection: $form.roomCount)
            }
            if form.mode != .presentiel {
                countPicker("Remote participants", selection: $form.remoteCount)
            }
            TextField("Expected participants", text: $form.participants, prompt: Text("Sophie, Marc, Jim…"))
        } header: {
            Text("Participants")
        } footer: {
            Text("If you know the number of people, voice separation gets much better. Expected names correct typos when naming speakers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func countPicker(_ title: LocalizedStringKey, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("Unknown").tag(Int?.none)
            ForEach(1...30, id: \.self) { count in
                Text("\(count)").tag(Int?.some(count))
            }
        }
    }
}
