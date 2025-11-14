import Foundation
import SwiftUI
import ArgmaxSDK
import Argmax
import WhisperKit
import AVFoundation

/// An `ObservableObject` that manages the state and logic for file-based and recorded audio transcription.
/// This view model acts as the interface between SwiftUI views and the underlying transcription services
/// for processing audio files, recorded audio buffers, and live recording, separate from live streaming.
///
/// ## Core Responsibilities
///
/// - **State Management:** Holds `@Published` properties for transcription results, progress tracking,
///   segment management, speaker diarization, and UI states. These properties are observed by SwiftUI views.
///   Manages internal state transitions for `isTranscribing` without exposing direct setters.
///
/// - **File & Buffer Processing:** Orchestrates transcription of both audio files and recorded audio buffers
///   by interacting with `ArgmaxSDKCoordinator` and `WhisperKitPro`.
///
/// - **Live Recording Management:** Handles live audio recording with permission checking, device validation,
///   and real-time buffer energy updates.
///
/// - **Speaker Diarization:** Manages speaker identification and re-assignment workflows using `SpeakerKit`.
///
/// ### Key Public Methods
///
/// - **`startFileTranscriptionTask(path:decodingOptions:diarizationMode:diarizationOptions:speakerInfoStrategy:transcriptionCallback:)`:**
///   Creates and starts a background task to transcribe a selected audio file from disk. Handles the complete
///   pipeline including audio loading, transcription, optional diarization, and segment management.
///
/// - **`stopRecordAndTranscribe(delayInterval:options:diarizationMode:diarizationOptions:speakerInfoStrategy:transcriptionCallback:)`:**
///   Stops audio recording and creates a background task to transcribe the recorded buffer. Includes
///   voice activity detection (VAD) and real-time processing capabilities.
///
/// ### Core Processing Methods
///
/// - **`transcribeCurrentFile(path:decodingOptions:diarizationMode:diarizationOptions:speakerInfoStrategy:transcriptionCallback:)`:**
///   Low-level file transcription method that handles the complete pipeline.
///
/// - **`transcribeCurrentBuffer(delayInterval:options:diarizationMode:diarizationOptions:speakerInfoStrategy:transcriptionCallback:)`:**
///   Low-level buffer transcription method with VAD and real-time processing.
///
/// - **`transcribeAudioSamples(_:_:chunksCallback:)`:** Core transcription method that processes
///   raw audio samples with progress callbacks and early stopping logic.
///
/// ## Thread Safety & Concurrency
///
/// - All task creation uses proper actor isolation to manage main thread UI updates
/// - Internal state changes are wrapped with `MainActor.run` where necessary
/// - Background processing tasks are created with `Task` for proper concurrency management
///
/// ## Dependencies
///
/// - **`ArgmaxSDKCoordinator`:** Provides access to `WhisperKitPro` and `SpeakerKit` instances
class TranscribeViewModel: ObservableObject {
    @Published var bufferEnergy: [Float] = []
    @Published var confirmedSegments: [TranscriptionSegment] = []
    @Published var unconfirmedSegments: [TranscriptionSegment] = []
    @Published var customVocabularyResults: VocabularyResults = [:]
    @Published var showShortAudioToast: Bool = false
    @Published var diarizedSpeakerSegments: [SpeakerSegment] = []
    @Published var speakerNames: [Int: String] = [:]
    @Published var selectedSpeakerForRename: Int = -1
    @Published var newSpeakerName: String = ""
    @Published var showSpeakerRenameAlert: Bool = false
    
    @Published var isTranscribing: Bool = false
    @Published var transcribeTask: Task<Void, Never>?
    
    @Published var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]
    // TODO - upddte this if it's needed
    // @Published var currentFallbacks: Int = 0
    
    @Published var currentText: String = ""
    @Published var lastBufferSize: Int = 0
    @Published var audioSampleDuration: TimeInterval = 0
    @Published var totalProcessTime: TimeInterval = 0
    @Published var transcriptionDuration: TimeInterval = 0
    @Published var currentAudioPath: String?
    @Published var requiredSegmentsForConfirmation: Int = 4
    @Published var lastConfirmedSegmentEndSeconds: Float = 0
    @Published var confirmedText: String = ""
    @Published var hypothesisText: String = ""
    
    @AppStorage("compressionCheckWindow") private var compressionCheckWindow: Double = 60
    @AppStorage("useVAD") private var useVAD: Bool = true
    @AppStorage("silenceThreshold") private var silenceThreshold: Double = 0.2
    
    #if os(macOS)
    private let energyHistoryLimit = 512
    #else
    private let energyHistoryLimit = 256
    #endif
    private let sdkCoordinator: ArgmaxSDKCoordinator
    
    init(sdkCoordinator: ArgmaxSDKCoordinator) {
        self.sdkCoordinator = sdkCoordinator
    }
    
    // MARK: - Public Methods
    
    /// Resets all transcription-related state to initial values including canceling active tasks
    func resetStates() {
        // Cancel any active transcription task
        transcribeTask?.cancel()
        transcribeTask = nil
        
        // Reset transcription state
        isTranscribing = false
        showShortAudioToast = false
        
        // Reset transcription results
        bufferEnergy = []
        currentText = ""
        confirmedText = ""
        hypothesisText = ""
        currentChunks = [:]
        confirmedSegments = []
        unconfirmedSegments = []
        diarizedSpeakerSegments = []
        customVocabularyResults = [:]
        
        // Reset timing and processing stats
        audioSampleDuration = 0
        transcriptionDuration = 0
        totalProcessTime = 0
        lastConfirmedSegmentEndSeconds = 0
        requiredSegmentsForConfirmation = 2
        lastBufferSize = 0
    }

    /// Clears the current audio file path from the view model state
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
        diarizationMode: ContentView.DiarizationMode,
        diarizationOptions: DiarizationOptions?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        transcriptionCallback: @escaping (TranscriptionResult?) -> Void = { _ in }
    ) {
        transcribeTask = Task {
            await MainActor.run {
                isTranscribing = true
            }
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
                Logging.debug("File transcription error: \(error.localizedDescription)")
            }
            await MainActor.run {
                isTranscribing = false
            }
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
        diarizationMode: ContentView.DiarizationMode,
        diarizationOptions: DiarizationOptions?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        transcriptionCallback: @escaping (TranscriptionResult?) -> Void
    ) {
        if let audioProcessor = sdkCoordinator.whisperKit?.audioProcessor {
            audioProcessor.stopRecording()
        } else {
            return
        }
        transcribeTask = Task {
            await MainActor.run {
                self.isTranscribing = true
            }
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
                Logging.debug("Buffer transcription error: \(error.localizedDescription)")
            }
            await MainActor.run {
                if hypothesisText != "" {
                    confirmedText += hypothesisText
                    hypothesisText = ""
                }

                if !unconfirmedSegments.isEmpty {
                    confirmedSegments.append(contentsOf: unconfirmedSegments)
                    unconfirmedSegments = []
                }
                isTranscribing = false
            }
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
            isTranscribing = true
            try audioProcessor.startRecordingLive(inputDeviceID: inputDeviceID) { _ in
                Task {
                    if let whisperKit = self.sdkCoordinator.whisperKit {
                        await MainActor.run {
                            let cappedEnergy = whisperKit.audioProcessor.relativeEnergy.suffix(self.energyHistoryLimit)
                            self.bufferEnergy = Array(cappedEnergy)
                        }
                    }
                    let bufferSeconds = Double(self.sdkCoordinator.whisperKit?.audioProcessor.audioSamples.count ?? 0) / Double(WhisperKit.sampleRate)
                    await bufferSecondsCallback(bufferSeconds)
                }
            }
        }
    }
    
    /// Re-runs speaker info assignment with new strategy
    func rerunSpeakerInfoAssignment(
        diarizationOptions: DiarizationOptions?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        selectedLanguage: String
    ) async throws {
        guard !diarizedSpeakerSegments.isEmpty else { return }
        
        guard let speakerKit = sdkCoordinator.speakerKit else {
            throw ArgmaxError.modelUnavailable("SpeakerKit not loaded")
        }
        
        let diarizationResult = try await speakerKit.diarize(options: diarizationOptions)
        
        let allSegments = confirmedSegments + unconfirmedSegments
        let allText = allSegments.map { $0.text }.joined(separator: " ")
        let transcriptionArray = [TranscriptionResult(
            text: allText,
            segments: allSegments,
            language: Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode],
            timings: TranscriptionTimings(),
            seekTime: nil
        )]
        let updatedSegmentsArray = diarizationResult.addSpeakerInfo(to: transcriptionArray, strategy: speakerInfoStrategy)
        
        await MainActor.run {
            self.diarizedSpeakerSegments = updatedSegmentsArray.flatMap { $0 }
        }
    }
    
    /// Transcribes audio from a recorded buffer with voice activity detection and real-time processing
    func transcribeCurrentBuffer(
        delayInterval: Float,
        options: DecodingOptions,
        diarizationMode: ContentView.DiarizationMode,
        diarizationOptions: DiarizationOptions?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        transcriptionCallback: @escaping (TranscriptionResult?) -> Void
    ) async throws {
        guard let whisperKit = sdkCoordinator.whisperKit else { return }

        // Retrieve the current audio buffer from the audio processor
        let currentBuffer = whisperKit.audioProcessor.audioSamples

        // Perform an eager copy of the recording buffer off the main actor to avoid UI stalls.
        let bufferCopy: [Float] = await Task.detached(priority: .userInitiated) {
            Array(currentBuffer)
        }.value

        // Calculate the size and duration of the next buffer segment
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

        // Only run the transcribe if the next buffer has at least `delayInterval` seconds of audio
        guard nextBufferSeconds > delayInterval else {
            Task { @MainActor in
                if currentText == "" {
                    currentText = "Waiting for speech..."
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000) // sleep for 100ms for next buffer
            return
        }

        let totalProcessStart = Date()

        if useVAD {
            let voiceDetected = AudioProcessor.isVoiceDetected(
                in: whisperKit.audioProcessor.relativeEnergy,
                nextBufferInSeconds: nextBufferSeconds,
                silenceThreshold: Float(silenceThreshold)
            )
            // Only run the transcribe if the next buffer has voice
            guard voiceDetected else {
                Task { @MainActor in
                    if currentText == "" {
                        currentText = "Waiting for speech..."
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
        }

        // Store this for next iterations VAD
        await MainActor.run {
            lastBufferSize = currentBuffer.count
        }

        let transcriptionStart = Date()
        let transcription = try await Task.detached(priority: .userInitiated) { [weak self] () -> TranscriptionResult? in
            guard let self else { return nil }
            return try await self.transcribeAudioSamples(bufferCopy, options) { joinedText in
                await MainActor.run {
                    self.currentText = joinedText
                }
            }
        }.value
        let transcriptionEnd = Date()

        // MARK: Transcribe recording mode

        Task { @MainActor in
            audioSampleDuration = TimeInterval(nextBufferSeconds)
            transcriptionDuration = transcriptionEnd.timeIntervalSince(transcriptionStart)
        }
        
        if nextBufferSeconds < 60 {
            Task { @MainActor in
                withAnimation {
                    showShortAudioToast = true
                }
            }
        } else {
            await MainActor.run {
                showShortAudioToast = false
            }
        }

        // Diarization if speaker kit available and mode is not disabled
        if diarizationMode != .disabled {
            do {
                guard let speakerKit = sdkCoordinator.speakerKit else {
                    throw ArgmaxError.modelUnavailable("SpeakerKit not loaded")
                }
                
                try await speakerKit.initializeDiarization(
                    audioArray: bufferCopy,
                    decodeOptions: options
                ) { audioClip in
                    Task {
                        do {
                            try await speakerKit.processSpeakerSegment(audioArray: audioClip)
                        } catch {
                            Logging.debug("Error processing speaker segment: \(error)")
                        }
                    }
                }

                let diarizationResult = try await speakerKit.diarize(options: diarizationOptions)
                let transcriptionArray = [transcription].compactMap { $0 }
                let updatedSegmentsArray = diarizationResult.addSpeakerInfo(to: transcriptionArray, strategy: speakerInfoStrategy)
                Task { @MainActor in
                    diarizedSpeakerSegments = updatedSegmentsArray.flatMap { $0 }
                }
            } catch {
                Logging.error("Error in transcribe recording mode diarization \(error)")
            }
        }

        // Calculate the total processing time
        // Clear current text and call the callback with transcription result
        let totalProcessEnd = Date()
        Task { @MainActor in
            totalProcessTime = totalProcessEnd.timeIntervalSince(totalProcessStart)
            currentText = ""
            // Update confirmed segments directly in viewmodel
            if let segments = transcription?.segments {
                // Logic for moving segments to confirmedSegments
                if segments.count > requiredSegmentsForConfirmation {
                    // Calculate the number of segments to confirm
                    let numberOfSegmentsToConfirm = segments.count - requiredSegmentsForConfirmation

                    // Confirm the required number of segments
                    let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
                    let remainingSegments = Array(segments.suffix(requiredSegmentsForConfirmation))

                    // Update lastConfirmedSegmentEnd based on the last confirmed segment
                    if let lastConfirmedSegment = confirmedSegmentsArray.last, lastConfirmedSegment.end > lastConfirmedSegmentEndSeconds {
                        lastConfirmedSegmentEndSeconds = lastConfirmedSegment.end
                        Logging.debug("Last confirmed segment end: \(lastConfirmedSegmentEndSeconds)")

                        // Add confirmed segments to the confirmedSegments array
                        for segment in confirmedSegmentsArray {
                            if !confirmedSegments.contains(segment: segment) {
                                confirmedSegments.append(segment)
                            }
                        }
                    }

                    // Update transcriptions to reflect the remaining segments
                    unconfirmedSegments = remainingSegments
                } else {
                    // Handle the case where segments are fewer or equal to required
                    unconfirmedSegments = segments
                }
            }
            transcriptionCallback(transcription)
        }
    }
    
    /// Transcribes an audio file from disk with optional diarization and segment management
    func transcribeCurrentFile(
        path: String,
        decodingOptions: DecodingOptions,
        diarizationMode: ContentView.DiarizationMode,
        diarizationOptions: DiarizationOptions?,
        speakerInfoStrategy: SpeakerInfoStrategy,
        transcriptionCallback: @escaping (TranscriptionResult?) -> Void
    ) async throws {
        Task { @MainActor in
            audioSampleDuration = 0
            transcriptionDuration = 0
            totalProcessTime = 0
            currentAudioPath = path
        }

        Logging.debug("Loading audio file: \(path)")
        let audioFileSamples = try await Task {
            try autoreleasepool {
                try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            }
        }.value

        let audioDuration = Double(audioFileSamples.count) / Double(WhisperKit.sampleRate)
        Task { @MainActor in
            audioSampleDuration = audioDuration
            if audioSampleDuration < 60 {
                withAnimation {
                    showShortAudioToast = true
                }
            } else {
                showShortAudioToast = false
            }
        }
        Logging.debug("Audio duration: \(audioDuration) seconds")

        // Time the entire process from start to finish
        let totalProcessStart = Date()

        // Start concurrent diarization if enabled
        var diarizationTask: Task<DiarizationResult?, Error>? = nil
        if diarizationMode == .concurrent {
            diarizationTask = Task {
                do {
                    guard let speakerKit = sdkCoordinator.speakerKit else {
                        throw ArgmaxError.modelUnavailable("SpeakerKit not loaded")
                    }

                    try await speakerKit.initializeDiarization(
                        audioArray: audioFileSamples,
                        decodeOptions: decodingOptions
                    ) { audioClip in
                        Task {
                            do {
                                try await speakerKit.processSpeakerSegment(audioArray: audioClip)
                            } catch {
                                Logging.debug("Error processing speaker segment: \(error)")
                            }
                        }
                    }

                    return try await speakerKit.diarize(options: diarizationOptions ?? DiarizationOptions())
                } catch {
                    Logging.debug("Error in concurrent diarization: \(error)")
                    return nil
                }
            }
        }

        let transcriptionStart = Date()
        let transcription = try await transcribeAudioSamples(audioFileSamples, decodingOptions) { joinedText in
            Task { @MainActor in
                self.currentText = joinedText
            }
        }
        let transcriptionEnd = Date()
        Task { @MainActor in
            transcriptionDuration = transcriptionEnd.timeIntervalSince(transcriptionStart)
        }

        if diarizationMode == .sequential {
            do {
                guard let speakerKit = sdkCoordinator.speakerKit else {
                    throw ArgmaxError.modelUnavailable("SpeakerKit not loaded")
                }

                try await speakerKit.initializeDiarization(
                    audioArray: audioFileSamples,
                    decodeOptions: decodingOptions
                ) { audioClip in
                    Task {
                        do {
                            try await speakerKit.processSpeakerSegment(audioArray: audioClip)
                        } catch {
                            Logging.debug("Error processing speaker segment: \(error)")
                        }
                    }
                }

                let diarizationResult = try await speakerKit.diarize(options: diarizationOptions ?? DiarizationOptions())
                let transcriptionArray = [transcription].compactMap { $0 }
                let updatedSegmentsArray = diarizationResult.addSpeakerInfo(to: transcriptionArray, strategy: speakerInfoStrategy)
                Task { @MainActor in
                    diarizedSpeakerSegments = updatedSegmentsArray.flatMap { $0 }
                }
            } catch {
                Logging.debug("Error in sequential diarization: \(error)")
            }
        }

        if diarizationMode == .concurrent, let task = diarizationTask {
            do {
                if let diarizationResult = try await task.value {
                    let transcriptionArray = [transcription].compactMap { $0 }
                    let updatedSegmentsArray = diarizationResult.addSpeakerInfo(to: transcriptionArray, strategy: speakerInfoStrategy)
                    Task { @MainActor in
                        diarizedSpeakerSegments = updatedSegmentsArray.flatMap { $0 }
                    }
                }
            } catch {
                Logging.debug("Error processing concurrent diarization results: \(error)")
            }
        }

        // Calculate the total processing time
        let totalProcessEnd = Date()
        let finalTotalProcessTime = totalProcessEnd.timeIntervalSince(totalProcessStart)
        
        Task { @MainActor in
            totalProcessTime = finalTotalProcessTime
            currentText = ""
            
            // Update confirmed segments directly in viewmodel
            if let segments = transcription?.segments {
                confirmedSegments = segments
            }
            
            transcriptionCallback(transcription)
        }
        
        // Log the timings
        Logging.debug("Audio Sample Duration: \(audioDuration) seconds")
        Logging.debug("Transcription Duration: \(transcriptionEnd.timeIntervalSince(transcriptionStart)) seconds")
        Logging.debug("Total Process Time: \(finalTotalProcessTime) seconds")
    }
    
    // MARK: - Private Methods
    
    /// Core transcription method that processes raw audio samples with progress callbacks and early stopping
    private func transcribeAudioSamples(_ samples: [Float], _ options: DecodingOptions, chunksCallback: @escaping (String) async -> Void) async throws -> TranscriptionResult? {
        guard let whisperKit = sdkCoordinator.whisperKit else { return nil }
        
        // Early stopping checks
        let decodingCallback: ((TranscriptionProgress) -> Bool?) = { (progress: TranscriptionProgress) in
            
            let fallbacks = Int(progress.timings.totalDecodingFallbacks)
            let chunkId = progress.windowId // isStreamMode assumed false
            
            // First check if this is a new window for the same chunk, append if so
            var updatedChunk = (chunkText: [progress.text], fallbacks: fallbacks)
            if var currentChunk = self.currentChunks[chunkId], let previousChunkText = currentChunk.chunkText.last {
                if progress.text.count >= previousChunkText.count {
                    // This is the same window of an existing chunk, so we just update the last value
                    currentChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                    updatedChunk = currentChunk
                } else {
                    // Fallback, overwrite the previous bad text
                    updatedChunk.chunkText[currentChunk.chunkText.endIndex - 1] = progress.text
                    updatedChunk.fallbacks = fallbacks
                    Logging.debug("Fallback occured: \(fallbacks)")
                }
            }
            Task { @MainActor in
                // Set the new text for the chunk
                self.currentChunks[chunkId] = updatedChunk
                let joinedChunks = self.currentChunks.sorted { $0.key < $1.key }.flatMap { $0.value.chunkText }.joined(separator: "\n")
            
                await chunksCallback(joinedChunks)
                // TODO - reenable if needed
                // self.currentFallbacks = fallbacks
            }
                
            
            // Check early stopping
            let currentTokens = progress.tokens
            let checkWindow = Int(self.compressionCheckWindow)
            if currentTokens.count > checkWindow {
                let checkTokens: [Int] = currentTokens.suffix(checkWindow)
                let compressionRatio = TextUtilities.compressionRatio(of: checkTokens)
                if compressionRatio > options.compressionRatioThreshold! {
                    Logging.debug("Early stopping due to compression threshold")
                    return false
                }
            }
            if progress.avgLogprob! < options.logProbThreshold! {
                Logging.debug("Early stopping due to logprob threshold")
                return false
            }
            return nil
        }
        
        let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: decodingCallback
        )
        
        let mergedResults = WhisperKitProUtils.mergeTranscriptionResults(transcriptionResults)
        if let proResult = mergedResults as? TranscriptionResultPro {
            await MainActor.run {
                self.customVocabularyResults = proResult.customVocabularyResults
            }
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
        switch speaker {
            case let .speakerId(id):
                if id == 0 {
                    return Color(hex: "3936DA") // Blue color for speakerId 0
                }
                let colors: [Color] = [
                    Color(hex: "A8C887"), // Green
                    Color(hex: "DD5F2F"), // Orange
                    Color(hex: "F0C148"), // Yellow
                ]
                let index = abs(id) % colors.count
                return colors[index]
            case .noMatch, .multiple:
                return Color(hex: "737066") // Gray color for undefined speakers
            @unknown default:
                return Color(hex: "737066")
        }
    }
}
