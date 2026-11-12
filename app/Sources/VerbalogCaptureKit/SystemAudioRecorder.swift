// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

/// System audio through ScreenCaptureKit, for everything or for a single app.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias Handler = MicRecorder.Handler

    private let source: String?
    private let handler: Handler
    private let onFailure: (Error) -> Void
    private let queue = DispatchQueue(label: "verbalog.system-audio")
    private var stream: SCStream?
    private var converter: PCMConverter?
    private var converterFormat: AVAudioFormat?

    /// `source`: a bundle identifier, or nil for all system audio.
    init(source: String?, handler: @escaping Handler, onFailure: @escaping (Error) -> Void) {
        self.source = source
        self.handler = handler
        self.onFailure = onFailure
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.screenRecordingDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter: SCContentFilter
        if let source {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == source }) else {
                throw CaptureError.appNotRunning(source)
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // The API insists on video too: ask for the least it will accept.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        if converterFormat != pcm.format {
            converter = PCMConverter(from: pcm.format)
            converterFormat = pcm.format
        }
        // Presentation timestamps are on the host clock, the same one the mic's use.
        let host = sampleBuffer.presentationTimeStamp.seconds
        if let result = converter?.convert(pcm) {
            handler(result.samples, host, result.level)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure(error)
    }

    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
