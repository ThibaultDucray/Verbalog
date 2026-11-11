import Foundation

/// Keeps a track's file position locked to the session clock.
///
/// Each buffer lands at the position its host timestamp implies: gaps become silence
/// and repeated audio is trimmed. Both tracks therefore stay in sync with each other and
/// with the notes, even if a source starts late, stalls (ScreenCaptureKit stops delivering
/// when nothing plays), or is paused. A pause is simply a gap, so the timeline never shifts.
public final class AlignedTrack {
    /// Below this, timestamp jitter isn't worth correcting; inserting tiny gaps would click.
    static let toleranceSamples = WavWriter.sampleRate / 50

    private let writer: WavWriter
    private let startTime: TimeInterval

    public init(writer: WavWriter, startTime: TimeInterval) {
        self.writer = writer
        self.startTime = startTime
    }

    public var samplesWritten: Int { writer.samplesWritten }

    public func write(_ samples: [Int16], at hostTime: TimeInterval) throws {
        let expected = Int(((hostTime - startTime) * Double(WavWriter.sampleRate)).rounded())
        let drift = expected - writer.samplesWritten
        var dropCount = 0
        if drift > Self.toleranceSamples {
            try writer.appendSilence(samples: drift)
        } else if drift < -Self.toleranceSamples {
            dropCount = min(-drift, samples.count)
        }
        guard dropCount < samples.count else { return }
        try samples.withUnsafeBufferPointer { pointer in
            try writer.append(UnsafeBufferPointer(rebasing: pointer[dropCount...]))
        }
    }

    /// Pads to the session's end, so that both files have the same duration.
    public func finish(at hostTime: TimeInterval) throws {
        let expected = Int(((hostTime - startTime) * Double(WavWriter.sampleRate)).rounded())
        try writer.appendSilence(samples: expected - writer.samplesWritten)
        try writer.close()
    }
}
