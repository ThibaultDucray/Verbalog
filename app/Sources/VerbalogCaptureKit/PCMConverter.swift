@preconcurrency import AVFoundation

/// Any input format to the tracks' 16 kHz mono, and its level.
final class PCMConverter {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat) {
        guard
            let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(WavWriter.sampleRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: output)
        else { return nil }
        converter.downmix = true
        self.output = output
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> (samples: [Int16], level: Float)? {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let channel = out.floatChannelData?[0] else { return nil }
        let count = Int(out.frameLength)
        var samples = [Int16](repeating: 0, count: count)
        var energy: Float = 0
        for index in 0..<count {
            let value = max(-1, min(1, channel[index]))
            samples[index] = Int16(value * 32767)
            energy += value * value
        }
        let rms = count > 0 ? (energy / Float(count)).squareRoot() : 0
        return (samples, 20 * log10(max(rms, 1e-6)))
    }
}
