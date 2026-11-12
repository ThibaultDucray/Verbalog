// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// When to invite people to support development (Verbalog-Support-Development-Model.md).
///
/// Nothing here is verified or sent anywhere: a contribution unlocks nothing, so the supporter
/// status is simply what the person says. UserDefaults survives reinstalls on macOS (deleting
/// the app leaves its preferences), without the Keychain prompts a re-signed build would cause.
public struct SupportPolicy {
    public static let firstInvitation = 10
    public static let meetingsBetweenInvitations = 20
    public static let daysBetweenInvitations = 60

    private enum Key {
        static let counted = "support.countedMeetings"
        static let supporterSince = "support.supporterSince"
        static let promptsDisabled = "support.promptsDisabled"
        static let snoozedAtCount = "support.snoozedAtCount"
        static let snoozedOn = "support.snoozedOn"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Meetings finished since Verbalog was installed, even if deleted since.
    public var completedMeetings: Int { (defaults.stringArray(forKey: Key.counted) ?? []).count }
    public var isSupporter: Bool { defaults.object(forKey: Key.supporterSince) != nil }
    public var promptsDisabled: Bool { defaults.bool(forKey: Key.promptsDisabled) }

    /// Counts a finished meeting once, however often it's exported again. Returns whether
    /// this is a good moment for an invitation.
    @discardableResult
    public func meetingCompleted(_ id: String, now: Date = Date()) -> Bool {
        var counted = defaults.stringArray(forKey: Key.counted) ?? []
        guard !counted.contains(id) else { return false }
        counted.append(id)
        defaults.set(counted, forKey: Key.counted)
        return shouldInvite(now: now)
    }

    public func shouldInvite(now: Date = Date()) -> Bool {
        guard !isSupporter, !promptsDisabled else { return false }
        let count = completedMeetings
        guard let snoozedOn = defaults.object(forKey: Key.snoozedOn) as? Date else {
            return count >= Self.firstInvitation
        }
        let days = now.timeIntervalSince(snoozedOn) / 86_400
        // Whichever comes first. Asked only right after a meeting (see meetingCompleted), so
        // someone who stopped using Verbalog is never reminded.
        return count >= defaults.integer(forKey: Key.snoozedAtCount) + Self.meetingsBetweenInvitations
            || days >= Double(Self.daysBetweenInvitations)
    }

    /// "Maybe Later", and also after opening the payment page: no reminder right away.
    public func snooze(now: Date = Date()) {
        defaults.set(completedMeetings, forKey: Key.snoozedAtCount)
        defaults.set(now, forKey: Key.snoozedOn)
    }

    public func markSupporter(now: Date = Date()) {
        defaults.set(now, forKey: Key.supporterSince)
        defaults.set(true, forKey: Key.promptsDisabled)
    }

    public func disablePrompts() {
        defaults.set(true, forKey: Key.promptsDisabled)
    }
}
