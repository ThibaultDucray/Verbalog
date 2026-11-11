import Foundation
import XCTest
@testable import VerbalogCaptureKit

final class CaptureTests: XCTestCase {
    private func tempWav() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    }

    private func samples(of url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url).dropFirst(WavWriter.headerSize)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    func testHeaderAfterClose() throws {
        let url = tempWav()
        let writer = try WavWriter(url: url)
        try writer.appendSilence(samples: 100)
        try writer.close()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 200)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        let dataSize = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(dataSize, 200)
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(rate, 16_000)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testLateStartBecomesLeadingSilence() throws {
        let url = tempWav()
        let track = AlignedTrack(writer: try WavWriter(url: url), startTime: 100)
        try track.write([Int16](repeating: 7, count: 160), at: 100.5)
        try track.finish(at: 101)
        let out = try samples(of: url)
        XCTAssertEqual(out.count, 16_000)
        XCTAssertEqual(out[7_999], 0)
        XCTAssertEqual(out[8_000], 7)
    }

    func testPauseGapKeepsTimelineAligned() throws {
        let url = tempWav()
        let track = AlignedTrack(writer: try WavWriter(url: url), startTime: 0)
        try track.write([Int16](repeating: 1, count: 16_000), at: 0)
        // No write between t=1 and t=3: paused, or nothing playing.
        try track.write([Int16](repeating: 2, count: 16_000), at: 3)
        try track.finish(at: 4)
        let out = try samples(of: url)
        XCTAssertEqual(out.count, 64_000)
        XCTAssertEqual(out[15_999], 1)
        XCTAssertEqual(out[32_000], 0)
        XCTAssertEqual(out[48_000], 2)
    }

    func testSmallJitterIsNotCorrected() throws {
        let url = tempWav()
        let track = AlignedTrack(writer: try WavWriter(url: url), startTime: 0)
        try track.write([Int16](repeating: 1, count: 1_600), at: 0)
        try track.write([Int16](repeating: 2, count: 1_600), at: 0.105)  // 5 ms late
        try track.finish(at: 0.2)
        let out = try samples(of: url)
        XCTAssertEqual(out[1_600], 2, "no silence inserted under the tolerance")
    }

    func testOverlappingBufferIsTrimmed() throws {
        let url = tempWav()
        let track = AlignedTrack(writer: try WavWriter(url: url), startTime: 0)
        try track.write([Int16](repeating: 1, count: 16_000), at: 0)
        try track.write([Int16](repeating: 2, count: 8_000), at: 0.75)  // repeats 0.25 s
        try track.finish(at: 1.25)
        let out = try samples(of: url)
        XCTAssertEqual(out.count, 20_000)
        XCTAssertEqual(out[15_999], 1)
        XCTAssertEqual(out[16_000], 2)
    }
}
