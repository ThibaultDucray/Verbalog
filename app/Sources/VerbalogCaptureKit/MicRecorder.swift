// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import AudioToolbox

/// Microphone through AVAudioEngine, on a chosen input device.
final class MicRecorder {
    typealias Handler = (_ samples: [Int16], _ hostTime: TimeInterval, _ level: Float) -> Void

    private let engine = AVAudioEngine()
    private let deviceKey: String?
    private let handler: Handler
    private var observer: NSObjectProtocol?

    init(deviceKey: String?, handler: @escaping Handler) {
        self.deviceKey = deviceKey
        self.handler = handler
    }

    func start() throws {
        try configureAndRun()
        // Headsets come and go during meetings. Reattach and keep recording: the gap becomes silence.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.configureAndRun()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func configureAndRun() throws {
        let input = engine.inputNode
        if let deviceKey, let device = AudioDevices.device(forUIDOrName: deviceKey), let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr { throw CaptureError.deviceUnavailable(device.name) }
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
