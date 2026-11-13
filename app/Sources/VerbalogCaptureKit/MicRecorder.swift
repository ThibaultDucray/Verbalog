// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import CoreAudio

/// Microphone straight from the device's Core Audio I/O, on a chosen input, or else the
/// system's default.
///
/// Call apps make microphones misbehave: answering a WhatsApp call with a Bluetooth headset
/// switches it to call mode, after which AVAudioEngine either recorded digital silence or
/// blocked for the whole call while reconnecting. So the device is opened directly, every
/// Core Audio call runs off the main thread, and a reconnection that hangs is abandoned for a
/// fresh one rather than waited for. If the headset still delivers nothing, the caller can
/// switch to the Mac's built-in microphone.
final class MicRecorder: @unchecked Sendable {
    typealias Handler = (_ samples: [Int16], _ hostTime: TimeInterval, _ level: Float) -> Void

    private let deviceKey: String?
    private let handler: Handler
    private let lock = NSLock()
    private let events = DispatchQueue(label: "verbalog.mic.events")
    private var input: DeviceInput?
    private var generation = 0
    private var stopped = false
    private var usesBuiltIn = false
    private var restartPending = false
    private var lastOpened: TimeInterval = 0
    private var lastListenerRestart: TimeInterval = 0
    private var defaultListener: AudioObjectPropertyListenerBlock?

    /// Called when the mic couldn't be reattached after several tries.
    var onFailure: ((Error) -> Void)?

    init(deviceKey: String?, handler: @escaping Handler) {
        self.deviceKey = deviceKey
        self.handler = handler
    }

    /// Whether the Mac's built-in microphone exists and isn't already the one recording.
    var canFallBack: Bool {
        guard let builtIn = AudioDevices.builtInInput() else { return false }
        return lock.withLock { !usesBuiltIn && input?.id != builtIn.id }
    }

    /// Throws only when there's no usable microphone at all. A device that takes too long to
    /// answer doesn't hold the meeting up: the caller's watchdog sees no audio and restarts it.
    func start() async throws {
        if deviceKey == nil { listenToDefaultInput() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.connect(generation: 0)
                    once.run { continuation.resume() }
                } catch {
                    once.run { continuation.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                once.run { continuation.resume() }
            }
        }
    }

    /// Reopens the microphone from any thread, never blocking it. With `builtIn`, records from
    /// the Mac's own microphone for the rest of the meeting.
    func restart(builtIn: Bool = false) {
        let state: (Int, DeviceInput?)? = lock.withLock {
            guard !stopped else { return nil }
            if builtIn { usesBuiltIn = true }
            generation += 1
            defer { input = nil }
            return (generation, input)
        }
        guard let (current, old) = state else { return }
        // Closing the old device can block too: never on the path that opens the new one.
        if let old { DispatchQueue.global(qos: .utility).async { old.stop() } }
        DispatchQueue.global(qos: .userInitiated).async { self.attempt(current, remaining: 10) }
    }

    func stop() {
        let old: DeviceInput? = lock.withLock {
            stopped = true
            generation += 1
            defer { input = nil }
            return input
        }
        if let defaultListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, events, defaultListener)
        }
        if let old { DispatchQueue.global(qos: .utility).async { old.stop() } }
    }

    /// The device can refuse to open for a moment while it switches mode: try again shortly.
    private func attempt(_ current: Int, remaining: Int) {
        guard lock.withLock({ !stopped && current == generation }) else { return }
        do {
            try connect(generation: current)
        } catch {
            if remaining > 0 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                    self.attempt(current, remaining: remaining - 1)
                }
            } else if lock.withLock({ !stopped && current == generation }) {
                onFailure?(error)
            }
        }
    }

    private func connect(generation current: Int) throws {
        let (id, name) = try target()
        let opened = try DeviceInput(id: id, name: name, handler: handler) { [weak self] in
            self?.scheduleRestart()
        }
        let stale: Bool = lock.withLock {
            guard !stopped, current == generation else { return true }
            input = opened
            lastOpened = ProcessInfo.processInfo.systemUptime
            return false
        }
        // A newer attempt replaced this one while it was opening.
        if stale { opened.stop() }
    }

    private func target() throws -> (AudioDeviceID, String) {
        if lock.withLock({ usesBuiltIn }), let builtIn = AudioDevices.builtInInput() {
            return (builtIn.id, builtIn.name)
        }
        // A chosen headset that's been unplugged: the default still hears the room.
        if let deviceKey, let chosen = AudioDevices.device(forUIDOrName: deviceKey) {
            return (chosen.id, chosen.name)
        }
        guard let id = AudioDevices.defaultInputID() else { throw CaptureError.noMicrophone }
        return (id, AudioDevices.name(id))
    }

    /// Device changes come in bursts, and opening a Bluetooth headset's mic changes the headset
    /// itself: ignore what follows an opening, and reopen at most every few seconds. Otherwise
    /// each reopening causes the next, and the headset keeps switching modes.
    private func scheduleRestart() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay: Double? = lock.withLock {
            guard !stopped, !restartPending, now - lastOpened >= 2 else { return nil }
            restartPending = true
            return max(0.5, lastListenerRestart + 5 - now)
        }
        guard let delay else { return }
        events.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.restartPending = false
                self.lastListenerRestart = ProcessInfo.processInfo.systemUptime
            }
            self.restart()
        }
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Without a chosen device, follow the default: a headset connecting, or a call switching it.
    private func listenToDefaultInput() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.lock.withLock({ self.usesBuiltIn }) else { return }
            self.scheduleRestart()
        }
        var address = Self.defaultInputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, events, block) == noErr {
            defaultListener = block
        }
    }
}

/// One open input device: its I/O callback, and the listeners that say it changed.
private final class DeviceInput: @unchecked Sendable {
    let id: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "verbalog.mic.input", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "verbalog.mic.listeners")
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(id: AudioDeviceID, name: String, handler: @escaping MicRecorder.Handler, onChange: @escaping () -> Void) throws {
        self.id = id
        guard var description = AudioDevices.inputFormat(id), description.mSampleRate > 0, description.mChannelsPerFrame > 0 else {
            throw CaptureError.noMicrophone
        }
        // Separate channels arrive as separate buffers: the first one is enough for a voice.
        if description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            description.mChannelsPerFrame = 1
        }
        let bytesPerFrame = Int(description.mBytesPerFrame)
        guard
            bytesPerFrame > 0,
            let format = AVAudioFormat(streamDescription: &description),
            let converter = PCMConverter(from: format)
        else { throw CaptureError.unsupportedFormat }

        let queue = self.queue
        var proc: AudioDeviceIOProcID?
        // The callback runs on Core Audio's real-time thread: copy the samples and leave.
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, inputData, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = buffers.first, let data = first.mData, Int(first.mDataByteSize) >= bytesPerFrame else { return }
            let bytes = Data(bytes: data, count: Int(first.mDataByteSize))
            let stamp = inputTime.pointee
            let host = stamp.mFlags.contains(.hostTimeValid)
                ? AVAudioTime.seconds(forHostTime: stamp.mHostTime)
                : ProcessInfo.processInfo.systemUptime
            queue.async {
                let frames = AVAudioFrameCount(bytes.count / bytesPerFrame)
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                pcm.frameLength = frames
                let target = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                guard let destination = target[0].mData else { return }
                bytes.withUnsafeBytes { raw in
                    if let source = raw.baseAddress { memcpy(destination, source, Int(frames) * bytesPerFrame) }
                }
                if let result = converter.convert(pcm) {
                    handler(result.samples, host, result.level)
                }
            }
        }
        guard status == noErr, let proc else { throw CaptureError.deviceUnavailable(name) }
        status = AudioDeviceStart(id, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(id, proc)
            throw CaptureError.deviceUnavailable(name)
        }
        procID = proc

        // Unplugged, or reconfigured by a call: reopen it, or whatever is the default now.
        let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        for (selector, scope) in watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            if AudioObjectAddPropertyListenerBlock(id, &address, listenerQueue, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    func stop() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, listenerQueue, block)
        }
        listeners = []
        guard let procID else { return }
        self.procID = nil
        AudioDeviceStop(id, procID)
        AudioDeviceDestroyIOProcID(id, procID)
    }
}

/// Runs its closure the first time only, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
