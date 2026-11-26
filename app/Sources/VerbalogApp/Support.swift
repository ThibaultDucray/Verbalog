// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import VerbalogCore

/// The voluntary Support Development option: a Stripe page, a discreet invitation after some
/// meetings, and a Help menu entry. Hidden entirely when Info.plist has no link, as in forks.
@MainActor
final class SupportModel: ObservableObject {
    static let link: URL? = (Bundle.main.object(forInfoDictionaryKey: "VerbalogSupportURL") as? String)
        .flatMap { URL(string: $0) }

    @Published private(set) var isSupporter: Bool
    @Published private(set) var inviting = false
    @Published private(set) var completedMeetings: Int

    private let policy = SupportPolicy()

    init() {
        isSupporter = policy.isSupporter
        completedMeetings = policy.completedMeetings
    }

    var isAvailable: Bool { Self.link != nil }

    func meetingCompleted(_ id: String) {
        guard isAvailable else { return }
        if policy.meetingCompleted(id) { inviting = true }
        completedMeetings = policy.completedMeetings
    }

    func openSupportPage() {
        guard let link = Self.link else { return }
        NSWorkspace.shared.open(link)
        if inviting { later() }
    }

    func later() {
        policy.snooze()
        inviting = false
    }

    func markSupporter() {
        policy.markSupporter()
        isSupporter = true
        inviting = false
    }
}

struct SupportInvitation: View {
    @EnvironmentObject private var support: SupportModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.title2)
                .foregroundStyle(.brown)
            VStack(alignment: .leading, spacing: 6) {
                Text("Enjoying Verbalog?").font(.headline)
                Text("You have already turned \(support.completedMeetings) meetings into notes with Verbalog. The app is free and open source. If it saves you time, please consider supporting its continued development.")
                    .font(.callout)
                    // Not fixedSize: laid out at a near-zero width while the split view settles,
                    // a fixed-height paragraph grew taller than the window and threw both the
                    // sidebar and the transcript out of place.
                    .lineLimit(2...4)
                HStack(spacing: 8) {
                    Button("Support Development") { support.openSupportPage() }
                        .buttonStyle(.borderedProminent)
                    Button("Maybe Later") { support.later() }
                    Spacer()
                    Menu {
                        Button("I've Already Supported") { support.markSupporter() }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("More")
                    .accessibilityLabel("More")
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SupportMenu: View {
    @ObservedObject var support: SupportModel

    var body: some View {
        if support.isAvailable {
            Divider()
            if support.isSupporter {
                Text("❤️ Thanks for Supporting Verbalog")
                Button("Support Again…") { support.openSupportPage() }
            } else {
                Button("☕ Support Development…") { support.openSupportPage() }
                Button("I've Already Supported") { support.markSupporter() }
            }
        }
    }
}
