// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A localized string for contexts typed String. SwiftUI views look their literals up by themselves.
/// English is the source language; translations are in app/Resources.
public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

public enum MeetingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case visio, presentiel, hybride

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .visio: L("Video Call")
        case .presentiel: L("In Person")
        case .hybride: L("Hybrid")
        }
    }

    public var summary: String {
        switch self {
        case .visio: L("Just me on my side")
        case .presentiel: L("Everyone in the room")
        case .hybride: L("Room + remote participants")
        }
    }

    public var capturesSystem: Bool { self != .presentiel }
}

/// Languages a meeting can be transcribed in, as Whisper names them (verbalog/transcribe.py).
public enum MeetingLanguage: String, CaseIterable, Identifiable, Sendable {
    case fr, en, de, nl, es, it, pt

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fr: L("French")
        case .en: L("English")
        case .de: L("German")
        case .nl: L("Dutch")
        case .es: L("Spanish")
        case .it: L("Italian")
        case .pt: L("Portuguese")
        }
    }

    /// Supported codes in display order; French and English when none, as the backend does.
    public static func normalized(_ codes: [String]) -> [String] {
        let chosen = allCases.map(\.rawValue).filter(codes.contains)
        return chosen.isEmpty ? [MeetingLanguage.fr.rawValue, MeetingLanguage.en.rawValue] : chosen
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case recording, recorded, processing, review, done, failed
}

public struct SessionOutputs: Codable, Hashable, Sendable {
    public var md: String?
    public var json: String?
    public var summary: String?
}

public struct SessionMeta: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var created_at: String
    public var mode: MeetingMode
    public var headset: Bool?
    public var room_count: Int?
    public var remote_count: Int?
    public var participants: [String]?
    public var languages: [String]?
    /// Made from an audio file rather than recorded in Verbalog.
    public var imported: Bool?
    public var status: SessionStatus
    public var error: String?
    public var warnings: [String]?
    public var outputs: SessionOutputs?
    public var duration: Double?
    public var coverage: Double?

    public var createdDate: Date? {
        ISO8601DateFormatter.withTimeZone.date(from: created_at)
    }
}

extension ISO8601DateFormatter {
    fileprivate static let withTimeZone: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

public struct SpeakerSample: Codable, Hashable, Sendable {
    public var t: Double
    public var end: Double?
    public var track: String?
    public var text: String
}

public struct Speaker: Codable, Hashable, Sendable {
    public var name: String?
    public var display: String
    public var track: String
    public var origin: String?
    public var talk_seconds: Double
    public var source: String?
    public var samples: [SpeakerSample]
}

public struct Turn: Codable, Hashable, Identifiable, Sendable {
    public var start: Double
    public var end: Double
    public var label: String
    public var track: String
    public var lang: String?
    public var text: String
    public var id: String { "\(track)-\(start)-\(label)" }

    /// A text view selection as code points, which is what the backend counts.
    public func scalarOffsets(of selection: NSRange) -> (from: Int, to: Int)? {
        guard selection.length > 0, let range = Range(selection, in: text) else { return nil }
        let scalars = text.unicodeScalars
        return (
            scalars.distance(from: scalars.startIndex, to: range.lowerBound),
            scalars.distance(from: scalars.startIndex, to: range.upperBound)
        )
    }
}

public struct TranscriptNote: Codable, Hashable, Identifiable, Sendable {
    public var t: Double
    public var type: String
    public var text: String
    public var speaker: String?
    public var id: String { "\(t)-\(type)-\(text)" }

    public var kind: NoteKind { NoteKind(rawValue: type) ?? .note }
}

public struct SpeakerConflict: Codable, Hashable, Sendable {
    public var kind: String
    public var t: Double
    public var name: String
    public var labels: [String]
    public var previous: String?
}

public struct Transcript: Codable, Sendable {
    public var title: String
    public var date: String
    public var duration: Double
    public var context: String
    public var languages: [String]
    public var expected_participants: [String]?
    public var speakers: [String: Speaker]
    public var turns: [Turn]
    public var notes: [TranscriptNote]
    public var conflicts: [SpeakerConflict]?
    public var warnings: [String]?
}

public struct LiveSegment: Codable, Hashable, Identifiable, Sendable {
    public var track: String
    public var start: Double
    public var end: Double
    public var text: String
    public var lang: String?
    public var id: String { "\(track)-\(start)" }

    public init(track: String, start: Double, end: Double, text: String, lang: String?) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.lang = lang
    }
}

public enum NoteKind: String, Sendable {
    case note, action, decision, question, speaker, `private`, bookmark

    public var title: String {
        switch self {
        case .note: L("Note")
        case .action: L("Action")
        case .decision: L("Decision")
        case .question: L("Question")
        case .speaker: L("Speaker")
        case .private: L("Private")
        case .bookmark: L("Bookmark")
        }
    }

    /// Display-only classification while typing. The backend's parser is authoritative at processing time.
    public static func classify(_ raw: String, namingPatterns: [String] = []) -> NoteKind {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return .bookmark }
        switch first {
        case "!": return .action
        case "#": return .decision
        case "?": return .question
        case "~": return .private
        case "@": return text.count > 1 ? .speaker : .note
        default: break
        }
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        for pattern in namingPatterns {
            let escaped = NSRegularExpression.escapedPattern(for: pattern.replacingOccurrences(of: "’", with: "'"))
                .replacingOccurrences(of: "\\{nom\\}", with: "\\p{L}[\\p{L}' -]{0,39}")
            if normalized.range(of: "^\(escaped)[.!]?$", options: [.regularExpression, .caseInsensitive]) != nil {
                return .speaker
            }
        }
        return .note
    }
}

/// What the meeting view lists: speech with notes interleaved, as in the Markdown export.
public enum TranscriptItem: Identifiable, Hashable, Sendable {
    case turn(Turn)
    case note(TranscriptNote)

    public var id: String {
        switch self {
        case .turn(let turn): "t-\(turn.id)"
        case .note(let note): "n-\(note.id)"
        }
    }

    public var time: Double {
        switch self {
        case .turn(let turn): turn.start
        case .note(let note): note.t
        }
    }
}

extension Transcript {
    /// Same rule as the export: a note goes after the turn in progress at its timestamp. Consumed hints don't show.
    public var items: [TranscriptItem] {
        let sortedTurns = turns.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var followers: [Int: [TranscriptNote]] = [:]
        for note in notes.sorted(by: { $0.t < $1.t }) where note.kind != .speaker {
            var position = -1
            for (index, turn) in sortedTurns.enumerated() {
                if turn.start <= note.t { position = index } else { break }
            }
            followers[position, default: []].append(note)
        }
        var items: [TranscriptItem] = (followers[-1] ?? []).map(TranscriptItem.note)
        for (index, turn) in sortedTurns.enumerated() {
            items.append(.turn(turn))
            items += (followers[index] ?? []).map(TranscriptItem.note)
        }
        return items
    }

    /// Plain-text export: same content as the Markdown, without the markup.
    public var plainText: String {
        var lines = [title, ""]
        for item in items {
            switch item {
            case .turn(let turn):
                lines.append("[\(TimeFormat.hms(turn.start))] \(speakers[turn.label]?.display ?? turn.label): \(turn.text)")
            case .note(let note):
                guard note.kind != .private else { continue }
                lines.append("  -- \(note.kind.title.uppercased()) [\(TimeFormat.hms(note.t))] \(note.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum TimeFormat {
    public static func hms(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    public static func minutes(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \(total % 3600 / 60) min"
    }
}

public struct DoctorReport: Sendable, Equatable {
    public var mlxWhisper = false
    public var whisperModel = ""
    public var whisperCached = false
    public var liveModel = ""
    public var liveCached = false
    public var pyannote = false
    public var diarizationModel = ""
    public var diarizationCached = false
    public var hfToken = false
    public var ner = false
    public var fileVault: Bool?
    public var outputDir = ""
    public var outputDirCloudSynced = false
    public var userNameSet = false

    public init() {}

    public init(_ fields: [String: Any]) {
        mlxWhisper = fields["mlx_whisper"] as? Bool ?? false
        whisperModel = fields["whisper_model"] as? String ?? ""
        whisperCached = fields["whisper_cached"] as? Bool ?? false
        liveModel = fields["live_model"] as? String ?? ""
        liveCached = fields["live_cached"] as? Bool ?? false
        pyannote = fields["pyannote"] as? Bool ?? false
        diarizationModel = fields["diarization_model"] as? String ?? ""
        diarizationCached = fields["diarization_cached"] as? Bool ?? false
        hfToken = fields["hf_token"] as? Bool ?? false
        ner = fields["ner"] as? Bool ?? false
        fileVault = fields["filevault"] as? Bool
        outputDir = fields["output_dir"] as? String ?? ""
        outputDirCloudSynced = fields["output_dir_cloud_synced"] as? Bool ?? false
        userNameSet = fields["user_name_set"] as? Bool ?? false
    }

    public var canTranscribe: Bool { mlxWhisper && whisperCached }
    public var canDiarize: Bool { pyannote && diarizationCached }
}
