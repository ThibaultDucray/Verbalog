// SPDX-FileCopyrightText: 2026 Thibault Ducray
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Streams 16-bit mono 16 kHz PCM to disk. The header is refreshed about once a second,
/// so a crash loses at most that much metadata and the file stays readable.
public final class WavWriter {
    public static let sampleRate = 16_000
    public static let headerSize = 44

    private let handle: FileHandle
    private var dataBytes = 0
    private var bytesSinceHeader = 0

    public private(set) var samplesWritten = 0

    public init(url: URL) throws {
        // Owner-only from creation: this is a recording of a private conversation.
        guard FileManager.default.createFile(
            atPath: url.path, contents: Self.header(dataBytes: 0), attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        let byteCount = samples.count * MemoryLayout<Int16>.size
        try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: byteCount, deallocator: .none))
        dataBytes += byteCount
        samplesWritten += samples.count
        bytesSinceHeader += byteCount
        if bytesSinceHeader >= Self.sampleRate * 2 {
            try refreshHeader()
        }
    }

    public func appendSilence(samples: Int) throws {
        guard samples > 0 else { return }
        let zeros = [Int16](repeating: 0, count: samples)
        try zeros.withUnsafeBufferPointer { try append($0) }
    }

    public func close() throws {
        try refreshHeader()
        try handle.synchronize()
        try handle.close()
    }

    private func refreshHeader() throws {
        bytesSinceHeader = 0
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes))
        try handle.seek(toOffset: end)
    }

    static func header(dataBytes: Int) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        put(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16))
        put(UInt16(1))
        put(UInt16(1))
        put(UInt32(sampleRate))
        put(UInt32(sampleRate * 2))
        put(UInt16(2))
        put(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        put(UInt32(dataBytes))
        return data
    }
}
