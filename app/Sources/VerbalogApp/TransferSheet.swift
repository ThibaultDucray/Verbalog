// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import VerbalogCore

/// The only way text leaves the Mac: previewed exactly, pseudonymized by default, and started by the user.
struct TransferSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: SessionMeta

    private struct Destination: Identifiable {
        let name: String
        let url: String
        var id: String { name }
    }

    private static let destinations = [
        Destination(name: "Claude", url: "https://claude.ai/new"),
        Destination(name: "ChatGPT", url: "https://chatgpt.com/"),
        Destination(name: "Gemini", url: "https://gemini.google.com/app"),
        Destination(name: "Mistral", url: "https://chat.mistral.ai/chat"),
    ]

    @AppStorage("customLLMName") private var customName = ""
    @AppStorage("customLLMURL") private var customURL = ""

    @State private var pseudonymize = true
    @State private var loaded = false
    @State private var loading = false
    @State private var payload = ""
    @State private var prepareTask: Task<Void, Never>?
    @State private var transcriptPreview = ""
    @State private var aliases: [String] = []
    @State private var notice: String?
    @State private var response = ""
    @State private var apiRunning = false
    @State private var apiText = ""
    @State private var apiTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Send to LLM").font(.title2.weight(.semibold))
                Spacer()
                Toggle("Pseudonymize", isOn: $pseudonymize)
                    .toggleStyle(.switch)
                    .onChange(of: pseudonymize) { prepare() }
            }

            HSplitView {
                preview.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                actions.frame(minWidth: 300, idealWidth: 340, maxWidth: 400, maxHeight: .infinity).padding(.leading, 12)
            }

            HStack {
                if let notice {
                    Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button("Close") {
                    apiTask?.cancel()
                    prepareTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(minWidth: 860, idealWidth: 980, minHeight: 600, idealHeight: 680)
        .task {
            pseudonymize = model.configValue("privacy", "pseudonymize", default: true)
            loaded = true
            prepare()
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Exact text that will be sent").font(.headline)
                if loading { ProgressView().controlSize(.small) }
            }
            if pseudonymize {
                Text(loading ? "Searching for sensitive terms locally…" : aliases.isEmpty
                     ? "No terms replaced: add to the sensitive terms list in Settings if needed."
                     : "\(aliases.count) term(s) replaced: \(aliases.prefix(8).joined(separator: ", "))\(aliases.count > 8 ? "…" : "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("Names, amounts and contact details will be sent as they are.", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
            ScrollView {
                Text(payload)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var actions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("1. Transfer") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Copy Prompt + Transcript", systemImage: "doc.on.doc") { copyPayload() }
                            .disabled(payload.isEmpty)
                        Button("Copy Transcript Only", systemImage: "text.alignleft") {
                            model.copyToClipboard(transcriptPreview)
                            notice = L("Transcript copied.")
                        }
                        .disabled(transcriptPreview.isEmpty)
                        Button("Save As…", systemImage: "square.and.arrow.down") { savePayload() }
                            .disabled(payload.isEmpty)
                        Divider()
                        Text("Copy and open:").font(.callout).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                            ForEach(allDestinations) { destination in
                                Button(destination.name) { open(destination) }
                                    .disabled(payload.isEmpty)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("2. Get the Response") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $response)
                            .font(.callout)
                            .frame(height: 110)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                        Button("Save as Summary", systemImage: "tray.and.arrow.down") { saveResponse() }
                            .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if pseudonymize {
                            Text("Real names are restored when you save.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Or directly through the Claude API") {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.hasSecret(.anthropicKey) {
                            HStack {
                                Button(apiRunning ? "Stop" : "Generate Summary", systemImage: apiRunning ? "stop.fill" : "sparkles") {
                                    apiRunning ? apiTask?.cancel() : summarizeWithAPI()
                                }
                                .disabled(payload.isEmpty)
                                if apiRunning { ProgressView().controlSize(.small) }
                            }
                            Text("Model: \(model.configValue("claude", "model", default: "claude-opus-5-5"))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !apiText.isEmpty {
                                ScrollView {
                                    Text(apiText).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 120)
                            }
                        } else {
                            Text("Add an API key in Settings (LLM tab) to enable this.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
        }
    }

    private var allDestinations: [Destination] {
        var list = Self.destinations
        if !customName.isEmpty, URL(string: customURL)?.scheme != nil {
            list.append(Destination(name: customName, url: customURL))
        }
        return list
    }

    private func prepare() {
        guard loaded else { return }
        loading = true
        payload = ""
        let client = model.backend
        let flag = pseudonymize ? "--pseudonymize" : "--no-pseudonymize"
        transcriptPreview = ""
        aliases = []
        // Toggling must never leave a stale run able to finish last: the screen
        // could then show unpseudonymized text with the switch on.
        prepareTask?.cancel()
        prepareTask = Task {
            do {
                let result = try await client.run(["prepare", session.id, flag])
                guard !Task.isCancelled else { return }
                transcriptPreview = result["transcript"] as? String ?? ""
                payload = result["payload"] as? String ?? ""
                aliases = (result["aliases"] as? [[String: Any]] ?? []).compactMap { $0["alias"] as? String }
                loading = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                loading = false
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func copyPayload() {
        model.copyToClipboard(payload)
        notice = L("Copied: \(payload.count) characters.")
    }

    private func open(_ destination: Destination) {
        guard let url = URL(string: destination.url) else { return }
        model.copyToClipboard(payload)
        notice = L("Copied: paste with ⌘V into \(destination.name), then come back here with the response.")
        NSWorkspace.shared.open(url)
    }

    private func savePayload() {
        let stem = session.outputs?.md.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? session.id
        let suffix = pseudonymize ? "_pseudonymise" : ""
        model.saveFile(suggestedName: stem + suffix + ".md") {
            try payload.write(to: $0, atomically: true, encoding: .utf8)
        }
    }

    private func saveResponse() {
        let client = model.backend
        let arguments = ["save-summary", session.id] + (pseudonymize ? [] : ["--no-reidentify"])
        let text = response
        Task {
            do {
                _ = try await client.run(arguments, stdin: text)
                model.reloadSessions()
                dismiss()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func summarizeWithAPI() {
        let client = model.backend
        let flag = pseudonymize ? "--pseudonymize" : "--no-pseudonymize"
        apiRunning = true
        apiText = ""
        apiTask = Task {
            defer { apiRunning = false }
            do {
                _ = try await client.run(["summarize", session.id, flag]) { event in
                    guard event.name == "delta", let text = event.fields["text"] as? String else { return }
                    Task { @MainActor in apiText += text }
                }
                model.reloadSessions()
                dismiss()
            } catch is CancellationError {
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
