// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

public struct BackendError: LocalizedError, Sendable {
    public var message: String
    public var kind: String?
    public var errorDescription: String? { message }
}

public struct BackendEvent: @unchecked Sendable {
    public let name: String
    public let fields: [String: Any]

    public init?(line: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let name = object["event"] as? String
        else { return nil }
        self.name = name
        fields = object
    }
}

/// Splits a byte stream into complete lines; pipes deliver arbitrary chunks.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }
}

/// Where the backend lives: a development checkout, or the copy shipped inside the app.
public struct BackendLayout: Sendable {
    public var python: URL
    public var workingDirectory: URL
    /// What the setup screen shows: the repository, or the folder holding Python and packages.
    public var location: URL
    public var environment: [String: String]
    public var installer: URL
    public var installArguments: [String]
    /// Release builds: the environment is installed from the uv.lock in the app, and must be
    /// installed again when an update ships a different one.
    public var lockDigest: String?
    public var installedMarker: URL?

    public var isBundled: Bool { installedMarker != nil }

    /// `.venv` in the repository, installed by `scripts/bootstrap.sh`.
    public static func development(root: URL) -> BackendLayout {
        BackendLayout(
            python: root.appendingPathComponent(".venv/bin/python"),
            workingDirectory: root,
            location: root,
            environment: [:],
            installer: URL(fileURLWithPath: "/bin/bash"),
            installArguments: [root.appendingPathComponent("scripts/bootstrap.sh").path]
        )
    }

    /// The `verbalog` code runs from the signed app; Python and the locked packages are
    /// installed by the bundled uv into `support`, on first launch. Nothing writes into the app.
    public static func bundled(backend: URL, uv: URL, support: URL, caches: URL) -> BackendLayout {
        let venv = support.appendingPathComponent("venv")
        let lock = (try? Data(contentsOf: backend.appendingPathComponent("uv.lock"))) ?? Data()
        return BackendLayout(
            python: venv.appendingPathComponent("bin/python"),
            workingDirectory: backend,
            location: support,
            environment: [
                "PYTHONPATH": backend.path,
                "PYTHONPYCACHEPREFIX": caches.appendingPathComponent("pycache").path,
                "PYTHONNOUSERSITE": "1",
                // Only the app's own Python and settings, whatever the user has installed.
                "UV_NO_CONFIG": "1",
                "UV_PYTHON_PREFERENCE": "only-managed",
                "UV_PYTHON_INSTALL_DIR": support.appendingPathComponent("python").path,
                "UV_PROJECT_ENVIRONMENT": venv.path,
                "UV_CACHE_DIR": caches.appendingPathComponent("uv").path,
            ],
            installer: uv,
            installArguments: [
                "sync", "--frozen", "--no-install-project", "--all-extras", "--no-dev", "--compile-bytecode",
                "--project", backend.path,
            ],
            lockDigest: SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined(),
            installedMarker: support.appendingPathComponent("installed-lock.sha256")
        )
    }

    var hasPython: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    var lockMatches: Bool {
        guard let installedMarker, let lockDigest else { return true }
        return (try? String(contentsOf: installedMarker, encoding: .utf8)) == lockDigest
    }
}

/// Runs the Python backend, one process per job. Exiting the process is what frees the models' memory.
public struct BackendClient: Sendable {
    public let layout: BackendLayout
    public let environment: [String: String]

    public init(layout: BackendLayout, environment: [String: String] = [:]) {
        self.layout = layout
        self.environment = environment
    }

    public init(root: URL, environment: [String: String] = [:]) {
        self.init(layout: .development(root: root), environment: environment)
    }

    public var python: URL { layout.python }

    public var isInstalled: Bool { layout.hasPython && layout.lockMatches }

    /// Installed, but from another version's packages: the app was updated.
    public var needsUpdate: Bool { layout.hasPython && !layout.lockMatches }

    /// Runs a job to completion and returns its `result` event. Cancelling the task terminates the process.
    public func run(
        _ arguments: [String],
        stdin: String? = nil,
        onEvent: (@Sendable (BackendEvent) -> Void)? = nil
    ) async throws -> [String: Any] {
        guard isInstalled else {
            throw BackendError(message: L("The Python backend isn't installed: install it from Status & Models."))
        }
        return try await launch(executable: python, arguments: ["-m", "verbalog"] + arguments, stdin: stdin, onEvent: onEvent)
    }

    /// For the setup screen: `uv sync` in a release, the repo's install script otherwise.
    /// Its output is plain log lines.
    public func install(onLine: @escaping @Sendable (String) -> Void) async throws {
        if let marker = layout.installedMarker {
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: marker)  // half an install isn't an install
        }
        _ = try await launch(executable: layout.installer, arguments: layout.installArguments, stdin: nil, onEvent: { event in
            if let line = event.fields["line"] as? String { onLine(line) }
        }, parseLines: false)
        if let marker = layout.installedMarker, let digest = layout.lockDigest {
            try digest.write(to: marker, atomically: true, encoding: .utf8)
        }
    }

    private func launch(
        executable: URL,
        arguments: [String],
        stdin: String?,
        onEvent: (@Sendable (BackendEvent) -> Void)?,
        parseLines: Bool = true
    ) async throws -> [String: Any] {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = layout.workingDirectory
        var env = ProcessInfo.processInfo.environment
        // An app launched from Finder has a minimal PATH, without Homebrew's uv.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONUNBUFFERED"] = "1"
        env.merge(layout.environment) { _, new in new }
        env.merge(environment) { _, new in new }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let input = Pipe()
        process.standardInput = input

        let state = JobState()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                state.stdoutClosed()
                return
            }
            for line in state.feed(chunk) {
                if parseLines {
                    guard let event = BackendEvent(line: line) else { continue }
                    state.record(event)
                    onEvent?(event)
                } else if let text = String(data: line, encoding: .utf8),
                          let event = BackendEvent(line: Data(#"{"event":"log"}"#.utf8)) {
                    onEvent?(BackendEvent.log(text, from: event))
                }
            }
        }
        // Always drained: a full stderr pipe would block the process.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                state.appendLog(chunk)
                if !parseLines, let text = String(data: chunk, encoding: .utf8),
                   let event = BackendEvent(line: Data(#"{"event":"log"}"#.utf8)) {
                    onEvent?(BackendEvent.log(text, from: event))
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    let killed = finished.terminationReason == .uncaughtSignal
                    state.whenStdoutClosed {
                        state.persistLog()
                        if let error = state.errorEvent {
                            continuation.resume(throwing: BackendError(message: error.fields["message"] as? String ?? L("Backend error"), kind: error.fields["kind"] as? String))
                        } else if let result = state.resultEvent {
                            continuation.resume(returning: result.fields)
                        } else if status == 0 {
                            continuation.resume(returning: [:])
                        } else if killed {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: BackendError(message: state.logTail ?? L("The backend stopped (code \(status)).")))
                        }
                    }
                }
                do {
                    try process.run()
                    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
                    try? input.fileHandleForWriting.close()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: BackendError(message: L("Can't start the backend: \(error.localizedDescription)")))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

extension BackendEvent {
    fileprivate static func log(_ text: String, from event: BackendEvent) -> BackendEvent {
        let payload = try? JSONSerialization.data(withJSONObject: ["event": "log", "line": text])
        return payload.flatMap(BackendEvent.init(line:)) ?? event
    }
}

private final class JobState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = LineBuffer()
    private var log = Data()
    private var stdoutIsClosed = false
    private var afterStdout: (@Sendable () -> Void)?
    private var result: BackendEvent?
    private var error: BackendEvent?

    func feed(_ chunk: Data) -> [Data] {
        lock.withLock { buffer.feed(chunk) }
    }

    func record(_ event: BackendEvent) {
        lock.withLock {
            if event.name == "result" { result = event }
            if event.name == "error" { error = event }
        }
    }

    func appendLog(_ chunk: Data) {
        lock.withLock {
            log.append(chunk)
            if log.count > 256_000 { log = Data(log.suffix(128_000)) }
        }
    }

    func stdoutClosed() {
        let action = lock.withLock {
            stdoutIsClosed = true
            return takeAfterStdout()
        }
        action?()
    }

    /// The process exiting doesn't mean its last events were read yet. A child that
    /// inherited the pipe can keep it open, so this doesn't wait for more than `timeout`.
    func whenStdoutClosed(timeout: TimeInterval = 2, _ action: @escaping @Sendable () -> Void) {
        let closed = lock.withLock {
            if !stdoutIsClosed { afterStdout = action }
            return stdoutIsClosed
        }
        guard !closed else { return action() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            self.lock.withLock { self.takeAfterStdout() }?()
        }
    }

    /// Call with the lock held. Whichever of closing and timeout comes first runs the action, once.
    private func takeAfterStdout() -> (@Sendable () -> Void)? {
        defer { afterStdout = nil }
        return afterStdout
    }

    var resultEvent: BackendEvent? { lock.withLock { result } }
    var errorEvent: BackendEvent? { lock.withLock { error } }

    var logTail: String? {
        lock.withLock {
            guard !log.isEmpty else { return nil }
            return String(decoding: log.suffix(1200), as: UTF8.self)
        }
    }

    func persistLog() {
        let home = ProcessInfo.processInfo.environment["VERBALOG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".verbalog")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let data = lock.withLock { log }
        guard !data.isEmpty else { return }
        try? data.write(to: home.appendingPathComponent("backend.log"))
    }
}
