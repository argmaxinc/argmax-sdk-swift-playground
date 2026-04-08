import XCTest
@testable import Playground

final class AudioFileWriterTests: XCTestCase {
    func testCreatesFileAtExpectedPath() {
        let writer = AudioFileWriter(sampleRate: 16000)
        XCTAssertTrue(writer.outputURL.lastPathComponent.hasPrefix("playground_"))
        XCTAssertTrue(writer.outputURL.lastPathComponent.hasSuffix(".wav"))
    }

    func testAppendAndFinalize() {
        let writer = AudioFileWriter(sampleRate: 16000)
        let samples = [Float](repeating: 0.5, count: 16000)
        writer.append(samples: samples)

        let url = writer.finalize()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "WAV file should exist after finalize")

        // Cleanup
        try? FileManager.default.removeItem(at: url)
    }

    func testDurationReflectsAppendedSamples() {
        let writer = AudioFileWriter(sampleRate: 16000)
        let halfSecondOfSamples = [Float](repeating: 0.1, count: 8000)
        writer.append(samples: halfSecondOfSamples)

        // duration uses queue.sync internally, which serializes after the async append
        let duration = writer.duration
        XCTAssertGreaterThan(duration, 0.4, "Duration should be approximately 0.5s")
        XCTAssertLessThan(duration, 0.6, "Duration should be approximately 0.5s")

        let url = writer.finalize()
        try? FileManager.default.removeItem(at: url)
    }

    func testEmptyWriteProducesValidFile() {
        let writer = AudioFileWriter(sampleRate: 16000)
        let url = writer.finalize()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }
}
