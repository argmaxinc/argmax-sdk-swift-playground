import Foundation
import SwiftUI
import Argmax

/// In-memory store for session history. Does not persist across app launches.
@MainActor
class SessionHistoryManager: ObservableObject {
    @Published var sessions: [SessionRecord] = []

    func addSession(_ record: SessionRecord) {
        sessions.insert(record, at: 0)
    }

    func removeSession(id: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            let session = sessions[index]
            cleanupAudioFile(session.audioFileURL)
            sessions.remove(at: index)
        }
    }

    func clearAll() {
        for session in sessions {
            cleanupAudioFile(session.audioFileURL)
        }
        sessions.removeAll()
    }

    private func cleanupAudioFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Convenience: build a SessionRecord from AppSettings plus tab-specific data.
    func saveTranscribeSession(
        settings: AppSettings,
        sdkCoordinator: ArgmaxSDKCoordinator,
        mode: SessionMode,
        source: String,
        diarizationMode: String,
        segments: [TranscriptionSegment],
        speakerSegments: [SpeakerSegment]?,
        result: TranscriptionResult?,
        diarizationTimings: PyannoteDiarizationTimings?,
        diarizationDurationMs: Double?,
        audioFileURL: URL?,
        audioDuration: TimeInterval
    ) {
        let snapshot = settings.captureSettings(
            diarizationMode: diarizationMode,
            customVocabularyWords: settings.enableCustomVocabulary ? sdkCoordinator.currentCustomVocabularyWords : []
        )
        let record = SessionRecord(
            id: UUID(),
            timestamp: Date(),
            mode: mode,
            sourceDescription: source,
            settings: snapshot,
            segments: segments,
            speakerSegments: speakerSegments,
            wordsWithSpeakers: nil,
            transcriptionTimings: result?.timings,
            diarizationTimings: diarizationTimings,
            streamingDiarizationTimings: nil,
            diarizationDurationMs: diarizationDurationMs,
            audioFileURL: audioFileURL,
            audioDuration: audioDuration
        )
        addSession(record)
    }

    func saveStreamSession(
        settings: AppSettings,
        segments: [TranscriptionSegment],
        wordsWithSpeakers: [WordWithSpeaker]?,
        streamingDiarizationTimings: Any?,
        audioFileURL: URL?,
        audioDuration: TimeInterval,
        sourceDescription: String = "Live Stream",
        resolvedSortformerMode: String? = nil
    ) {
        let snapshot = settings.captureSettings(diarizationMode: settings.diarizationModeRaw, resolvedSortformerMode: resolvedSortformerMode)
        let record = SessionRecord(
            id: UUID(),
            timestamp: Date(),
            mode: .stream,
            sourceDescription: sourceDescription,
            settings: snapshot,
            segments: segments,
            speakerSegments: nil,
            wordsWithSpeakers: wordsWithSpeakers,
            transcriptionTimings: nil,
            diarizationTimings: nil,
            streamingDiarizationTimings: streamingDiarizationTimings,
            diarizationDurationMs: nil,
            audioFileURL: audioFileURL,
            audioDuration: audioDuration
        )
        addSession(record)
    }
}
