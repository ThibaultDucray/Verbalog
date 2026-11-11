import AppKit
import Carbon.HIToolbox
import SwiftUI
import VerbalogCore

@main
struct VerbalogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Verbalog", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.recorder)
                .frame(minWidth: 960, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Meeting") { model.selection = .newMeeting }
                    .keyboardShortcut("n")
                    .disabled(model.recorder.isActive)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.recorder)
        } label: {
            MenuBarLabel(recorder: model.recorder)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated {
            hotKey = GlobalHotKey([
                (kVK_ANSI_N, { MainActor.assumeIsolated { QuickNotePanel.shared.toggle() } }),
                (kVK_ANSI_M, {
                    MainActor.assumeIsolated {
                        let recorder = AppModel.shared.recorder
                        if recorder.isActive { recorder.setMicMuted(!recorder.isMicMuted) }
                    }
                }),
            ])
            AppModel.shared.launch()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            guard model.recorder.isActive || !model.jobs.isEmpty else { return .terminateNow }

            let alert = NSAlert()
            if model.recorder.isActive {
                alert.messageText = L("A meeting is being recorded")
                alert.informativeText = L("Recording will stop and be kept. You can process it the next time you open Verbalog.")
            } else {
                alert.messageText = L("Processing is in progress")
                alert.informativeText = L("It will be interrupted. The audio is kept and you can start it again.")
            }
            alert.addButton(withTitle: L("Quit"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

            Task { @MainActor in
                await model.prepareForQuit()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
