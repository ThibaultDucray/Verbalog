// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import AudioToolbox

/// Microphone through AVAudioEngine, on a chosen input device, or else the system's default.
final class MicRecorder {
    typealias Handler = (_ samples: [Int16], _ hostTime: TimeInterval, _ level: Float) -> Void

    private let engine = AVAudioEngine()
    private let deviceKey: String?
    private let handler: Handler
    private var observer: NSObjectProtocol?
    private var stopped = false
    private var attempt = 0

    /// Called on the main queue when the mic couldn't be reattached after several tries.
    var onFailure: ((Error) -> Void)?

    init(deviceKey: String?, handler: @escaping Handler) {
        self.deviceKey = deviceKey
        self.handler = handler
    }

    func start() throws {
        try configureAndRun()
        // Headsets come and go during meetings, and a call app starting switches a Bluetooth
        // headset to call mode, which changes its format. Reattach and keep recording: the gap
        // becomes silence.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
    }

    /// Also called when the mic stops delivering audio without telling anyone. Main queue only.
    func restart() {
        guard !stopped else { return }
        attempt += 1
        let current = attempt
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        retry(current, remaining: 20)
    }

    func stop() {
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The device can report no format for a moment while it switches mode: try again shortly.
    private func retry(_ current: Int, remaining: Int) {
        guard !stopped, current == attempt else { return }
        do {
            try configureAndRun()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.retry(current, remaining: remaining - 1)
                }
            } else {
                onFailure?(error)
            }
        }
    }

    private func configureAndRun() throws {
        let input = engine.inputNode
        // Without a chosen device, follow the current default explicitly: after a change the
        // engine can stay bound to a device that no longer delivers anything.
        let chosen = deviceKey.flatMap { AudioDevices.device(forUIDOrName: $0) }
        if let target = chosen?.id ?? AudioDevices.defaultInputID(), let unit = input.audioUnit {
            var id = target
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr, let chosen { throw CaptureError.deviceUnavailable(chosen.name) }
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        guard let converter = PCMConverter(from: format) else { throw CaptureError.unsupportedFormat }
        let handler = self.handler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            let host = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime
            if let result = converter.convert(buffer) {
                handler(result.samples, host, result.level)
            }
        }
        engine.prepare()
        try engine.start()
    }
}
