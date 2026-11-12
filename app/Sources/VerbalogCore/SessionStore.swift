// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The per-meeting directory shared with the backend (verbalog/session.py defines the same layout).
public struct SessionStore: Sendable {
    public let root: URL

    public init(home: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment["VERBALOG_HOME"].map { URL(fileURLWithPath: $0) }
        let base = home ?? environment ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".verbalog")
        root = base.appendingPathComponent("sessions")
    }

    public var home: URL { root.deletingLastPathComponent() }

    /// Config paths under ~/.verbalog follow the home, as in verbalog/config.py.
    public func resolve(_ path: String) -> URL {
        if path == "~/.verbalog" { return home }
        if path.hasPrefix("~/.verbalog/") { return home.appendingPathComponent(String(path.dropFirst("~/.verbalog/".count))) }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    public func directory(_ id: String) -> URL {
        root.appendingPathComponent(id)
    }

    public func list() -> [SessionMeta] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return directories
            .compactMap { load(id: $0.lastPathComponent) }
            .sorted { $0.created_at > $1.created_at }
    }

    public func load(id: String) -> SessionMeta? {
        guard let data = try? Data(contentsOf: directory(id).appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder().decode(SessionMeta.self, from: data)
    }

    public func create(title: String, mode: MeetingMode, headset: Bool, roomCount: Int?, remoteCount: Int?, participants: [String], languages: [String] = [], micDevice: String?, systemSource: String?, now: Date = Date()) throws -> SessionMeta {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let base = "\(formatter.string(from: now))_\(Self.slug(title))"
        var id = base
        var suffix = 1
        while FileManager.default.fileExists(atPath: directory(id).path) {
            suffix += 1
            id = "\(base)-\(suffix)"
        }
        try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        var fields: [String: Any] = [
            "id": id,
            "title": title,
            "created_at": iso.string(from: now),
            "mode": mode.rawValue,
            "headset": headset,
            "participants": participants,
            "status": SessionStatus.recording.rawValue,
            "warnings": [String](),
            "outputs": [String: String](),
        ]
        fields["room_count"] = roomCount ?? NSNull()
        fields["remote_count"] = remoteCount ?? NSNull()
        fields["mic_device"] = micDevice ?? NSNull()
        fields["system_source"] = systemSource ?? NSNull()
        fields["languages"] = MeetingLanguage.normalized(languages)
        try write(fields, id: id)
        guard let meta = load(id: id) else { throw CocoaError(.fileReadCorruptFile) }
        return meta
    }

    /// Merged into the raw JSON rather than through the Codable model, so that fields the backend owns survive.
    public func update(id: String, _ changes: [String: Any]) throws {
        let url = directory(id).appendingPathComponent("session.json")
        var fields = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        fields.merge(changes) { _, new in new }
        try write(fields, id: id)
    }

    private func write(_ fields: [String: Any], id: String) throws {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory(id).appendingPathComponent("session.json"), options: .atomic)
    }

    public func transcript(id: String) -> Transcript? {
        guard let data = try? Data(contentsOf: directory(id).appendingPathComponent("transcript.json")) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    public func liveSegments(id: String) -> [LiveSegment] {
        guard let text = try? String(contentsOf: directory(id).appendingPathComponent("live.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(LiveSegment.self, from: Data($0.utf8)) }
    }

    /// Edits the backend can still undo (verbalog/edit.py).
    public func canUndo(id: String) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory(id).appendingPathComponent("undo").path)) ?? []
        return files.contains { $0.hasSuffix(".json") }
    }

    public func audioURL(id: String, track: String) -> URL {
        directory(id).appendingPathComponent(track == "system" ? "system.wav" : "mic.wav")
    }

    public func hasAudio(id: String) -> Bool {
        ["mic", "system"].contains { FileManager.default.fileExists(atPath: audioURL(id: id, track: $0).path) }
    }

    /// Sessions a crash or forced quit left mid-flight: their audio is intact, so they go back to "ready to process".
    public func recoverInterrupted(activeIDs: Set<String>) {
        for session in list() where !activeIDs.contains(session.id) {
            guard session.status == .recording || session.status == .processing else { continue }
            var warnings = session.warnings ?? []
            warnings.append(session.status == .recording
                ? L("Recording interrupted: the audio captured so far was kept.")
                : L("Processing interrupted: you can start it again."))
            try? update(id: session.id, ["status": SessionStatus.recorded.rawValue, "warnings": warnings])
        }
    }

    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
        let parts = cleaned.split(separator: "-").joined(separator: "-")
        return parts.isEmpty ? "reunion" : String(parts.prefix(60))
    }
}

/// Appends one note per line and syncs it, so a crash can't lose a note already validated.
public final class NotesFile {
    private let handle: FileHandle

    public init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public func append(t: Double, text: String, epochMs: Int64) throws {
        let line = try JSONSerialization.data(withJSONObject: ["t": (t * 1000).rounded() / 1000, "text": text, "epoch_ms": epochMs])
        try handle.write(contentsOf: line + Data("\n".utf8))
        try handle.synchronize()
    }
}

extension Array where Element == String {
    /// "Sophie, Marc ; Jim" -> the list of names.
    public static func participants(from text: String) -> [String] {
        text.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
