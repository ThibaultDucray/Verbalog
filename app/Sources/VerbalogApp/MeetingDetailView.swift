// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import VerbalogCore

struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionMeta

    private enum Tab: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case notes = "Notes"
        case summary = "Summary"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .transcript
    @State private var transcript: Transcript?
    @State private var summary: String?
    @State private var search = ""
    @State private var showTransfer = false
    @State private var renamingLabel: String?
    @State private var nameDraft = ""
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var canUndo = false
    @State private var editBusy = false
    @State private var editingTurnID: String?
    @State private var newSpeakerRequest: NewSpeakerRequest?
    @State private var newSpeakerName = ""

    private struct NewSpeakerRequest {
        let turn: Turn
        let selection: (from: Int, to: Int)?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle(session.title)
        .searchable(text: $search, prompt: "Search transcript")
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button("Undo", systemImage: "arrow.uturn.backward") { edit(["op": "undo"]) }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!canUndo || editBusy || editingTurnID != nil)
                    .help("Undo the last change to this transcript")
            }
            ToolbarItem {
                exportMenu
            }
            ToolbarItem {
                Button("Send to LLM", systemImage: "paperplane") { showTransfer = true }
                    .help("Prepare the transcript for your LLM")
            }
        }
        .task(id: session) { load() }
        .sheet(isPresented: $showTransfer, onDismiss: load) {
            TransferSheet(session: session)
                .environmentObject(model)
        }
        .alert("Rename Speaker", isPresented: Binding(get: { renamingLabel != nil }, set: { if !$0 { renamingLabel = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let label = renamingLabel, !nameDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                    rename(label, to: nameDraft.trimmingCharacters(in: .whitespaces))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The name is replaced throughout the transcript.")
        }
        .alert("New Speaker", isPresented: Binding(get: { newSpeakerRequest != nil }, set: { if !$0 { newSpeakerRequest = nil } })) {
            TextField("Name", text: $newSpeakerName)
            Button("Assign") {
                let name = newSpeakerName.trimmingCharacters(in: .whitespaces)
                if let request = newSpeakerRequest, !name.isEmpty {
                    assign(request.turn, selection: request.selection, ["name": name])
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Meeting Title", isPresented: $editingTitle) {
            TextField("Title", text: $titleDraft)
            Button("Rename") {
                let title = titleDraft.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { model.runSimple(["retitle", session.id, title]) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() {
        transcript = model.store.transcript(id: session.id)
        summary = session.outputs?.summary.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        canUndo = model.store.canUndo(id: session.id)
    }

    private func edit(_ operation: [String: Any]) {
        guard
            !editBusy,
            let data = try? JSONSerialization.data(withJSONObject: operation),
            let json = String(data: data, encoding: .utf8)
        else { return }
        let client = model.backend
        editBusy = true
        Task {
            do {
                _ = try await client.run(["edit", session.id, "--op", json])
            } catch {
                model.errorMessage = error.localizedDescription
            }
            model.reloadSessions()
            load()
            editBusy = false
        }
    }

    private func editTurn(_ kind: String, _ turn: Turn, _ fields: [String: Any] = [:]) {
        guard let index = transcript?.turns.firstIndex(of: turn) else { return }
        edit(["op": kind, "turn": index, "start": turn.start].merging(fields) { _, new in new })
    }

    private func assign(_ turn: Turn, selection: (from: Int, to: Int)?, _ speaker: [String: Any]) {
        let range: [String: Any] = selection.map { ["from": $0.from, "to": $0.to] } ?? [:]
        editTurn("assign", turn, speaker.merging(range) { _, new in new })
    }

    private func rename(_ label: String, to name: String) {
        let client = model.backend
        Task {
            do {
                _ = try await client.run(["rename", session.id, label, name])
                model.reloadSessions()
                load()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    titleDraft = session.title
                    editingTitle = true
                } label: {
                    Text(session.title).font(.title2.weight(.semibold)).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Rename")
                Spacer()
                if model.store.hasAudio(id: session.id) {
                    Button("Delete Audio", systemImage: "waveform.slash") { model.purgeAudio(session.id) }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 10) {
                if let date = session.createdDate {
                    Text(date.formatted(date: .long, time: .shortened))
                }
                Text(session.imported == true ? L("Imported recording") : session.mode.title)
                if let duration = transcript?.duration {
                    Text(TimeFormat.minutes(duration))
                }
                if let languages = transcript?.languages, !languages.isEmpty {
                    Text(languages.joined(separator: ", ").uppercased())
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            speakerChips
            WarningList(warnings: session.warnings ?? [])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var speakerChips: some View {
        let speakers = transcript?.speakers ?? [:]
        let labels = speakers.keys.sorted()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels, id: \.self) { label in
                    Button {
                        nameDraft = speakers[label]?.name ?? ""
                        renamingLabel = label
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(SpeakerColor.color(for: label, in: labels)).frame(width: 8, height: 8)
                            Text(speakers[label]?.display ?? label)
                            Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Rename this speaker")
                }
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            Button("Markdown (.md)") { exportMarkdown() }
            Button("Plain Text (.txt)") { exportPlain() }
            Button("Full JSON (.json) — includes private notes") { exportJSON() }
            Divider()
            Button("Copy Transcript") {
                if let text = markdownText { model.copyToClipboard(text) }
            }
            Button("Show in Finder") {
                if let path = session.outputs?.md {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Button("Share…") { share() }
            Divider()
            Button("Delete Meeting…", role: .destructive) { model.delete(session.id) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    private var markdownText: String? {
        session.outputs?.md.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    private var fileStem: String {
        session.outputs?.md.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? session.id
    }

    private func exportMarkdown() {
        guard let source = session.outputs?.md else { return }
        model.saveFile(suggestedName: fileStem + ".md") { try copy(URL(fileURLWithPath: source), to: $0) }
    }

    private func exportPlain() {
        guard let transcript else { return }
        model.saveFile(suggestedName: fileStem + ".txt") { try transcript.plainText.write(to: $0, atomically: true, encoding: .utf8) }
    }

    private func exportJSON() {
        guard let source = session.outputs?.json else { return }
        model.saveFile(suggestedName: fileStem + ".json") { try copy(URL(fileURLWithPath: source), to: $0) }
    }

    private func copy(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func share() {
        guard let path = session.outputs?.md, let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [URL(fileURLWithPath: path)])
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .transcript:
            if let transcript {
                TranscriptList(
                    transcript: transcript,
                    search: search,
                    busy: editBusy,
                    editingTurnID: $editingTurnID,
                    onRename: { label in
                        nameDraft = transcript.speakers[label]?.name ?? ""
                        renamingLabel = label
                    },
                    onAssign: { turn, selection, label in
                        assign(turn, selection: selection, ["label": label])
                    },
                    onNewSpeaker: { turn, selection in
                        newSpeakerName = ""
                        newSpeakerRequest = NewSpeakerRequest(turn: turn, selection: selection)
                    },
                    onSetText: { turn, text in editTurn("set_text", turn, ["text": text]) },
                    onDelete: { turn in editTurn("delete", turn) }
                )
            } else {
                ContentUnavailableView("Transcript unreadable", systemImage: "doc.questionmark")
            }
        case .notes:
            notesTab
        case .summary:
            summaryTab
        }
    }

    private var notesTab: some View {
        let notes = (transcript?.notes ?? []).filter { $0.kind != .speaker }
        return Group {
            if notes.isEmpty {
                ContentUnavailableView("No notes", systemImage: "note.text")
            } else {
                List(notes) { note in
                    NoteRow(t: note.t, kind: note.kind, text: note.text)
                }
            }
        }
    }

    @ViewBuilder
    private var summaryTab: some View {
        if let summary {
            ScrollView {
                MarkdownText(text: summary)
                    .padding(20)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") { model.copyToClipboard(summary) }
                    Button("Show in Finder", systemImage: "folder") {
                        if let path = session.outputs?.summary {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }
                .padding(10)
                .background(.bar)
            }
        } else {
            ContentUnavailableView {
                Label("No summary yet", systemImage: "sparkles")
            } description: {
                Text("Send the transcript to your LLM, then paste its response: real names are restored if it was pseudonymized.")
            } actions: {
                Button("Send to LLM") { showTransfer = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct TranscriptList: View {
    let transcript: Transcript
    let search: String
    let busy: Bool
    @Binding var editingTurnID: String?
    let onRename: (String) -> Void
    let onAssign: (Turn, (from: Int, to: Int)?, String) -> Void
    let onNewSpeaker: (Turn, (from: Int, to: Int)?) -> Void
    let onSetText: (Turn, String) -> Void
    let onDelete: (Turn) -> Void

    @State private var textDraft = ""

    private var items: [TranscriptItem] {
        let all = transcript.items
        guard !search.isEmpty else { return all }
        return all.filter { item in
            switch item {
            case .turn(let turn):
                turn.text.localizedCaseInsensitiveContains(search)
                    || (transcript.speakers[turn.label]?.display.localizedCaseInsensitiveContains(search) ?? false)
            case .note(let note):
                note.text.localizedCaseInsensitiveContains(search)
            }
        }
    }

    var body: some View {
        let labels = transcript.speakers.keys.sorted()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    Text(search.isEmpty ? "No speech detected in this recording." : "No results for “\(search)”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    switch item {
                    case .turn(let turn):
                        turnRow(turn, labels: labels)
                    case .note(let note):
                        noteRow(note)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .disabled(busy)
    }

    private func otherSpeakers(than turn: Turn) -> [(label: String, name: String)] {
        transcript.speakers.keys.sorted()
            .filter { $0 != turn.label }
            .map { ($0, transcript.speakers[$0]?.display ?? $0) }
    }

    private func turnRow(_ turn: Turn, labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(otherSpeakers(than: turn), id: \.label) { speaker in
                        Button(speaker.name) { onAssign(turn, nil, speaker.label) }
                    }
                    Divider()
                    Button("New Speaker…") { onNewSpeaker(turn, nil) }
                } label: {
                    Text(transcript.speakers[turn.label]?.display ?? turn.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(SpeakerColor.color(for: turn.label, in: labels))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Change who said this block")
                Text(TimeFormat.hms(turn.start))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Edit Text…") { beginEditing(turn) }
                    Button("Rename This Speaker…") { onRename(turn.label) }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(turn.text, forType: .string)
                    }
                    Divider()
                    Button("Delete Block", role: .destructive) { onDelete(turn) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            if editingTurnID == turn.id {
                textEditor(turn)
            } else {
                SelectableTurnText(text: turn.text) { selection, textView in
                    contextMenu(turn, selection: selection, textView: textView)
                }
                .help("Select words and right-click to give them to another speaker")
            }
        }
    }

    private func beginEditing(_ turn: Turn) {
        textDraft = turn.text
        editingTurnID = turn.id
    }

    private func textEditor(_ turn: Turn) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $textDraft)
                .font(.body)
                .lineSpacing(2)
                .frame(minHeight: 90)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Button("Cancel") { editingTurnID = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    editingTurnID = nil
                    if textDraft != turn.text { onSetText(turn, textDraft) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }

    private func contextMenu(_ turn: Turn, selection: NSRange, textView: NSTextView) -> NSMenu {
        let menu = NSMenu()
        if let offsets = turn.scalarOffsets(of: selection) {
            menu.addItem(speakerSubmenu(L("Assign Selection To"), turn, selection: offsets))
        }
        menu.addItem(speakerSubmenu(L("Assign Block To"), turn, selection: nil))
        menu.addItem(.separator())
        let copy = NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.target = textView
        copy.isEnabled = selection.length > 0
        menu.addItem(copy)
        menu.addItem(ClosureMenuItem(L("Edit Text…")) { beginEditing(turn) })
        menu.addItem(ClosureMenuItem(L("Rename This Speaker…")) { onRename(turn.label) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Delete Block")) { onDelete(turn) })
        return menu
    }

    private func speakerSubmenu(_ title: String, _ turn: Turn, selection: (from: Int, to: Int)?) -> NSMenuItem {
        let submenu = NSMenu()
        for speaker in otherSpeakers(than: turn) {
            submenu.addItem(ClosureMenuItem(speaker.name) { onAssign(turn, selection, speaker.label) })
        }
        if !submenu.items.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ClosureMenuItem(L("New Speaker…")) { onNewSpeaker(turn, selection) })
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func noteRow(_ note: TranscriptNote) -> some View {
        NoteRow(t: note.t, kind: note.kind, text: note.text)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(note.kind.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            .help(note.kind == .private ? "Private note: left out of exports and of what's sent to the LLM" : "")
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// SwiftUI's Text doesn't tell us what is selected, which reassigning part of a block needs.
private struct SelectableTurnText: NSViewRepresentable {
    let text: String
    let menu: (NSRange, NSTextView) -> NSMenu

    final class TextView: NSTextView {
        var menuProvider: ((NSRange, NSTextView) -> NSMenu)?

        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?(selectedRange(), self) ?? super.menu(for: event)
        }
    }

    func makeNSView(context: Context) -> TextView {
        let view = TextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        view.menuProvider = menu
        guard view.string != text else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 780
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}

/// Enough Markdown for a meeting summary: headings and inline styles. Tables stay monospaced so their columns line up.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                render(line)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func render(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            EmptyView()
        } else if trimmed.hasPrefix("#") {
            let level = trimmed.prefix { $0 == "#" }.count
            inline(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("|") {
            Text(trimmed).font(.system(.callout, design: .monospaced))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(String(trimmed.dropFirst(2)))
            }
        } else {
            inline(trimmed)
        }
    }

    private func inline(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: source, options: options) {
            return Text(attributed)
        }
        return Text(source)
    }
}
