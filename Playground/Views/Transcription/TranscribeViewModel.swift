import Foundation
import SwiftUI
#if canImport(ArgmaxSDK)
import ArgmaxSDK
#endif
import Argmax
import WhisperKit
import AVFoundation

enum PipelinePhase: Equatable {
    case idle
    case recording
    case transcribing
    case diarizing
    case transcribingAndDiarizing
}

/// Live decoder-preview text as an @Observable class so that only DecoderPreviewLine
/// subscribes to its changes. This keeps currentText updates from invalidating the
/// entire TranscribeResultView body — and all its speaker bubbles — on every tick.
@Observable
final class DecoderPreviewText {
    var value: String = ""
}

/// Isolated progress container for the pipeline status label.
/// @Observable keeps updates out of TranscribeViewModel.objectWillChange —
/// only TranscriptionProgressBar subscribes to these values.
///
/// Both fields are 0-100 integers gated at 1% to minimize invalidations.
/// - transcription: sourced from whisperKit.progress.fractionCompleted per window callback.
/// - diarization:   mirrored from diarizationProgress via its didSet.
@Observable
final class PipelineProgress {
    var transcription: Int? = nil
    var diarization: Int? = nil

    func reset() {
        transcription = nil
        diarization = nil
    }
}

/// An `ObservableObject` that manages the state and logic for file-based and recorded audio transcription.
/// This view model acts as the interface between SwiftUI views and the underlying transcription services
/// for processing audio files, recorded audio buffers, and live recording, separate from live streaming.
@MainActor
class TranscribeViewModel: ObservableObject {
    @Published var bufferEnergy: [Float] = []
    @Published var confirmedSegments: [TranscriptionSegment] = []
    /// Only transitions at session boundaries (reset / final commit) to avoid per-tick re-renders.
    @Published var hasConfirmedResults: Bool = false
    @Published var unconfirmedSegments: [TranscriptionSegment] = []
    @Published var customVocabularyResults: VocabularyResults = [:]
    @Published var showShortAudioToast: Bool = false
    @Published var diarizedSpeakerSegments: [SpeakerSegment] = []
    @Published var lastDiarizationTimings: PyannoteDiarizationTimings?
    @Published var lastDiarizationDurationMs: Double?
    @Published var speakerNames: [Int: String] = [:]
    @Published var selectedSpeakerForRename: Int = -1
    @Published var newSpeakerName: String = ""
    @Published var showSpeakerRenameAlert: Bool = false
    
    @Published private(set) var pipelinePhase: PipelinePhase = .idle
    // Not @Published — routed through pipelineProgress (@Observable) to avoid full-body rerenders
    var diarizationProgress: Double = 0 {
        didSet {
            let pct = Int(diarizationProgress * 100)
            if pipelineProgress.diarization != pct { pipelineProgress.diarization = pct }
        }
    }

    let pipelineProgress = PipelineProgress()

    var isRecordingAudio: Bool { pipelinePhase == .recording }
    var isTranscribing: Bool { pipelinePhase == .transcribing || pipelinePhase == .transcribingAndDiarizing }
    var isDiarizing: Bool    { pipelinePhase == .diarizing   || pipelinePhase == .transcribingAndDiarizing }

    @Published var transcribeTask: Task<Void, Never>?

    // Not @Published — purely internal accumulator; only currentText drives UI updates.
    var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]
    // Not @Published — updates propagate to decoderPreview.value (@Observable) so that
    // only DecoderPreviewLine re-renders, not the full TranscribeResultView body.
    var currentText: String = "" {
        didSet { decoderPreview.value = currentText }
    }
    let decoderPreview = DecoderPreviewText()
    @Published var lastBufferSize: Int = 0
    @Published var audioSampleDuration: TimeInterval = 0
    @Published var totalProcessTime: TimeInterval = 0
    @Published var transcriptionDuration: TimeInterval = 0
    @Published var currentAudioPath: String?
    @Published var requiredSegmentsForConfirmation: Int = 2
    @Published var lastConfirmedSegmentEndSeconds: Float = 0
    @Published var confirmedText: String = ""
    @Published var hypothesisText: String = ""
    @Published private(set) var confirmedSegmentsVersion: Int = 0
    
    private let sdkCoordinator: ArgmaxSDKCoordinator
    private let settings: AppSettings

    private var cachedDiarizationResult: DiarizationResult?
    private var cachedTranscriptionResult: TranscriptionResult?

    private static let bufferUpdateThrottleInterval: TimeInterval = 0.1
    private var lastBufferUpdateTime: CFAbsoluteTime = 0

    private static let progressUpdateThrottleInterval: TimeInterval = 0.3

    init(sdkCoordinator: ArgmaxSDKCoordinator, settings: AppSettings) {
        self.sdkCoordinator = sdkCoordinator
        self.settings = settings
    }
    
    // MARK: - Public Methods
    
    func resetStates() {
        transcribeTask?.cancel()
        transcribeTask = nil
        
        pipelinePhase = .idle
        diarizationProgress = 0
        pipelineProgress.reset()
        showShortAudioToast = false
        
        bufferEnergy = []
        currentText = ""
        confirmedText = ""
        hypothesisText = ""
        currentChunks = [:]
        confirmedSegments = []
        hasConfirmedResults = false
        unconfirmedSegments = []
        diarizedSpeakerSegments = []
        confirmedSegmentsVersion += 1
        lastDiarizationTimings = nil
        lastDiarizationDurationMs = nil
        cachedDiarizationResult = nil
        cachedTranscriptionResult = nil
        customVocabularyResults = [:]
        
        audioSampleDuration = 0
        transcriptionDuration = 0
        totalProcessTime = 0
        lastConfirmedSegmentEndSeconds = 0
        requiredSegmentsForConfirmation = 2
        lastBufferSize = 0
    }

    func clearCurrentAudioPath() {
        currentAudioPath = nil
    }

    /// Starts a background transcription task for processing an audio file
    /// - Parameters:
    ///   - path: The file system path to the audio file to transcribe
    ///   - decodingOptions: Configuration options for the transcription process
    ///   - diarizationMode: Speaker diarization processing mode (disabled, concurrent, sequential)
    ///   - diarizationOptions: Optional configuration for speaker diarization
    ///   - speakerInfoStrategy: Strategy for assigning speaker information to transcription segments
    ///   - transcriptionCallback: Callback function invoked when transcription completes
    func startFileTranscriptionTask(
        path: String,
        decodingOptions: DecodingOptions,
        diarizationMode: DiarizationMode,
        diarizationOptions: (any DiarizationOptions)?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        transcriptionCallback: @escaping (TranscriptionResult?) -> Void = { _ in }
    ) {
        transcribeTask = Task {
            pipelinePhase = .transcribing
            do {
                try await transcribeCurrentFile(
                    path: path,
                    decodingOptions: decodingOptions,
                    diarizationMode: diarizationMode,
                    diarizationOptions: diarizationOptions,
                    speakerInfoStrategy: speakerInfoStrategy,
                    transcriptionCallback: transcriptionCallback
                )
            } catch {
                Logging.error("File transcription error: \(error.localizedDescription)")
                currentText = ""
            }
            pipelinePhase = .idle
        }
    }
    
    /// Stops audio recording and starts transcription of the recorded buffer
    /// - Parameters:
    ///   - delayInterval: Minimum audio duration required before processing
    ///   - options: Decoding options for transcription configuration
    ///   - diarizationMode: Speaker diarization processing mode
    ///   - diarizationOptions: Optional configuration for speaker diarization
    ///   - speakerInfoStrategy: Strategy for assigning speaker information
    ///   - transcriptionCallback: Callback function invoked when transcription completes
    func stopRecordAndTranscribe(
        delayInterval: Float,
        options: DecodingOptions,
        diarizationMode: DiarizationMode,
        diarizationOptions: (any DiarizationOptions)?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        transcriptionCallback: @escaping (TranscriptionResult?) -> Void
    ) {
        if let audioProcessor = sdkCoordinator.whisperKit?.audioProcessor {
            audioProcessor.stopRecording()
        } else {
            return
        }
        transcribeTask = Task {
            pipelinePhase = .transcribing
            do {
                try await transcribeCurrentBuffer(
                    delayInterval: delayInterval,
                    options: options,
                    diarizationMode: diarizationMode,
                    diarizationOptions: diarizationOptions,
                    speakerInfoStrategy: speakerInfoStrategy,
                    transcriptionCallback: transcriptionCallback
                )
            } catch {
                Logging.error("Buffer transcription error: \(error.localizedDescription)")
                currentText = ""
            }
            if hypothesisText != "" {
                confirmedText += hypothesisText
                hypothesisText = ""
            }
            if !unconfirmedSegments.isEmpty {
                confirmedSegments.append(contentsOf: unconfirmedSegments)
                unconfirmedSegments = []
                hasConfirmedResults = true
                confirmedSegmentsVersion += 1
            }
            pipelinePhase = .idle
        }
    }
    
    /// Starts live audio recording with real-time buffer energy monitoring
    /// - Parameters:
    ///   - inputDeviceID: Optional device ID for audio input selection
    ///   - bufferSecondsCallback: Callback function for buffer duration updates
    /// - Throws: Audio recording errors if device access fails
    func startRecordAudio(
        inputDeviceID: DeviceID?,
        bufferSecondsCallback: @escaping (Double) async -> Void
    ) throws {
        if let audioProcessor = sdkCoordinator.whisperKit?.audioProcessor {
            pipelinePhase = .recording
            try audioProcessor.startRecordingLive(inputDeviceID: inputDeviceID) { _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    if let whisperKit = self.sdkCoordinator.whisperKit {
                        let cappedEnergy = whisperKit.audioProcessor.relativeEnergy.suffix(AudioConstants.energyHistoryLimit)
                        if now - self.lastBufferUpdateTime >= Self.bufferUpdateThrottleInterval {
                            self.lastBufferUpdateTime = now
                            self.bufferEnergy = Array(cappedEnergy)
                        }
                    }
                    let bufferSeconds = Double(self.sdkCoordinator.whisperKit?.audioProcessor.audioSamples.count ?? 0) / Double(WhisperKit.sampleRate)
                    await bufferSecondsCallback(bufferSeconds)
                }
            }
        }
    }
    
    func rerunSpeakerInfoAssignment(
        diarizationOptions: (any DiarizationOptions)?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        selectedLanguage: String
    ) async throws {
        guard !diarizedSpeakerSegments.isEmpty else { return }
        
        guard let speakerKit = sdkCoordinator.speakerKit else {
            throw ArgmaxError.modelUnavailable("SpeakerKit not loaded")
        }
        guard let path = currentAudioPath else {
            throw ArgmaxError.invalidConfiguration("No audio path available for re-diarization")
        }
        let audioSamples = try await Task.detached(priority: .userInitiated) {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        }.value
        diarizationProgress = 0
        let diarizeStart = CFAbsoluteTimeGetCurrent()
        let diarizationResult = try await speakerKit.diarize(audioArray: audioSamples, options: diarizationOptions, progressCallback: makeDiarizationProgressCallback())
        let diarizeElapsedMs = (CFAbsoluteTimeGetCurrent() - diarizeStart) * 1000.0
        
        let allSegments = confirmedSegments + unconfirmedSegments
        let allText = allSegments.map { $0.text }.joined(separator: " ")
        let syntheticResult = TranscriptionResult(
            text: allText,
            segments: allSegments,
            language: Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode],
            timings: TranscriptionTimings(),
            seekTime: nil
        )
        applyDiarizationResult(diarizationResult, transcription: syntheticResult, strategy: speakerInfoStrategy, elapsedMs: diarizeElapsedMs)
    }

    func rerunDiarizationFromFile(
        path: String,
        decodingOptions: DecodingOptions,
        diarizationOptions: (any DiarizationOptions)?,
        speakerInfoStrategy: SpeakerInfoStrategy
    ) {
        transcribeTask = Task {
            pipelinePhase = .diarizing
            do {
                let audioFileSamples = try await Task.detached(priority: .userInitiated) {
                    try autoreleasepool {
                        try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
                    }
                }.value

                guard let speakerKit = sdkCoordinator.speakerKit else {
                    throw ArgmaxError.modelUnavailable("SpeakerKit not loaded")
                }
                diarizationProgress = 0
                let diarizeStart = CFAbsoluteTimeGetCurrent()
                let result = try await speakerKit.diarize(
                    audioArray: audioFileSamples,
                    options: diarizationOptions,
                    progressCallback: makeDiarizationProgressCallback()
                )
                diarizationProgress = 1.0
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - diarizeStart) * 1000.0

                let syntheticResult = TranscriptionResult(
                    text: confirmedSegments.map { $0.text }.joined(separator: " "),
                    segments: confirmedSegments,
                    language: "",
                    timings: TranscriptionTimings(),
                    seekTime: nil
                )
                applyDiarizationResult(result, transcription: syntheticResult, strategy: speakerInfoStrategy, elapsedMs: elapsedMs)
            } catch {
                diarizationProgress = 0
                Logging.error("Error in diarization-only rerun: \(error)")
            }
            pipelinePhase = .idle
        }
    }

    func transcribeCurrentBuffer(
        delayInterval: Float,
        options: DecodingOptions,
        diarizationMode: DiarizationMode,
        diarizationOptions: (any DiarizationOptions)?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        transcriptionCallback: @escaping (TranscriptionResult?) -> Void
    ) async throws {
        guard let whisperKit = sdkCoordinator.whisperKit else { return }

        let currentBuffer = whisperKit.audioProcessor.audioSamples
        let bufferCopy: [Float] = await Task.detached(priority: .userInitiated) {
            Array(currentBuffer)
        }.value

        let tempWriter = AudioFileWriter(sampleRate: Double(WhisperKit.sampleRate))
        tempWriter.append(samples: bufferCopy)
        let tempURL = tempWriter.finalize()
        currentAudioPath = tempURL.path

        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

        guard nextBufferSeconds > delayInterval else {
            if currentText == "" {
                currentText = "Waiting for speech..."
            }
            try await Task.sleep(nanoseconds: 100_000_000) // sleep for 100ms for next buffer
            return
        }

        let totalProcessStart = Date()

        if settings.useVAD {
            let voiceDetected = AudioProcessor.isVoiceDetected(
                in: whisperKit.audioProcessor.relativeEnergy,
                nextBufferInSeconds: nextBufferSeconds,
                silenceThreshold: Float(settings.silenceThreshold)
            )
            guard voiceDetected else {
                if currentText == "" {
                    currentText = "Waiting for speech..."
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
        }

        lastBufferSize = currentBuffer.count

        let transcriptionStart = Date()
        let transcription = try await Task.detached(priority: .userInitiated) { [weak self] () -> TranscriptionResult? in
            guard let self else { return nil }
            return try await self.transcribeAudioSamples(bufferCopy, options) { [weak self] joined in
                self?.currentText = joined
            }
        }.value
        let transcriptionEnd = Date()

        // MARK: Transcribe recording mode

        audioSampleDuration = TimeInterval(nextBufferSeconds)
        transcriptionDuration = transcriptionEnd.timeIntervalSince(transcriptionStart)

        if nextBufferSeconds < 60 {
            withAnimation {
                showShortAudioToast = true
            }
        } else {
            showShortAudioToast = false
        }

        if diarizationMode != .disabled {
            pipelinePhase = .diarizing
            do {
                guard let speakerKit = sdkCoordinator.speakerKit else {
                    throw ArgmaxError.modelUnavailable("SpeakerKit not loaded")
                }
                diarizationProgress = 0
                let diarizationResult = try await speakerKit.diarize(audioArray: bufferCopy, options: diarizationOptions, progressCallback: makeDiarizationProgressCallback())
                diarizationProgress = 1.0
                Task { @MainActor in
                    self.applyDiarizationResult(diarizationResult, transcription: transcription, strategy: speakerInfoStrategy)
                }
            } catch {
                diarizationProgress = 0
                Logging.error("Error in transcribe recording mode diarization \(error)")
            }
        }

        let totalProcessEnd = Date()
        totalProcessTime = totalProcessEnd.timeIntervalSince(totalProcessStart)
        currentText = ""
        if let segments = transcription?.segments {
            if segments.count > requiredSegmentsForConfirmation {
                let numberOfSegmentsToConfirm = segments.count - requiredSegmentsForConfirmation
                let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
                let remainingSegments = Array(segments.suffix(requiredSegmentsForConfirmation))
                if let lastConfirmedSegment = confirmedSegmentsArray.last, lastConfirmedSegment.end > lastConfirmedSegmentEndSeconds {
                    lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
                    Logging.debug("Last confirmed segment end: \(lastConfirmedSegmentEndSeconds)")
                    for segment in confirmedSegmentsArray {
                        if !confirmedSegments.contains(segment: segment) {
                            confirmedSegments.append(segment)
                        }
                    }
                }
                unconfirmedSegments = remainingSegments
            } else {
                unconfirmedSegments = segments
            }
            confirmedSegmentsVersion += 1
        }
        transcriptionCallback(transcription)
    }
    
    func transcribeCurrentFile(
        path: String,
        decodingOptions: DecodingOptions,
        diarizationMode: DiarizationMode,
        diarizationOptions: (any DiarizationOptions)?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        transcriptionCallback: @escaping (TranscriptionResult?) -> Void
    ) async throws {
        audioSampleDuration = 0
        transcriptionDuration = 0
        totalProcessTime = 0
        currentAudioPath = path

        Logging.debug("Loading audio file: \(path)")
        let audioFileSamples = try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            }
        }.value

        let audioDuration = Double(audioFileSamples.count) / Double(WhisperKit.sampleRate)
        audioSampleDuration = audioDuration
        if audioSampleDuration < 60 {
            withAnimation {
                showShortAudioToast = true
            }
        } else {
            showShortAudioToast = false
        }
        Logging.debug("Audio duration: \(audioDuration) seconds")

        let totalProcessStart = Date()

        var diarizationTask: Task<(DiarizationResult?, Double), Error>? = nil
        if diarizationMode == .concurrent, let speakerKit = sdkCoordinator.speakerKit {
            pipelinePhase = .transcribingAndDiarizing
            diarizationTask = Task {
                do {
                    await MainActor.run { self.diarizationProgress = 0 }
                    let diarizeStart = CFAbsoluteTimeGetCurrent()
                    let result = try await speakerKit.diarize(audioArray: audioFileSamples, options: diarizationOptions, progressCallback: self.makeDiarizationProgressCallback())
                    let elapsedMs = (CFAbsoluteTimeGetCurrent() - diarizeStart) * 1000.0
                    return (result, elapsedMs)
                } catch {
                    Logging.debug("Error in concurrent diarization: \(error)")
                    return (nil, 0)
                }
            }
        }

        let transcriptionStart = Date()
        let transcription = try await transcribeAudioSamples(audioFileSamples, decodingOptions) { [weak self] joined in
            self?.currentText = joined
        }
        let transcriptionEnd = Date()
        transcriptionDuration = transcriptionEnd.timeIntervalSince(transcriptionStart)

        // Commit confirmed segments immediately — before diarization — so the
        // transcription text is visible in the main list while diarization runs.
        // Also jump progress to 100% here; the consumer task caps at 95% until transcription finishes.
        if let segments = transcription?.segments {
            confirmedSegments = segments
            hasConfirmedResults = true
            confirmedSegmentsVersion += 1
        }
        pipelineProgress.transcription = 100
        currentText = ""

        if diarizationMode == .sequential {
            pipelinePhase = .diarizing
            do {
                guard let speakerKit = sdkCoordinator.speakerKit else {
                    throw ArgmaxError.modelUnavailable("SpeakerKit not loaded")
                }
                diarizationProgress = 0
                let diarizeStart = CFAbsoluteTimeGetCurrent()
                let diarizationResult = try await speakerKit.diarize(audioArray: audioFileSamples, options: diarizationOptions, progressCallback: makeDiarizationProgressCallback())
                diarizationProgress = 1.0
                let diarizeElapsedMs = (CFAbsoluteTimeGetCurrent() - diarizeStart) * 1000.0
                applyDiarizationResult(diarizationResult, transcription: transcription, strategy: speakerInfoStrategy, elapsedMs: diarizeElapsedMs)
            } catch {
                diarizationProgress = 0
                Logging.error("Error in sequential diarization: \(error)")
            }
            pipelinePhase = .idle
        }

        if diarizationMode == .concurrent, let task = diarizationTask {
            // Stay in .transcribingAndDiarizing — switching to .diarizing would reset the progress bar
            do {
                let (diarizationResult, diarizeElapsedMs) = try await task.value
                diarizationProgress = 1.0
                if let diarizationResult {
                    applyDiarizationResult(diarizationResult, transcription: transcription, strategy: speakerInfoStrategy, elapsedMs: diarizeElapsedMs)
                }
            } catch {
                diarizationProgress = 0
                Logging.error("Error processing concurrent diarization results: \(error)")
            }
            pipelinePhase = .idle
        }

        let totalProcessEnd = Date()
        totalProcessTime = totalProcessEnd.timeIntervalSince(totalProcessStart)
        transcriptionCallback(transcription)
        
        Logging.debug("Audio Sample Duration: \(audioDuration) seconds")
        Logging.debug("Transcription Duration: \(transcriptionEnd.timeIntervalSince(transcriptionStart)) seconds")
        Logging.debug("Total Process Time: \(totalProcessTime) seconds")
    }
    
    // MARK: - Private Methods

    /// Re-runs word-speaker matching on the cached diarization result using updated options,
    /// skipping Sortformer inference entirely. Only applicable after a batch diarization has run.
    @available(macOS 15, iOS 18, *)
    func reapplyWordSpeakerMatching(options: SortformerDiarizationOptions) {
        guard let diarizationResult = cachedDiarizationResult,
              let transcriptionResult = cachedTranscriptionResult else { return }
        let updated = diarizationResult.addSpeakerInfo(
            to: [transcriptionResult],
            strategy: .subsegment(betweenWordThreshold: Float(options.maxWordGapInterval))
        )
        diarizedSpeakerSegments = updated.flatMap { $0 }
        confirmedSegmentsVersion += 1
    }

    private func applyDiarizationResult(
        _ result: DiarizationResult,
        transcription: TranscriptionResult?,
        strategy: SpeakerInfoStrategy,
        elapsedMs: Double? = nil
    ) {
        cachedDiarizationResult = result
        cachedTranscriptionResult = transcription
        let transcriptionArray = [transcription].compactMap { $0 }
        let updated = result.addSpeakerInfo(to: transcriptionArray, strategy: strategy)
        diarizedSpeakerSegments = updated.flatMap { $0 }
        confirmedSegmentsVersion += 1
        lastDiarizationTimings = result.timings as? PyannoteDiarizationTimings
        lastDiarizationDurationMs = result.timings == nil ? elapsedMs : nil
    }

    /// Core transcription method that processes raw audio samples with progress callbacks and early stopping.
    /// Uses an AsyncStream to serialize window updates through a single @MainActor consumer Task,
    /// eliminating concurrent Task spawning and nonisolated time-check races.
    private func transcribeAudioSamples(
        _ samples: [Float],
        _ options: DecodingOptions,
        onTextUpdate: @escaping @MainActor (String) -> Void
    ) async throws -> TranscriptionResult? {
        guard let whisperKit = sdkCoordinator.whisperKit else { return nil }

        struct WindowUpdate {
            let chunkId: Int
            let text: String
            let fallbacks: Int
        }

        let (updateStream, updateContinuation) = AsyncStream<WindowUpdate>.makeStream()

        // Single serialized consumer: merges window chunks on @MainActor and throttles currentText publishes.
        let consumerTask = Task { @MainActor [weak self] in
            var lastPublishTime: CFAbsoluteTime = 0
            for await update in updateStream {
                guard let self else { continue }

                var updatedChunk = (chunkText: [update.text], fallbacks: update.fallbacks)
                if var existing = self.currentChunks[update.chunkId], let prevText = existing.chunkText.last {
                    if update.text.count >= prevText.count {
                        existing.chunkText[existing.chunkText.endIndex - 1] = update.text
                        updatedChunk = existing
                    } else {
                        updatedChunk.chunkText[0] = update.text
                        Logging.debug("Fallback occurred: \(update.fallbacks)")
                    }
                }
                self.currentChunks[update.chunkId] = updatedChunk

                let pct = Int((self.sdkCoordinator.whisperKit?.progress.fractionCompleted ?? 0) * 100)
                if self.pipelineProgress.transcription != pct {
                    self.pipelineProgress.transcription = pct
                }

                let now = CFAbsoluteTimeGetCurrent()
                if now - lastPublishTime >= Self.progressUpdateThrottleInterval {
                    lastPublishTime = now
                    let joined = self.currentChunks
                        .sorted { $0.key < $1.key }
                        .flatMap { $0.value.chunkText }
                        .joined(separator: " ")
                    onTextUpdate(joined)
                }
            }

            onTextUpdate("")
        }

        let compressionCheckWindow = Int(settings.compressionCheckWindow)
        let decodingCallback: ((TranscriptionProgress) -> Bool?) = { progress in
            updateContinuation.yield(WindowUpdate(
                chunkId: progress.windowId,
                text: progress.text,
                fallbacks: Int(progress.timings.totalDecodingFallbacks)
            ))

            let currentTokens = progress.tokens
            let checkWindow = compressionCheckWindow
            if currentTokens.count > checkWindow, let threshold = options.compressionRatioThreshold {
                let checkTokens: [Int] = currentTokens.suffix(checkWindow)
                let compressionRatio = TextUtilities.compressionRatio(of: checkTokens)
                if compressionRatio > threshold {
                    Logging.debug("Early stopping due to compression threshold")
                    return false
                }
            }
            if let logProbThreshold = options.logProbThreshold, let avgLogprob = progress.avgLogprob, avgLogprob < logProbThreshold {
                Logging.debug("Early stopping due to logprob threshold")
                return false
            }
            return nil
        }

        let transcriptionResults: [TranscriptionResult]
        do {
            transcriptionResults = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options,
                callback: decodingCallback
            )
        } catch {
            updateContinuation.finish()
            consumerTask.cancel()
            throw error
        }

        // Close the stream and let the consumer drain + do its final publish.
        updateContinuation.finish()
        await consumerTask.value

        let mergedResults = WhisperKitProUtils.mergeTranscriptionResults(transcriptionResults)
        if let proResult = mergedResults as? TranscriptionResultPro {
            let vocabResults = proResult.customVocabularyResults
            Logging.debug("Custom vocabulary results: \(vocabResults.count) entries, keys: \(vocabResults.keys.map { "\($0.word) (p=\($0.probability))" })")
            customVocabularyResults = vocabResults
        } else {
            Logging.debug("Transcription result is not TranscriptionResultPro (type: \(type(of: mergedResults))), custom vocabulary highlighting unavailable")
        }
        return mergedResults
    }

    // MARK: - UI helpers
    
    func speakerDisplayName(speakerId: Int) -> String {
        if speakerId == -1 {
            return "No Match"
        } else if let name = speakerNames[speakerId] {
            return name
        } else {
            return "Speaker \(speakerId)"
        }
    }
    
    func applySpeakerRename() {
        if !newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speakerNames[selectedSpeakerForRename] = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    func renameSpeaker(speakerId: Int) {
        selectedSpeakerForRename = speakerId
        newSpeakerName = speakerDisplayName(speakerId: speakerId)
        showSpeakerRenameAlert = true
    }
    
    func messageChainTimestamp(currentIndex: Int) -> String {
        guard !diarizedSpeakerSegments.isEmpty,
              currentIndex >= 0,
              currentIndex < diarizedSpeakerSegments.count
        else {
            return "[0.00 → 0.00]"
        }
        let segment = diarizedSpeakerSegments[currentIndex]
        let speakerId = segment.speaker.speakerId
        var firstIndex = currentIndex
        while firstIndex > 0 && diarizedSpeakerSegments[firstIndex - 1].speaker.speakerId == speakerId {
            firstIndex -= 1
        }
        var lastIndex = currentIndex
        while lastIndex < diarizedSpeakerSegments.count - 1 && diarizedSpeakerSegments[lastIndex + 1].speaker.speakerId == speakerId {
            lastIndex += 1
        }
        let firstSegment = diarizedSpeakerSegments[firstIndex]
        let lastSegment = diarizedSpeakerSegments[lastIndex]
        let chainStartTime = firstSegment.speakerWords.first?.wordTiming.start ?? 0
        let chainEndTime = lastSegment.speakerWords.last?.wordTiming.end ?? 0

        return "[\(String(format: "%.2f", chainStartTime)) → \(String(format: "%.2f", chainEndTime))]"
    }
    
    func getMessageBackground(speaker: SpeakerInfo) -> Color {
        SpeakerUI.color(for: speaker.speakerId)
    }

    // MARK: - Private Helpers

    private func makeDiarizationProgressCallback() -> (@Sendable (Progress) -> Void)? {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.diarizationProgress = progress.fractionCompleted
            }
        }
    }
}

