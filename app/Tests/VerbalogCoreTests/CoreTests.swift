import Foundation
import XCTest
@testable import VerbalogCore

final class CoreTests: XCTestCase {
    override func setUp() {
        // The backend client keeps a log under the home: never the user's real one.
        setenv("VERBALOG_HOME", FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path, 1)
    }

    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSelectionBecomesCodePointOffsets() {
        let turn = Turn(start: 0, end: 1, label: "A", track: "mic", lang: "en", text: "😀 hello world")
        // The emoji is two UTF-16 units but one code point, as Python counts.
        let offsets = turn.scalarOffsets(of: NSRange(location: 3, length: 5))
        XCTAssertEqual(offsets?.from, 2)
        XCTAssertEqual(offsets?.to, 7)
        XCTAssertNil(turn.scalarOffsets(of: NSRange(location: 3, length: 0)))
    }

    func testNoteClassification() {
        let patterns = ["ici c'est {nom}", "{nom} speaking"]
        XCTAssertEqual(NoteKind.classify("", namingPatterns: patterns), .bookmark)
        XCTAssertEqual(NoteKind.classify("! envoyer"), .action)
        XCTAssertEqual(NoteKind.classify("# ok"), .decision)
        XCTAssertEqual(NoteKind.classify("? pourquoi"), .question)
        XCTAssertEqual(NoteKind.classify("~ perso"), .private)
        XCTAssertEqual(NoteKind.classify("@Jim+"), .speaker)
        XCTAssertEqual(NoteKind.classify("ici c’est Jim", namingPatterns: patterns), .speaker)
        XCTAssertEqual(NoteKind.classify("Jim speaking.", namingPatterns: patterns), .speaker)
        XCTAssertEqual(NoteKind.classify("le budget est validé", namingPatterns: patterns), .note)
    }

    func testCreateSessionUpdatesKeepUnknownFields() throws {
        let store = SessionStore(home: tempHome())
        let meta = try store.create(title: "Comité : été", mode: .hybride, headset: false, roomCount: 4, remoteCount: nil, participants: ["Jim"], micDevice: nil, systemSource: nil)
        XCTAssertTrue(meta.id.hasSuffix("_comite-ete"), meta.id)
        XCTAssertEqual(meta.status, .recording)
        XCTAssertEqual(meta.room_count, 4)
        XCTAssertNil(meta.remote_count)

        // A field only the backend knows about must survive an update from the app.
        let file = store.directory(meta.id).appendingPathComponent("session.json")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        raw["future_field"] = 42
        try JSONSerialization.data(withJSONObject: raw).write(to: file)
        try store.update(id: meta.id, ["title": "Nouveau"])
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(after["future_field"] as? Int, 42)
        XCTAssertEqual(store.load(id: meta.id)?.title, "Nouveau")
    }

    func testDirectoryPermissionsAndUniqueIDs() throws {
        let store = SessionStore(home: tempHome())
        let date = Date()
        let first = try store.create(title: "X", mode: .visio, headset: true, roomCount: nil, remoteCount: nil, participants: [], micDevice: nil, systemSource: nil, now: date)
        let second = try store.create(title: "X", mode: .visio, headset: true, roomCount: nil, remoteCount: nil, participants: [], micDevice: nil, systemSource: nil, now: date)
        XCTAssertNotEqual(first.id, second.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory(first.id).path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    func testRecoverInterruptedSessions() throws {
        let store = SessionStore(home: tempHome())
        let dead = try store.create(title: "Mort", mode: .visio, headset: true, roomCount: nil, remoteCount: nil, participants: [], micDevice: nil, systemSource: nil)
        let alive = try store.create(title: "Vivant", mode: .visio, headset: true, roomCount: nil, remoteCount: nil, participants: [], micDevice: nil, systemSource: nil)
        store.recoverInterrupted(activeIDs: [alive.id])
        XCTAssertEqual(store.load(id: dead.id)?.status, .recorded)
        XCTAssertEqual(store.load(id: dead.id)?.warnings?.count, 1)
        XCTAssertEqual(store.load(id: alive.id)?.status, .recording)
    }

    func testNotesAreOnePerLine() throws {
        let url = tempHome().appendingPathComponent("notes.jsonl")
        let notes = try NotesFile(url: url)
        try notes.append(t: 1.23456, text: "! été", epochMs: 1)
        try notes.append(t: 2, text: "", epochMs: 2)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(first["t"] as? Double, 1.235)
        XCTAssertEqual(first["text"] as? String, "! été")
    }

    func testLineBufferHandlesSplitChunks() {
        var buffer = LineBuffer()
        XCTAssertTrue(buffer.feed(Data("{\"a\":".utf8)).isEmpty)
        let lines = buffer.feed(Data("1}\n{\"b\":2}\n{\"c".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
    }

    func testConfigPathsFollowTheHome() {
        let home = tempHome()
        let store = SessionStore(home: home)
        XCTAssertEqual(store.resolve("~/.verbalog/sensitive.txt").path, home.appendingPathComponent("sensitive.txt").path)
        XCTAssertEqual(store.resolve("/tmp/x.txt").path, "/tmp/x.txt")
        XCTAssertTrue(store.resolve("~/Verbalog").path.hasSuffix("/Verbalog"))
    }

    func testBackendEventParsing() {
        XCTAssertEqual(BackendEvent(line: Data(#"{"event":"progress","fraction":0.5}"#.utf8))?.name, "progress")
        XCTAssertNil(BackendEvent(line: Data("100%|████".utf8)))
    }

    func testParticipantsParsing() {
        XCTAssertEqual([String].participants(from: "Sophie, Marc ;Jim\n Karim,,"), ["Sophie", "Marc", "Jim", "Karim"])
    }

    private func sampleTranscript() throws -> Transcript {
        let json = """
        {"title":"T","date":"2026-11-04T14:00:00+01:00","duration":60,"context":"visio","languages":["fr"],
         "speakers":{"A":{"name":"Jim","display":"Jim","track":"mic","origin":"","talk_seconds":5,"source":"hint","samples":[]}},
         "turns":[{"start":5,"end":8,"label":"A","track":"mic","lang":"fr","text":"Un","words":[{"w":"Un","start":5,"end":6,"conf":0.9,"lang":"fr"}],"confidence":0.9},
                  {"start":10,"end":12,"label":"A","track":"mic","lang":"fr","text":"Deux","words":[],"confidence":0.9}],
         "notes":[{"t":1,"type":"note","text":"avant"},{"t":6,"type":"action","text":"faire"},{"t":7,"type":"speaker","text":"","speaker":"Jim"},{"t":9,"type":"private","text":"secret"}],
         "conflicts":[],"warnings":[],"dedup_removed":[],"needs_review":false,"version":1}
        """
        return try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
    }

    func testItemsInterleaveLikeTheExport() throws {
        let items = try sampleTranscript().items
        let order = items.map { item -> String in
            switch item {
            case .turn(let turn): turn.text
            case .note(let note): note.text
            }
        }
        XCTAssertEqual(order, ["avant", "Un", "faire", "secret", "Deux"])
    }

    func testPlainTextExportOmitsPrivateNotes() throws {
        let text = try sampleTranscript().plainText
        XCTAssertTrue(text.contains("[00:00:05] Jim: Un"))
        XCTAssertTrue(text.contains("ACTION [00:00:06] faire"))
        XCTAssertFalse(text.contains("secret"))
    }

    func testBackendDoesNotHangOnChildHoldingStdoutOpen() async throws {
        let root = tempHome()
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try """
        #!/bin/bash
        echo '{"event":"result","done":true}'
        sleep 8 &
        exit 0
        """.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let started = Date()
        let result = try await BackendClient(root: root).run(["ok"])
        XCTAssertEqual(result["done"] as? Bool, true)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 1.5, "should give stdout a chance to close")
        XCTAssertLessThan(elapsed, 6, "should not wait for the child")
    }

    func testBackendRunsRealProcessAndReportsErrors() async throws {
        // A fake interpreter proves the protocol: events parsed, junk ignored, error surfaced.
        let root = tempHome()
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try """
        #!/bin/bash
        input=$(cat)
        echo 'not json'
        echo '{"event":"progress","fraction":0.5}'
        echo "log noise" >&2
        if [ "$3" = "boom" ]; then echo '{"event":"error","message":"Échec"}'; exit 1; fi
        echo "{\\"event\\":\\"result\\",\\"echo\\":\\"$input\\"}"
        """.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let client = BackendClient(root: root)
        let counter = Counter()
        let result = try await client.run(["ok"], stdin: "bonjour") { event in
            if event.name == "progress" { counter.increment() }
        }
        XCTAssertEqual(result["echo"] as? String, "bonjour")
        XCTAssertEqual(counter.value, 1)

        do {
            _ = try await client.run(["boom"])
            XCTFail("should throw")
        } catch let error as BackendError {
            XCTAssertEqual(error.message, "Échec")
        }
    }

    func testBundledBackendInstallsOnceAndAgainAfterALockChange() async throws {
        let root = tempHome()
        let backend = root.appendingPathComponent("App/Resources/backend")
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        try "lock v1".write(to: backend.appendingPathComponent("uv.lock"), atomically: true, encoding: .utf8)
        // Stands in for `uv sync`: creates the environment it's pointed at.
        let uv = root.appendingPathComponent("App/Helpers/uv")
        try FileManager.default.createDirectory(at: uv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/bash
        mkdir -p "$UV_PROJECT_ENVIRONMENT/bin"
        printf '#!/bin/bash\\n' > "$UV_PROJECT_ENVIRONMENT/bin/python"
        chmod +x "$UV_PROJECT_ENVIRONMENT/bin/python"
        echo "installed $*"
        """.write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)

        let support = root.appendingPathComponent("Support")
        let layout = BackendLayout.bundled(backend: backend, uv: uv, support: support, caches: root.appendingPathComponent("Caches"))
        XCTAssertFalse(BackendClient(layout: layout).isInstalled)

        let lines = LinesBox()
        try await BackendClient(layout: layout).install { lines.append($0) }
        XCTAssertTrue(BackendClient(layout: layout).isInstalled)
        XCTAssertTrue(lines.text.contains("sync --frozen"), lines.text)

        // An update ships another lock: same environment, but it must be installed again.
        try "lock v2".write(to: backend.appendingPathComponent("uv.lock"), atomically: true, encoding: .utf8)
        let updated = BackendLayout.bundled(backend: backend, uv: uv, support: support, caches: root.appendingPathComponent("Caches"))
        XCTAssertFalse(BackendClient(layout: updated).isInstalled)
        XCTAssertTrue(BackendClient(layout: updated).needsUpdate)
        XCTAssertEqual(updated.environment["PYTHONPATH"], backend.path)
    }

    func testSupportInvitationFollowsTheModel() throws {
        let suite = "verbalog.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = SupportPolicy(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // Nothing before the tenth meeting, and a meeting exported twice counts once.
        for index in 1...9 { XCTAssertFalse(policy.meetingCompleted("m\(index)", now: start)) }
        XCTAssertFalse(policy.meetingCompleted("m9", now: start))
        XCTAssertTrue(policy.meetingCompleted("m10", now: start))

        // Maybe Later: 20 more meetings, or 60 days, whichever comes first.
        policy.snooze(now: start)
        for index in 11...29 { XCTAssertFalse(policy.meetingCompleted("m\(index)", now: start)) }
        XCTAssertTrue(policy.meetingCompleted("m30", now: start))
        policy.snooze(now: start)
        XCTAssertFalse(policy.meetingCompleted("m31", now: start.addingTimeInterval(59 * 86_400)))
        XCTAssertTrue(policy.meetingCompleted("m32", now: start.addingTimeInterval(60 * 86_400)))

        // A supporter, or someone who said no, is never asked again.
        policy.markSupporter(now: start)
        XCTAssertTrue(policy.isSupporter)
        XCTAssertFalse(policy.meetingCompleted("m100", now: start.addingTimeInterval(400 * 86_400)))

        let other = SupportPolicy(defaults: defaults)
        defaults.removeObject(forKey: "support.supporterSince")
        XCTAssertFalse(other.isSupporter)
        XCTAssertFalse(other.meetingCompleted("m101", now: start.addingTimeInterval(400 * 86_400)), "prompts stay disabled")
    }

    func testCancellingTheTaskStopsTheProcess() async throws {
        let root = tempHome()
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try "#!/bin/bash\nsleep 30\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let client = BackendClient(root: root)
        let started = Date()
        let task = Task { try await client.run(["x"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

private final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
