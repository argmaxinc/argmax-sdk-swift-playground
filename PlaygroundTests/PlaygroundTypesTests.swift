import XCTest
@testable import Playground

final class PlaygroundTypesTests: XCTestCase {
    func testPlaygroundFeatureIcons() {
        for feature in PlaygroundFeature.allCases {
            XCTAssertFalse(feature.icon.isEmpty, "\(feature.rawValue) should have a non-empty icon")
        }
    }

    func testSettingsSnapshotDiffDescription() {
        let snap = SettingsSnapshot(
            whisperKitModel: "openai_whisper-large-v3",
            diarizationModel: "sortformer",
            sortformerMode: "",
            enableTimestamps: true,
            temperatureStart: 0.5,
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
            enableCustomVocabulary: true,
            customVocabularyWords: ["Argmax", "WhisperKit"]
        )
        let desc = snap.diffDescription
        XCTAssertTrue(desc.contains("whisper-large-v3"))
        XCTAssertTrue(desc.contains("Sortformer"))
        XCTAssertTrue(desc.contains("Custom Vocab: [Argmax, WhisperKit]"))
    }

    func testSettingsSnapshotDiffDescriptionOmitsCustomVocabWhenDisabled() {
        let snap = SettingsSnapshot(
            whisperKitModel: "base",
            diarizationModel: "none",
            sortformerMode: "",
            enableTimestamps: false,
            temperatureStart: 0,
            fallbackCount: 5,
            sampleLength: 224,
            silenceThreshold: 0.2,
            transcriptionMode: "alwaysOn",
            chunkingStrategy: "none",
            concurrentWorkerCount: 1,
            encoderComputeUnits: "cpuOnly",
            decoderComputeUnits: "cpuOnly",
            diarizationMode: "disabled",
            speakerInfoStrategy: "word",
            minNumOfSpeakers: -1,
            enableCustomVocabulary: false,
            customVocabularyWords: ["hidden"]
        )
        XCTAssertFalse(snap.diffDescription.contains("Custom Vocab"), "Vocab should not appear when disabled")
        XCTAssertFalse(snap.diffDescription.contains("Diarization"), "Diarization should not appear when model is none")
    }
}
