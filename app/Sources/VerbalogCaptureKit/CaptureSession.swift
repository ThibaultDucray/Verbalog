// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation

private func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

public enum CaptureError: LocalizedError {
    case noMicrophone
    case microphoneDenied
    case deviceUnavailable(String)
    case unsupportedFormat
    case screenRecordingDenied
    case noDisplay
    case appNotRunning(String)

    public var errorDescription: String? {
        switch self {
        case .noMicrophone: L("No microphone available.")
        case .microphoneDenied: L("Microphone access denied: allow Verbalog in System Settings › Privacy & Security › Microphone.")
        case .deviceUnavailable(let name): L("The microphone “\(name)” isn't available.")
        case .unsupportedFormat: L("Unsupported microphone audio format.")
        case .screenRecordingDenied: L("System audio unavailable: allow Verbalog in System Settings › Privacy & Security › Screen & System Audio Recording.")
        case .noDisplay: L("No display found to capture system audio.")
        case .appNotRunning(let app): L("The app “\(app)” isn't running, so its audio can't be captured.")
        }
    }
}

public struct AudioLevels: Sendable, Equatable {
    public var mic: Float = -120
    public var system: Float = -120
    public init() {}
}

/// Records the two tracks against one clock. Without an output directory it only
/// measures levels, which is how the context screen tests the sources before a meeting.
public final class CaptureSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var directory: URL?
        public var micDevice: String?
        public var captureSystem = true
        public var systemSource: String?

        public init(directory: URL?, micDevice: String? = nil, captureSystem: Bool = true, systemSource: String? = nil) {
            self.directory = directory
            self.micDevice = micDevice
            self.captureSystem = captureSystem
            self.systemSource = systemSource
        }
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var mic: MicRecorder?
    private var system: SystemAudioRecorder?
    private var micTrack: AlignedTrack?
    private var systemTrack: AlignedTrack?
    private var paused = false
    private var micMuted = false
    private var stopped = false
    private var failure: Error?
    private var levels = AudioLevels()
    private var levelTimer: DispatchSourceTimer?
    private var startTime: TimeInterval = 0

    public var onLevels: (@Sendable (AudioLevels) -> Void)?
    /// Something went wrong mid-recording, on a track that keeps the session going without it.
    public var onWarning: (@Sendable (String) -> Void)?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// The session clock: seconds of audio timeline so far. Note timestamps come from here.
    public var elapsed: TimeInterval {
        ProcessInfo.processInfo.systemUptime - startTime
    }

    /// Returns the epoch in ms of timeline position zero, plus the system-audio error if
    /// that track couldn't start. A mic-only recording beats none, but the caller must say so.
    @discardableResult
    public func start() async throws -> (epochMs: Int64, systemError: Error?) {
        guard await Self.requestMicrophoneAccess() else { throw CaptureError.microphoneDenied }

        startTime = ProcessInfo.processInfo.systemUptime
        let epochMs = Int64(Date().timeIntervalSince1970 * 1000)

        if let directory = configuration.directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            micTrack = AlignedTrack(writer: try WavWriter(url: directory.appendingPathComponent("mic.wav")), startTime: startTime)
        }

        let micRecorder = MicRecorder(deviceKey: configuration.micDevice) { [weak self] samples, host, level in
            self?.receive(samples, host, level, isMic: true)
        }
        try micRecorder.start()
        mic = micRecorder

        let systemError = configuration.captureSystem ? await startSystem() : nil
        startLevelTimer()
        return (epochMs, systemError)
    }

    /// For a meeting that turns out to have remote participants: system audio joins the same
    /// timeline, so everything before this moment is silence on that track.
    public func addSystemAudio() async -> Error? {
        guard system == nil else { return nil }
        return await startSystem()
    }

    private func startSystem() async -> Error? {
        do {
            if let directory = configuration.directory, lock.withLock({ systemTrack == nil && !stopped }) {
                let track = AlignedTrack(writer: try WavWriter(url: directory.appendingPathComponent("system.wav")), startTime: startTime)
                lock.withLock { systemTrack = track }
            }
            let recorder = SystemAudioRecorder(source: configuration.systemSource, handler: { [weak self] samples, host, level in
                self?.receive(samples, host, level, isMic: false)
            }, onFailure: { [weak self] error in
                self?.onWarning?(L("System audio capture stopped: \(error.localizedDescription)"))
            })
            try await recorder.start()
            // The meeting may have ended while the capture was starting.
            if lock.withLock({ stopped }) {
                await recorder.stop()
            } else {
                system = recorder
            }
            return nil
        } catch {
            return error
        }
    }

    public func setPaused(_ value: Bool) {
        lock.withLock { paused = value }
    }

    /// Unlike a pause, only the mic stops: remote voices keep being recorded. The device stays
    /// open, so muting doesn't make a Bluetooth headset or a call change audio mode.
    public func setMicMuted(_ value: Bool) {
        lock.withLock { micMuted = value }
    }

    public func stop() async {
        lock.withLock { stopped = true }
        levelTimer?.cancel()
        levelTimer = nil
        mic?.stop()
        mic = nil
        await system?.stop()
        system = nil
        let end = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            try? micTrack?.finish(at: end)
            try? systemTrack?.finish(at: end)
            micTrack = nil
            systemTrack = nil
        }
    }

    private func receive(_ samples: [Int16], _ host: TimeInterval, _ level: Float, isMic: Bool) {
        var warning: String?
        lock.withLock {
            if isMic && micMuted { return }  // a skipped write becomes silence on the timeline
            if isMic { levels.mic = max(levels.mic, level) } else { levels.system = max(levels.system, level) }
            guard !paused else { return }
            do {
                try (isMic ? micTrack : systemTrack)?.write(samples, at: host)
            } catch {
                if failure == nil {
                    failure = error
                    warning = L("Can't write audio: \(error.localizedDescription)")
                }
            }
        }
        if let warning { onWarning?(warning) }
    }

    private func startLevelTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot = self.lock.withLock { () -> AudioLevels in
                let current = self.levels
                self.levels = AudioLevels()
                return current
            }
            self.onLevels?(snapshot)
        }
        timer.resume()
        levelTimer = timer
    }
}
