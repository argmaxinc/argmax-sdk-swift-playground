import XCTest
@testable import Playground
import Argmax

final class ExportFormattersTests: XCTestCase {
    private let segments: [TranscriptionSegment] = [
        TranscriptionSegment(id: 0, start: 0.0, end: 2.5, text: "Hello world."),
        TranscriptionSegment(id: 1, start: 3.0, end: 5.5, text: "Second segment."),
    ]

    func testSRTFormat() {
        let srt = ExportFormatters.toSRT(segments: segments, speakerSegments: nil, includeSpeakers: false)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:02,500"), "SRT should contain proper timestamp format")
        XCTAssertTrue(srt.contains("Hello world."), "SRT should contain segment text")
        XCTAssertTrue(srt.contains("1\r\n"), "SRT should contain sequence numbers (with CRLF per spec)")
        XCTAssertTrue(srt.contains("2\r\n"), "SRT should contain second sequence number (with CRLF per spec)")
    }

    func testSRTUsesCRLFLineEndings() {
        let srt = ExportFormatters.toSRT(segments: segments, speakerSegments: nil, includeSpeakers: false)
        // Per SRT convention, line breaks should be CRLF for cross-player compatibility.
        XCTAssertTrue(srt.contains("\r\n"), "SRT should use CRLF line endings")
        let totalNewlines = srt.components(separatedBy: "\n").count - 1
        let crlfPairs = srt.components(separatedBy: "\r\n").count - 1
        XCTAssertEqual(totalNewlines, crlfPairs, "Every \\n should be part of a CRLF pair")
    }

    func testVTTFormat() {
        let vtt = ExportFormatters.toVTT(segments: segments, speakerSegments: nil, includeSpeakers: false)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"), "VTT should start with WEBVTT header")
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:02.500"), "VTT should use dot separator for ms")
    }

    func testJSONFormat() {
        let json = ExportFormatters.toJSON(segments: segments, speakerSegments: nil, includeSpeakers: false)
        XCTAssertTrue(json.contains("\"text\""), "JSON should contain text field")
        XCTAssertTrue(json.contains("\"start\""), "JSON should contain start field")
        XCTAssertTrue(json.contains("Hello world."), "JSON should contain segment text")
        XCTAssertFalse(json.contains("\"speaker\""), "JSON without speakers should not contain speaker field")
    }

    func testPlainText() {
        let txt = ExportFormatters.toPlainText(segments: segments, speakerSegments: nil, includeTimestamps: true, includeSpeakers: false)
        XCTAssertTrue(txt.contains("[0.00 -> 2.50]"), "Plain text should contain timestamps")
        XCTAssertTrue(txt.contains("Hello world."))
    }

    func testPlainTextWithoutTimestamps() {
        let txt = ExportFormatters.toPlainText(segments: segments, speakerSegments: nil, includeTimestamps: false, includeSpeakers: false)
        XCTAssertFalse(txt.contains("["), "Should not contain timestamp brackets")
        XCTAssertEqual(txt, "Hello world.\nSecond segment.")
    }

    func testEmptySegments() {
        let srt = ExportFormatters.toSRT(segments: [], speakerSegments: nil, includeSpeakers: false)
        XCTAssertTrue(srt.isEmpty, "Empty segments should produce empty SRT")

        let json = ExportFormatters.toJSON(segments: [], speakerSegments: nil, includeSpeakers: false)
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertNotNil(parsed, "Empty segments should produce valid JSON")
        XCTAssertTrue(parsed!.isEmpty, "Empty segments should produce an empty JSON array")
    }
}
