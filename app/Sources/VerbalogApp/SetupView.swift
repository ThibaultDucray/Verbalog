import SwiftUI
import VerbalogCore

/// What's ready, what isn't, and the button for each.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var hfToken = ""

    var body: some View {
        Form {
            Section {
                let layout = AppModel.backendLayout
                let location = layout.location.path
                if model.backend.isInstalled {
                    statusRow("Installed", ok: true, detail: "\(location)")
                } else if model.backend.needsUpdate {
                    statusRow("Update needed", ok: false, detail: "This version of Verbalog uses different Python packages.")
                    Button("Update") { model.installBackend() }
                        .disabled(model.setupRunning)
                } else {
                    statusRow("Not installed", ok: false, detail: "\(location)")
                    Button(layout.isBundled ? "Install" : "Install (uv sync)") { model.installBackend() }
                        .disabled(model.setupRunning)
                }
            } header: {
                Text("Backend Python")
            } footer: {
                if AppModel.backendLayout.isBundled && !model.backend.isInstalled {
                    Text("Downloads Python and the packages Verbalog needs, once: about 2 GB on disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let doctor = model.doctor {
                Section("Transcription") {
                    statusRow("\(doctor.whisperModel)", ok: doctor.canTranscribe, detail: doctor.canTranscribe ? "Ready, offline" : "To download (about 1.6 GB)")
                    statusRow("\(doctor.liveModel)", ok: doctor.liveCached, detail: doctor.liveCached ? "Live transcript ready" : "Live transcript: to download (about 500 MB)")
                }
                Section {
                    statusRow("\(doctor.diarizationModel)", ok: doctor.canDiarize, detail: doctor.canDiarize ? "Ready, offline" : "Without it, voices on the same track aren't separated")
                    if !doctor.canDiarize {
                        SecureField("Hugging Face token", text: $hfToken, prompt: Text(doctor.hfToken ? "Saved in Keychain" : "hf_…"))
                        Button("Save Token") {
                            model.setSecret(.hfToken, value: hfToken)
                            hfToken = ""
                            Task { await model.refreshDoctor() }
                        }
                        .disabled(hfToken.isEmpty)
                    }
                } header: {
                    Text("Diarization")
                } footer: {
                    if !doctor.canDiarize {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Just once: accept the model's licence, create a read token, save it here and download. No network calls after that.")
                            if let url = URL(string: "https://huggingface.co/\(doctor.diarizationModel)") {
                                Link("Model page on Hugging Face", destination: url)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if !doctor.canTranscribe || !doctor.liveCached || !doctor.canDiarize {
                    Section {
                        Button("Download Missing Models", systemImage: "arrow.down.circle") { model.downloadModels() }
                            .disabled(model.setupRunning)
                        ForEach(model.setupFailures.sorted(by: { $0.key < $1.key }), id: \.key) { failure in
                            Label("\(failure.key) : \(failure.value)", systemImage: "xmark.octagon.fill")
                                .symbolRenderingMode(.multicolor)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("Privacy") {
                    statusRow(
                        doctor.fileVault == true ? "FileVault on" : doctor.fileVault == false ? "FileVault off" : "FileVault status unknown",
                        ok: doctor.fileVault == true,
                        detail: doctor.fileVault == true ? "Deleted audio is protected by disk encryption" : "On an SSD, only disk encryption really protects deleted audio"
                    )
                    statusRow(
                        "\(doctor.outputDir)",
                        ok: !doctor.outputDirCloudSynced,
                        detail: doctor.outputDirCloudSynced ? "Folder syncs to the cloud: transcripts would be sent there. Choose another one in Settings." : "Folder not synced"
                    )
                    statusRow(doctor.ner ? "Name detection (spaCy)" : "Name detection missing", ok: doctor.ner, detail: "Complements the sensitive terms list when pseudonymizing")
                }

                Section("Profile") {
                    statusRow(doctor.userNameSet ? "Name set" : "Your name isn't set", ok: doctor.userNameSet, detail: "Replaces “Me” in transcripts")
                    SettingsLink {
                        Text("Open Settings…")
                    }
                }
            }

            if !model.setupLog.isEmpty || model.setupRunning {
                Section("Log") {
                    if model.setupRunning { ProgressView().controlSize(.small) }
                    ScrollView {
                        Text(model.setupLog)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Status & Models")
        .task {
            await model.refreshConfig()
            await model.refreshDoctor()
        }
    }

    private func statusRow(_ title: LocalizedStringKey, ok: Bool, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .accessibilityLabel(ok ? "Ready" : "Needs attention")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
