import XCTest
@testable import Playground
import Argmax

@MainActor
final class SessionHistoryManagerTests: XCTestCase {
    var sut: SessionHistoryManager!
    private var testStore: UserDefaults!
    private let testSuiteName = "com.argmax.playground.tests.SessionHistoryManagerTests"

    override func setUp() {
        super.setUp()
        testStore = UserDefaults(suiteName: testSuiteName)
        sut = SessionHistoryManager()
    }

    override func tearDown() {
        sut.clearAll()
        sut = nil
        testStore.removePersistentDomain(forName: testSuiteName)
        testStore = nil
        super.tearDown()
    }

    private func makeRecord(mode: SessionMode = .stream, source: String = "Test") -> SessionRecord {
        SessionRecord(
            id: UUID(),
            timestamp: Date(),
            mode: mode,
            sourceDescription: source,
            settings: SettingsSnapshot(
                whisperKitModel: "test-model",
                diarizationModel: "sortformer",
                sortformerMode: "",
                enableTimestamps: true,
                temperatureStart: 0,
                fallbackCount: 5,
                sampleLength: 224,
                silenceThreshold: 0.2,
                transcriptionMode: "voiceTriggered",
                chunkingStrategy: "vad",
                concurrentWorkerCount: 4,
                encoderComputeUnits: "cpuAndNeuralEngine",
                decoderComputeUnits: "cpuAndNeuralEngine",
                diarizationMode: "sequential",
                speakerInfoStrategy: "subsegment",
                minNumOfSpeakers: -1,
                enableCustomVocabulary: false,
                customVocabularyWords: []
            ),
            segments: [],
            speakerSegments: nil,
            wordsWithSpeakers: nil,
            transcriptionTimings: nil,
            diarizationTimings: nil,
            streamingDiarizationTimings: nil,
            audioFileURL: nil,
            audioDuration: 10.0
        )
    }

    func testAddSession() {
        let record = makeRecord()
        sut.addSession(record)
        XCTAssertEqual(sut.sessions.count, 1)
        XCTAssertEqual(sut.sessions.first?.id, record.id)
    }

    func testAddSessionPrependsMostRecentFirst() {
        let first = makeRecord(source: "First")
        let second = makeRecord(source: "Second")
        sut.addSession(first)
        sut.addSession(second)
        XCTAssertEqual(sut.sessions.count, 2)
        XCTAssertEqual(sut.sessions[0].sourceDescription, "Second")
        XCTAssertEqual(sut.sessions[1].sourceDescription, "First")
    }

    func testRemoveSession() {
        let record = makeRecord()
        sut.addSession(record)
        sut.removeSession(id: record.id)
        XCTAssertTrue(sut.sessions.isEmpty)
    }

    func testRemoveNonexistentSession() {
        let record = makeRecord()
        sut.addSession(record)
        sut.removeSession(id: UUID())
        XCTAssertEqual(sut.sessions.count, 1)
    }

    func testClearAll() {
        for _ in 0..<5 {
            sut.addSession(makeRecord())
        }
        XCTAssertEqual(sut.sessions.count, 5)
        sut.clearAll()
        XCTAssertTrue(sut.sessions.isEmpty)
    }

    func testSettingsSnapshotEqualityAndInequality() {
        let s1 = makeRecord().settings
        let s2 = makeRecord().settings
        XCTAssertEqual(s1, s2, "Settings with same values should be equal")

        let different = SettingsSnapshot(
            whisperKitModel: "large-v3",
            diarizationModel: "sortformer",
            sortformerMode: "",
            enableTimestamps: true,
            temperatureStart: 0,
            fallbackCount: 5,
            sampleLength: 224,
            silenceThreshold: 0.2,
            transcriptionMode: "voiceTriggered",
            chunkingStrategy: "vad",
            concurrentWorkerCount: 4,
            encoderComputeUnits: "cpuAndNeuralEngine",
            decoderComputeUnits: "cpuAndNeuralEngine",
            diarizationMode: "sequential",
            speakerInfoStrategy: "subsegment",
            minNumOfSpeakers: -1,
            enableCustomVocabulary: false,
            customVocabularyWords: []
        )
        XCTAssertNotEqual(s1, different, "Settings with different model names should not be equal")
    }

    func testDisplayTitleUsesSourceDescriptionForFileMode() {
        let record = makeRecord(mode: .transcribeFile, source: "test.wav")
        XCTAssertTrue(record.displayTitle.contains("test.wav"))
    }

    func testDisplayTitleUsesSourceDescriptionForStreamWithCustomSource() {
        let record = makeRecord(mode: .stream, source: "MacBook Pro Microphone")
        XCTAssertTrue(record.displayTitle.contains("MacBook Pro Microphone"))
    }

    func testDisplayTitleUsesModeLabelForStreamWithDefaultSource() {
        let record = makeRecord(mode: .stream, source: "Live Stream")
        XCTAssertFalse(record.displayTitle.contains("Live Stream"))
    }

    func testDisplayTitleDiffersByMode() {
        let streamRecord = makeRecord(mode: .stream, source: "Live Stream")
        let fileRecord = makeRecord(mode: .transcribeFile, source: "Live Stream")
        XCTAssertNotEqual(streamRecord.displayTitle, fileRecord.displayTitle)
    }

    func testDisplayTitleIsNeverEmpty() {
        for record in [makeRecord(mode: .stream), makeRecord(mode: .transcribeFile), makeRecord(mode: .transcribeRecord)] {
            XCTAssertFalse(record.displayTitle.isEmpty)
        }
    }

    func testDisplayDurationUnder60SecondsShowsNoMinutes() {
        var record = makeRecord()
        record.audioDuration = 30
        XCTAssertFalse(record.displayDuration.isEmpty)
        XCTAssertFalse(record.displayDuration.contains("m"), "Durations under 60s should not show minutes")
    }

    func testDisplayDurationOver60SecondsShowsMinutes() {
        var record = makeRecord()
        record.audioDuration = 125
        XCTAssertTrue(record.displayDuration.contains("m"), "Durations over 60s should show minutes")
    }

    func testDisplayDurationBoundary() {
        var below = makeRecord()
        below.audioDuration = 59
        XCTAssertFalse(below.displayDuration.contains("m"))

        var above = makeRecord()
        above.audioDuration = 61
        XCTAssertTrue(above.displayDuration.contains("m"))
    }

    func testSaveStreamSessionMode() {
        let settings = AppSettings(store: testStore)
        sut.saveStreamSession(
            settings: settings,
            segments: [],
            wordsWithSpeakers: nil,
            streamingDiarizationTimings: nil,
            audioFileURL: nil,
            audioDuration: 60.0
        )
        XCTAssertEqual(sut.sessions.count, 1)
        XCTAssertEqual(sut.sessions.first?.mode, .stream)
    }

    func testSaveStreamSessionSourceDescription() {
        let settings = AppSettings(store: testStore)
        sut.saveStreamSession(
            settings: settings,
            segments: [],
            wordsWithSpeakers: nil,
            streamingDiarizationTimings: nil,
            audioFileURL: nil,
            audioDuration: 30.0,
            sourceDescription: "MacBook Pro Microphone"
        )
        XCTAssertEqual(sut.sessions.first?.sourceDescription, "MacBook Pro Microphone")
    }

    func testSaveStreamSessionAudioDuration() throws {
        let settings = AppSettings(store: testStore)
        sut.saveStreamSession(
            settings: settings,
            segments: [],
            wordsWithSpeakers: nil,
            streamingDiarizationTimings: nil,
            audioFileURL: nil,
            audioDuration: 90.5
        )
        let duration = try XCTUnwrap(sut.sessions.first?.audioDuration)
        XCTAssertEqual(duration, 90.5, accuracy: 0.001)
    }

    func testSaveStreamSessionDefaultSourceDescription() {
        let settings = AppSettings(store: testStore)
        sut.saveStreamSession(
            settings: settings,
            segments: [],
            wordsWithSpeakers: nil,
            streamingDiarizationTimings: nil,
            audioFileURL: nil,
            audioDuration: 10.0
        )
        XCTAssertEqual(sut.sessions.first?.sourceDescription, "Live Stream")
    }

    func testSaveStreamSessionPrependsToHistory() {
        let settings = AppSettings(store: testStore)
        sut.saveStreamSession(
            settings: settings,
            segments: [],
            wordsWithSpeakers: nil,
            streamingDiarizationTimings: nil,
            audioFileURL: nil,
            audioDuration: 10.0,
            sourceDescription: "First"
        )
        sut.saveStreamSession(
            settings: settings,
            segments: [],
            wordsWithSpeakers: nil,
            streamingDiarizationTimings: nil,
            audioFileURL: nil,
            audioDuration: 20.0,
            sourceDescription: "Second"
        )
        XCTAssertEqual(sut.sessions.count, 2)
        XCTAssertEqual(sut.sessions[0].sourceDescription, "Second")
        XCTAssertEqual(sut.sessions[1].sourceDescription, "First")
    }
}
