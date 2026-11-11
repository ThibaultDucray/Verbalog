import AppKit
import Carbon.HIToolbox
import SwiftUI
import VerbalogCore

/// ⌃⌥ shortcuts from any app: during a call, Verbalog is rarely the one in front.
final class GlobalHotKey {
    private var references: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private static var actions: [() -> Void] = []

    /// `bindings`: virtual key codes, each pressed with ⌃⌥.
    init(_ bindings: [(key: Int, action: () -> Void)]) {
        Self.actions = bindings.map(\.action)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            let index = Int(pressed.id)
            DispatchQueue.main.async {
                if GlobalHotKey.actions.indices.contains(index) { GlobalHotKey.actions[index]() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        for (index, binding) in bindings.enumerated() {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: OSType(0x5642_4C47), id: UInt32(index))  // "VBLG"
            RegisterEventHotKey(UInt32(binding.key), UInt32(controlKey | optionKey), identifier, GetApplicationEventTarget(), 0, &reference)
            references.append(reference)
        }
    }

    deinit {
        for reference in references {
            if let reference { UnregisterEventHotKey(reference) }
        }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class QuickNotePanel {
    static let shared = QuickNotePanel()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard AppModel.shared.recorder.isActive else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.center()
        // A non-activating panel takes the keyboard without pulling the call out of the foreground.
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: QuickNoteView(recorder: AppModel.shared.recorder))
        return panel
    }
}

private struct QuickNoteView: View {
    @ObservedObject var recorder: RecordingController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(TimeFormat.hms(recorder.elapsed))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("Note — Return to save, empty = bookmark", text: $recorder.draft)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit {
                    recorder.submitDraft()
                    QuickNotePanel.shared.hide()
                }
                .onExitCommand { QuickNotePanel.shared.hide() }
        }
        .padding(16)
        .frame(width: 520, height: 64)
        .onAppear { focused = true }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var recorder: RecordingController

    var body: some View {
        if recorder.isActive {
            Label(TimeFormat.hms(recorder.elapsed), systemImage: recorder.isMicMuted ? "mic.slash.fill" : recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "waveform")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        if recorder.isActive {
            Text(recorder.title)
            Button("Take a Note  ⌃⌥N") { QuickNotePanel.shared.toggle() }
            Button(recorder.isMicMuted ? "Unmute Mic  ⌃⌥M" : "Mute Mic  ⌃⌥M") { recorder.setMicMuted(!recorder.isMicMuted) }
            Button(recorder.isPaused ? "Resume" : "Pause") { recorder.togglePause(!recorder.isPaused) }
            Button("End Meeting") { Task { await recorder.stop() } }
        } else {
            Button("New Meeting…") {
                model.selection = .newMeeting
                showMainWindow()
            }
        }
        if let job = model.jobs.first {
            Divider()
            Text("\(job.value.label) \(Int(job.value.fraction * 100)) %")
        }
        Divider()
        Button("Open Verbalog") { showMainWindow() }
        Button("Quit") { NSApp.terminate(nil) }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
