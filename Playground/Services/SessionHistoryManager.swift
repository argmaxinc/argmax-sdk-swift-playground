import Foundation
import SwiftUI
import Argmax

/// In-memory store for session history. Does not persist across app launches.
@MainActor
final class SessionHistoryManager: ObservableObject {
    @Published var sessions: [SessionRecord] = []

    func addSession(_ record: SessionRecord) {
        sessions.insert(record, at: 0)
    }

    func removeSession(id: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            let session = sessions[index]
            cleanupFile(session.audioFileURL)
            cleanupFile(session.traceFileURL)
            sessions.remove(at: index)
        }
    }

    func clearAll() {
        for session in sessions {
            cleanupFile(session.audioFileURL)
            cleanupFile(session.traceFileURL)
        }
        sessions.removeAll()
    }

    private func cleanupFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Tab-specific inputs for a transcribe-mode save. Packaging these as a struct keeps the
    /// `saveTranscribeSession` signature readable at call sites rather than a 12-positional
    /// argument list. `customVocabularyWords` is passed in (not pulled from the coordinator) so
    /// the history manager doesn't need a reference to it.
    struct TranscribeSessionContext {
        let settings: AppSettings
        let mode: SessionMode
        let source: String
        let diarizationMode: String
        let segments: [TranscriptionSegment]
        let speakerSegments: [SpeakerSegment]?
        let result: TranscriptionResult?
        let diarizationTimings: PyannoteDiarizationTimings?
        let diarizationDurationMs: Double?
        let audioFileURL: URL?
        let traceFileURL: URL?
        let audioDuration: TimeInterval
        let customVocabularyWords: [String]
    }

    func saveTranscribeSession(_ context: TranscribeSessionContext) {
        let snapshot = context.settings.captureSettings(
            diarizationMode: context.diarizationMode,
            customVocabularyWords: context.settings.enableCustomVocabulary ? context.customVocabularyWords : []
        )
        let record = SessionRecord(
            id: UUID(),
            timestamp: Date(),
            mode: context.mode,
            sourceDescription: context.source,
            settings: snapshot,
            segments: context.segments,
            speakerSegments: context.speakerSegments,
            wordsWithSpeakers: nil,
            transcriptionTimings: context.result?.timings,
            diarizationTimings: context.diarizationTimings,
            streamingDiarizationTimings: nil,
            diarizationDurationMs: context.diarizationDurationMs,
            audioFileURL: context.audioFileURL,
            traceFileURL: context.traceFileURL,
            audioDuration: context.audioDuration
        )
        addSession(record)
    }

    func saveStreamSession(
        settings: AppSettings,
        segments: [TranscriptionSegment],
        wordsWithSpeakers: [WordWithSpeaker]?,
        streamingDiarizationTimings: Any?,
        audioFileURL: URL?,
        traceFileURL: URL? = nil,
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
            traceFileURL: traceFileURL,
            audioDuration: audioDuration
        )
        addSession(record)
    }
}
