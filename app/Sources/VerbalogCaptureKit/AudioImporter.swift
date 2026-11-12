// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation

private func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

public enum ImportError: LocalizedError {
    case noAudio
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .noAudio: L("This file has no audio track.")
        case .unreadable(let reason): L("Can't read this file: \(reason)")
        }
    }
}

/// Turns any audio or video file macOS can read (WAV, M4A, MP3, AIFF, FLAC, MP4, MOV…) into the
/// 16 kHz mono WAV that recordings use, without ffmpeg. The source file is only read.
public enum AudioImporter {
    /// The file types to offer in an open panel.
    public static let contentTypes = ["public.audio", "public.movie"]

    /// Returns the duration in seconds.
    @discardableResult
    public static func convert(from source: URL, to destination: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ImportError.noAudio }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        // AVFoundation resamples and mixes down to mono itself.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: WavWriter.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImportError.unreadable(L("unsupported audio format")) }
        reader.add(output)
        if #available(macOS 26.0, *) {
            do {
                try reader.start()
            } catch {
                throw ImportError.unreadable(error.localizedDescription)
            }
        } else if !reader.startReading() {
            throw ImportError.unreadable(reader.error?.localizedDescription ?? L("unsupported audio format"))
        }

        let writer = try WavWriter(url: destination)
        do {
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                      let pointer, length == CMBlockBufferGetDataLength(block)
                else {
                    // Not contiguous: copy it out.
                    var bytes = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
                    _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                    try bytes.withUnsafeBufferPointer { try writer.append($0) }
                    continue
                }
                try pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) {
                    try writer.append(UnsafeBufferPointer(start: $0, count: length / 2))
                }
            }
            guard reader.status == .completed else {
                throw ImportError.unreadable(reader.error?.localizedDescription ?? L("reading stopped"))
            }
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }
        return Double(writer.samplesWritten) / Double(WavWriter.sampleRate)
    }
}
