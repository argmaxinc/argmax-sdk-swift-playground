import Foundation
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
/// entire TranscribeResultView body -- and all its speaker bubbles -- on every tick.
@Observable
final class DecoderPreviewText {
    var value: String = ""
}

/// Isolated progress container for the pipeline status label.
/// @Observable keeps updates out of TranscribeViewModel.objectWillChange --
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
final class TranscribeViewModel: ObservableObject {
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
    /// Intent surface for the speaker-rename alert. Non-nil signals "the user tapped to rename
    /// speaker `N`"; the view observes and presents its own alert. Set back to `nil` when the
    /// view dismisses the alert. Replaces the old (selectedSpeakerForRename, newSpeakerName,
    /// showSpeakerRenameAlert) triplet that mixed view-layer ephemeral state into the VM.
    @Published var pendingSpeakerRename: Int?
    /// Qwen compute metrics from `onMetrics` callbacks during file/recording transcription.
    @Published var qwenMetrics: QwenStreamMetrics?
    /// First hypothesis received during recording (the "fast final" candidate). Set by
    /// onHypothesis, cleared on reset. Drives the dedicated dictation result UI.
    @Published var dictationFastFinalText: String?
    /// Exact final text returned by finish(). Set after finishActiveDictationSession returns.
    @Published var dictationExactFinalText: String?

    // MARK: - Language Detection

    /// Most recently detected language (lowercase). Reset when states are cleared.
    @Published var detectedLanguage: String?
    /// All distinct languages detected so far this session, in order of first appearance.
    @Published var sessionLanguages: [String] = []

    @Published private(set) var pipelinePhase: PipelinePhase = .idle
    // Not @Published -- routed through pipelineProgress (@Observable) to avoid full-body rerenders
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

    /// Non-published -- assignment doesn't need to drive view updates. Views derive
    /// "show the cancel button" from `hasActiveTranscriptionTask` instead, which only changes
    /// at task start / end, not on every internal mutation.
    var transcribeTask: Task<Void, Never>?
    /// `true` when an in-flight transcription task exists and hasn't been cancelled. Drives
    /// the cancel-button visibility in `TranscribeResultView`.
    @Published var hasActiveTranscriptionTask: Bool = false

    /// Cancels the active transcription task (if any) and clears the handle. Safe to call
    /// when no task is running.
    func cancelTranscription() {
        transcribeTask?.cancel()
        transcribeTask = nil
        hasActiveTranscriptionTask = false
        // The cancelled task skips its own state resets, so return to idle here.
        pipelinePhase = .idle
        _activeDictationSessionBox = nil
        lastAppendTask = nil
        dictationFastFinalText = nil
        dictationExactFinalText = nil
    }

    // Not @Published -- purely internal accumulator; only currentText drives UI updates.
    var currentChunks: [Int: (chunkText: [String], fallbacks: Int)] = [:]
    // Not @Published -- updates propagate to decoderPreview.value (@Observable) so that
    // only DecoderPreviewLine re-renders, not the full TranscribeResultView body.
    var currentText: String = "" {
        didSet { decoderPreview.value = currentText }
    }
    let decoderPreview = DecoderPreviewText()
    // Internal-only counters/buffers (not observed by any View). Keeping them off the
    // `@Published` publisher avoids triggering view re-renders on every transcription tick.
    var lastBufferSize: Int = 0
    var requiredSegmentsForConfirmation: Int = 2
    var confirmedText: String = ""
    var hypothesisText: String = ""

    @Published var audioSampleDuration: TimeInterval = 0
    @Published var totalProcessTime: TimeInterval = 0
    @Published var transcriptionDuration: TimeInterval = 0
    @Published var currentAudioPath: String?
    @Published var lastConfirmedSegmentEndSeconds: Float = 0
    @Published private(set) var confirmedSegmentsVersion: Int = 0
    
    /// Settings signatures captured by TranscribeTabView.onDisappear (macOS embedded-settings
    /// flow). Lives here because the tab view unmounts while Settings occupies the detail
    /// column; compared on reappear to decide whether to rerun. Not @Published -- no UI reads it.
    var settingsSignaturesOnDisappear: (transcription: String, diarization: String)?

    private let sdkCoordinator: ArgmaxSDKCoordinator
    private let settings: AppSettings

    private var cachedDiarizationResult: DiarizationResult?
    private var cachedTranscriptionResult: TranscriptionResult?
    /// Standalone audio processor used when Qwen is the active transcriber (no WhisperKit instance).
    private var standaloneAudioProcessor: (any AudioProcessing)?

    private static let bufferUpdateThrottleInterval: TimeInterval = 0.1
    private var lastBufferUpdateTime: CFAbsoluteTime = 0

    private static let progressUpdateThrottleInterval: TimeInterval = 0.3

    // MARK: - Qwen Real-Time Dictation State
    private var _activeDictationSession: QwenDictationSession? {
        get { _activeDictationSessionBox as? QwenDictationSession }
        set { _activeDictationSessionBox = newValue }
    }
    private var _activeDictationSessionBox: AnyObject?
    /// Tracks how many samples from activeAudioProcessor have been appended to the live session.
    private var dictationFeedOffset: Int = 0
    /// Wall-clock moment when recording (and real-time feeding) began.
    private var dictationRecStart: Date?
    /// Wall-clock moment when stopRecording() was called (the stop gesture).
    private var dictationRecStop: Date?
    /// Timestamps captured during the live session (e.g. first hypothesis).
    private var dictationTS = _DictateTimestamps()
    /// Resolved language passed to makeDictationSession -- needed when building the result.
    private var dictationLanguageName: String?
    /// The most recently dispatched append task. Each new task awaits this one before running,
    /// serialising the feed chain so finish() is never called while an append() is in flight.
    private var lastAppendTask: Task<Void, Never>?


    init(sdkCoordinator: ArgmaxSDKCoordinator, settings: AppSettings) {
        self.sdkCoordinator = sdkCoordinator
        self.settings = settings
    }
    
    // MARK: - Public Methods
    
    /// Returns the active audio processor: WhisperKit's when available, standalone when Qwen is the transcriber.
    private var activeAudioProcessor: (any AudioProcessing)? {
        sdkCoordinator.whisperKit?.audioProcessor ?? standaloneAudioProcessor
    }

    func resetStates() {
        standaloneAudioProcessor?.stopRecording()
        standaloneAudioProcessor = nil
        cancelTranscription()

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

        currentAudioPath = nil
        audioSampleDuration = 0
        transcriptionDuration = 0
        totalProcessTime = 0
        lastConfirmedSegmentEndSeconds = 0
        requiredSegmentsForConfirmation = 2
        lastBufferSize = 0
        qwenMetrics = nil
        dictationFastFinalText = nil
        dictationExactFinalText = nil
        detectedLanguage = nil
        sessionLanguages = []
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
        // This task's state resets are skipped once it is cancelled; whoever cancels it
        // owns the state from then on.
        hasActiveTranscriptionTask = true
        transcribeTask = Task {
            defer { if !Task.isCancelled { hasActiveTranscriptionTask = false } }
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
                guard !Task.isCancelled else { return }
                Logging.error("File transcription error: \(error.localizedDescription)")
                currentText = ""
            }
            guard !Task.isCancelled else { return }
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
        guard let audioProcessor = activeAudioProcessor else { return }
        audioProcessor.stopRecording()
        // Stamp the stop time before any async suspension so metrics are accurate.
        dictationRecStop = Date()
        // Do NOT nil standaloneAudioProcessor here. transcribeCurrentBuffer() reads
        // activeAudioProcessor to get the recorded buffer; clearing it before the
        // Task body runs makes the guard inside transcribeCurrentBuffer return immediately
        // with no transcription and no error. Release it inside the task after capture.
        hasActiveTranscriptionTask = true
        transcribeTask = Task {
            // Cancelled == replaced/aborted: only the current task may reset shared state.
            defer { if !Task.isCancelled { hasActiveTranscriptionTask = false } }
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
                guard !Task.isCancelled else { return }
                Logging.error("Buffer transcription error: \(error.localizedDescription)")
                currentText = ""
                // Clear the rolling hypothesis so the UI doesn't stay frozen on it when
                // finishActiveDictationSession threw (e.g. due to a concurrent-call race).
                dictationFastFinalText = nil
                // Drop the dead session too: a retry on the same buffer must take the batch
                // fallback, not call finish() again on a finished/failed session.
                _activeDictationSessionBox = nil
                lastAppendTask = nil
            }
            guard !Task.isCancelled else { return }
            // Release the standalone processor now that the buffer has been captured and transcribed.
            standaloneAudioProcessor = nil
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
    
    /// Starts live audio recording with real-time buffer energy monitoring.
    /// When Qwen is available, also opens a `QwenDictationSession` and begins feeding
    /// samples in real-time so that `prewarmFinalize()` can fire during trailing silence
    /// and `finish()` is near-instant at the stop gesture.
    func startRecordAudio(
        inputDeviceID: DeviceID?,
        bufferSecondsCallback: @escaping (Double) async -> Void
    ) throws {
        let audioProcessor: any AudioProcessing
        if let ap = sdkCoordinator.whisperKit?.audioProcessor {
            audioProcessor = ap
        } else {
            let ap = AudioProcessor()
            standaloneAudioProcessor = ap
            audioProcessor = ap
            // Each new standalone recorder starts with empty audioSamples; reset the cursor so
            // nextBufferSize = newCount - 0 (not newCount - previousCount, which goes negative).
            lastBufferSize = 0
        }

        // Open a real-time dictation session BEFORE the mic opens so t=0 aligns with recStart.
        if let qwen = sdkCoordinator.qwen {
            try beginQwenDictationSession(qwen)
        }

        pipelinePhase = .recording
        try audioProcessor.startRecordingLive(inputDeviceID: inputDeviceID) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Waveform energy (throttled to avoid re-renders on every audio chunk).
                let now = CFAbsoluteTimeGetCurrent()
                if now - self.lastBufferUpdateTime >= Self.bufferUpdateThrottleInterval {
                    self.lastBufferUpdateTime = now
                    let cappedEnergy = self.activeAudioProcessor?.relativeEnergy
                        .suffix(AudioConstants.energyHistoryLimit)
                        .map { $0.isFinite ? $0 : 0 } ?? []
                    self.bufferEnergy = cappedEnergy
                }

                // Real-time feed for Qwen dictation. Pass all audio -- voice and silence --
                // to the session. The SDK's internal DictationPauseDetector arms auto-prewarm
                // after 300 ms of trailing silence; no caller-side VAD or prewarm call needed.
                if self.pipelinePhase == .recording,
                   let session = self._activeDictationSession,
                   let samples = self.activeAudioProcessor?.audioSamples,
                   samples.count > self.dictationFeedOffset {
                    // Copy only the unfed suffix -- this runs on every ~0.1 s audio callback,
                    // and copying the whole accumulated recording each tick is O(n^2) over a
                    // long dictation.
                    let newSamples = Array(samples[self.dictationFeedOffset...])
                    self.dictationFeedOffset = samples.count
                    // Chain tasks so each append awaits the previous one. This serialises
                    // the feed and ensures finish() is never called while an append() is
                    // still executing (QwenDictationSession is not concurrent-call safe).
                    // The .recording guard above ensures stale callbacks never append
                    // concurrently with finish(): stop flips the phase before finish() runs.
                    let prev = self.lastAppendTask
                    self.lastAppendTask = Task.detached(priority: .userInitiated) {
                        await prev?.value
                        try? await session.append(samples: newSamples)
                    }
                }

                let bufferSeconds = Double(self.activeAudioProcessor?.audioSamples.count ?? 0) / Double(WhisperKit.sampleRate)
                await bufferSecondsCallback(bufferSeconds)
            }
        }
    }

    /// Creates a `QwenDictationSession`, wires the hypothesis callback, and resets all
    /// per-recording dictation state. Must be called before the mic opens (recStart = now).
    private func beginQwenDictationSession(_ qwen: WhisperKitPro) throws {
        let languageName: String? = settings.selectedLanguage == AppSettings.detectLanguageOption
            ? nil
            : settings.selectedLanguage.capitalized
        let session = try qwen.makeDictationSession(language: languageName, silenceThreshold: Float(settings.dictationSilenceThreshold))
        _activeDictationSession = session
        lastAppendTask = nil
        dictationRecStart = Date()
        dictationRecStop = nil
        dictationFeedOffset = 0
        dictationTS = _DictateTimestamps()
        dictationLanguageName = languageName
        qwenMetrics = QwenStreamMetrics()
        dictationFastFinalText = nil
        dictationExactFinalText = nil

        let recStart = dictationRecStart!
        let ts = dictationTS
        // onHypothesis fires at each 8-second decode tick: confirmed prefix + live tail.
        // The first callback requires 8s of audio; short clips won't fire it at all.
        session.onHypothesis = { [weak self, ts, recStart] hypothesis in
            Task { @MainActor in
                if ts.fastFinalApp == nil {
                    ts.fastFinalApp = Date().timeIntervalSince(recStart)
                }
                self?.currentText = hypothesis
                self?.dictationFastFinalText = hypothesis
            }
        }
        // onConfirm fires when a sentence (or comma / token boundary) is permanently
        // flushed. Also updates the hypothesis display so long recordings stay current.
        session.onConfirm = { [weak self] confirmedSoFar in
            Task { @MainActor in
                self?.dictationFastFinalText = confirmedSoFar
            }
        }
    }

    /// Calls `finish()` on the already-fed session and builds the `TranscriptionResult` +
    /// metrics. This is the only SDK call made after the stop gesture; it is near-instant
    /// when `prewarmFinalize()` fired during a trailing-silence window before stop.
    private func finishActiveDictationSession(
        session: QwenDictationSession,
        recStart: Date,
        recStop: Date
    ) async throws -> TranscriptionResult? {
        // Drain the append chain before calling finish(). The recording callback may have
        // dispatched the last append task milliseconds before stopRecording() was called;
        // awaiting it here ensures no append() is in flight when finish() starts.
        await lastAppendTask?.value
        lastAppendTask = nil
        let finishStart = Date()
        let finalText = try await session.finish()
        let finishDone = Date()

        let audioSeconds = recStop.timeIntervalSince(recStart)
        let finishLatency = finishDone.timeIntervalSince(finishStart)
        let totalSeconds = finishDone.timeIntervalSince(recStart)
        // RTF = processing over audio (lower is faster), matching the streaming path's
        // compute/audio definition. Live dictation overlaps recording, so this sits near 1.
        let rtf = audioSeconds > 0 ? totalSeconds / audioSeconds : 0

        var metrics = QwenStreamMetrics()
        metrics.audioSeconds = audioSeconds
        metrics.totalSeconds = totalSeconds
        metrics.exactFinalSeconds = finishDone.timeIntervalSince(recStop)
        metrics.runningRTF = rtf
        metrics.rtfSeries = [rtf]
        metrics.timelineFastFinalApp = dictationTS.fastFinalApp
        // Auto-prewarm fires inside append() at 300 ms of trailing silence; the playground
        // has no timestamps for it. consumedPrewarm tells us whether finish() was a cache hit.
        if session.consumedPrewarm {
            metrics.fastFinalSeconds = finishLatency  // near-zero when cache consumed
        }

        qwenMetrics = metrics
        dictationExactFinalText = finalText
        _activeDictationSession = nil

        let duration = Float(audioSeconds)
        var timings = TranscriptionTimings()
        timings.fullPipeline = totalSeconds
        timings.inputAudioSeconds = audioSeconds
        let segment = TranscriptionSegment(start: 0, end: duration, text: finalText, words: nil)
        return TranscriptionResult(
            text: finalText,
            segments: [segment],
            language: dictationLanguageName ?? "auto",
            timings: timings,
            seekTime: nil
        )
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
        // Cancel the previous task; once cancelled it no longer touches shared state.
        transcribeTask?.cancel()
        hasActiveTranscriptionTask = true
        transcribeTask = Task {
            defer { if !Task.isCancelled { hasActiveTranscriptionTask = false } }
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
                guard !Task.isCancelled else { return }
                diarizationProgress = 0
                Logging.error("Error in diarization-only rerun: \(error)")
            }
            guard !Task.isCancelled else { return }
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
        guard let audioProcessor = activeAudioProcessor else { return }

        let currentBuffer = audioProcessor.audioSamples
        let bufferCopy: [Float] = await Task.detached(priority: .userInitiated) {
            Array(currentBuffer)
        }.value

        let tempWriter = AudioFileWriter(sampleRate: Double(WhisperKit.sampleRate))
        tempWriter.append(samples: bufferCopy)
        let tempURL = tempWriter.finalize()
        currentAudioPath = tempURL.path

        // The Qwen real-time path fed samples during recording and only needs finish(); skip the
        // duration/VAD guards that exist to protect the batch path from empty/quiet buffers.
        let hasActiveDictationSession = _activeDictationSession != nil

        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

        let totalProcessStart = Date()

        if !hasActiveDictationSession {
            guard nextBufferSeconds > delayInterval else {
                if currentText == "" {
                    currentText = "Waiting for speech..."
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }

            if settings.useVAD {
                let voiceDetected = AudioProcessor.isVoiceDetected(
                    in: audioProcessor.relativeEnergy,
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
        }

        lastBufferSize = currentBuffer.count

        let transcriptionStart = Date()
        let transcription: TranscriptionResult?
        if let session = _activeDictationSession,
           let recStart = dictationRecStart {
            // Real-time Qwen path: session was fed sample-by-sample during recording.
            // finish() consumes the prewarm cache (near-instant) or decodes now if no pause occurred.
            let recStop = dictationRecStop ?? Date()
            transcription = try await finishActiveDictationSession(
                session: session, recStart: recStart, recStop: recStop
            )
        } else if let qwen = sdkCoordinator.qwen {
            // Batch fallback (no active session -- e.g. beginQwenDictationSession was skipped).
            transcription = try await transcribeWithQwenDictation(qwen, bufferCopy) { [weak self] text in
                self?.currentText = text
            }
        } else {
            // WhisperKit (or Parakeet): heavy CPU work -- keep off main actor.
            transcription = try await Task.detached(priority: .userInitiated) { [weak self] () -> TranscriptionResult? in
                guard let self else { return nil }
                return try await self.transcribeAudioSamples(bufferCopy, options) { [weak self] joined in
                    self?.currentText = joined
                }
            }.value
        }
        let transcriptionEnd = Date()

        recordDetectedLanguage(transcription?.language)

        // MARK: Transcribe recording mode

        audioSampleDuration = TimeInterval(nextBufferSeconds)
        transcriptionDuration = transcriptionEnd.timeIntervalSince(transcriptionStart)

        // `showShortAudioToast` drives a SwiftUI alert; the view that observes it owns the
        // animation via `.animation(.easeInOut, value:)`. No `withAnimation` here keeps SwiftUI
        // imports out of the ViewModel.
        showShortAudioToast = nextBufferSeconds < 60

        // Skip diarization for Qwen dictation to keep post-SDK latency minimal.
        if diarizationMode != .disabled && qwenMetrics?.totalSeconds == nil {
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

        // Stamp app overhead for the Qwen dictation path: everything the UI waited for after
        // the SDK returned -- diarization, segment assembly, and state updates above.
        if var m = qwenMetrics, m.totalSeconds != nil {
            m.appOverheadSeconds = Date().timeIntervalSince(transcriptionEnd)
            qwenMetrics = m
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
        showShortAudioToast = audioSampleDuration < 60
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
        recordDetectedLanguage(transcription?.language)

        // Commit confirmed segments immediately -- before diarization -- so the
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
            // Stay in .transcribingAndDiarizing -- switching to .diarizing would reset the progress bar
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
        // Qwen runs as its own transcriber with a different API/result shape; route to it when loaded.
        if let qwen = sdkCoordinator.qwen {
            return try await transcribeWithQwen(qwen, samples, onTextUpdate: onTextUpdate)
        }
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
        let decodingCallback: @Sendable (TranscriptionProgress) -> Bool? = { progress in
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

        let sampleCount = samples.count
        let transcriptionResults: [TranscriptionResult]
        do {
            transcriptionResults = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options,
                callback: decodingCallback,
                segmentCallback: { [weak self, sampleCount] segments in
                    guard let self else { return }
                    let totalDuration = Double(sampleCount) / Double(WhisperKit.sampleRate)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.confirmedSegments = segments
                        if totalDuration > 0, let lastEnd = segments.last.map({ Double($0.end) }) {
                            let pct = Int(min(lastEnd / totalDuration, 0.99) * 100)
                            if self.pipelineProgress.transcription ?? 0 < pct {
                                self.pipelineProgress.transcription = pct
                            }
                        }
                    }
                }
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
            if vocabResults.isEmpty {
                Logging.info("[Custom Vocabulary] 0 replacements")
            } else {
                // `vocabResults` maps the *inserted* (boosted) word -> the list of baseline word(s)
                // it replaced. Print both sides so the swap is visible end-to-end.
                let pairs = vocabResults.map { inserted, originals -> String in
                    let originalText = originals.map { "'\($0.word)'" }.joined(separator: " + ")
                    return "\(originalText) -> '\(inserted.word)' (p=\(String(format: "%.3f", inserted.probability)))"
                }
                Logging.info("[Custom Vocabulary] \(vocabResults.count) replacement(s): \(pairs.joined(separator: ", "))")
            }
            customVocabularyResults = vocabResults
        }
        return mergedResults
    }

    /// Transcribes live-recorded audio using `QwenDictationSession`, which is purpose-built for
    /// the Dictate button flow. Unlike `transcribeWithQwen` (file path, batch `transcribe`),
    /// this feeds samples via `append()` and calls `prewarmFinalize()` + `finish()`, yielding
    /// finalization latency metrics that `makeStreamSession` cannot provide.
    private func transcribeWithQwenDictation(
        _ qwen: WhisperKitPro,
        _ samples: [Float],
        onTextUpdate: @escaping @MainActor (String) -> Void
    ) async throws -> TranscriptionResult? {
        let languageName: String? = settings.selectedLanguage == AppSettings.detectLanguageOption
            ? nil
            : settings.selectedLanguage.capitalized

        let audioSeconds = Double(samples.count) / Double(WhisperKit.sampleRate)
        qwenMetrics = QwenStreamMetrics()

        // feedStart declared before onHypothesis so the closure can timestamp relative to it.
        let feedStart = Date()
        let tsCapture = _DictateTimestamps()

        let session = try qwen.makeDictationSession(language: languageName, silenceThreshold: Float(settings.dictationSilenceThreshold))
        session.onHypothesis = { [tsCapture, feedStart] hypothesis in
            Task { @MainActor [tsCapture, feedStart] in
                // Stamp only the first hypothesis (fast-final candidate).
                if tsCapture.fastFinalApp == nil {
                    tsCapture.fastFinalApp = Date().timeIntervalSince(feedStart)
                }
                onTextUpdate(hypothesis)
            }
        }

        // Feed buffer in 1-second chunks (no progress bar -- hypothesis callbacks drive the UI).
        let stepSize = WhisperKit.sampleRate
        var offset = 0
        while offset < samples.count {
            let end = min(offset + stepSize, samples.count)
            try await session.append(samples: Array(samples[offset..<end]))
            offset = end
        }

        // Finalization: prewarm then finish, measuring latency from end of feeding.
        let finalizeStart = Date()
        await session.prewarmFinalize()
        let prewarmDone = Date()
        let finalText = try await session.finish()
        let finishDone = Date()

        onTextUpdate(finalText)

        let totalElapsed = finishDone.timeIntervalSince(feedStart)
        let finalizationLatency = finishDone.timeIntervalSince(finalizeStart)
        let prewarmLatency = prewarmDone.timeIntervalSince(finalizeStart)
        // RTF = processing over audio (lower is faster), consistent across all Qwen paths.
        let rtf = audioSeconds > 0 ? totalElapsed / audioSeconds : 0

        var metrics = QwenStreamMetrics()
        metrics.runningRTF = rtf
        metrics.rtfSeries = [rtf]
        metrics.audioSeconds = audioSeconds
        metrics.totalSeconds = totalElapsed
        metrics.exactFinalSeconds = finalizationLatency
        if session.consumedPrewarm {
            metrics.fastFinalSeconds = prewarmLatency
        }
        metrics.timelineFastFinalApp = tsCapture.fastFinalApp
        qwenMetrics = metrics

        let duration = Float(samples.count) / Float(WhisperKit.sampleRate)
        var timings = TranscriptionTimings()
        timings.fullPipeline = totalElapsed
        timings.inputAudioSeconds = audioSeconds
        let segment = TranscriptionSegment(start: 0, end: duration, text: finalText, words: nil)
        return TranscriptionResult(
            text: finalText,
            segments: [segment],
            language: languageName ?? "auto",
            timings: timings,
            seekTime: nil
        )
    }

    private func recordDetectedLanguage(_ language: String?) {
        guard let lang = language, !lang.isEmpty, lang != "auto" else { return }
        let normalized = lang.lowercased()
        detectedLanguage = normalized
        if !sessionLanguages.contains(normalized) {
            sessionLanguages.append(normalized)
        }
    }

    /// Transcribes a pre-recorded buffer with the Qwen3-ASR transcriber.
    ///
    /// Uses the batch `transcribe(audioArray:)`, which returns one segment per
    /// sentence with per-word timings on the recording's clock -- exactly what
    /// `DiarizationResult.addSpeakerInfo` needs.
    ///
    /// A single whole-recording segment must be avoided here: `.segment` speaker matching
    /// intersects each segment's span against the speaker timelines, so one big span
    /// collapses every voice into whichever speaker held the floor longest.
    private func transcribeWithQwen(
        _ qwen: WhisperKitPro,
        _ samples: [Float],
        onTextUpdate: @escaping @MainActor (String) -> Void
    ) async throws -> TranscriptionResult? {
        // Qwen wants a Title-Case language *name* ("English"), nil = auto-detect.
        let languageName: String? = settings.selectedLanguage == AppSettings.detectLanguageOption
            ? nil
            : settings.selectedLanguage.capitalized

        let audioSeconds = Double(samples.count) / Double(WhisperKit.sampleRate)
        var decodeOptions = DecodingOptions(wordTimestamps: true)
        decodeOptions.language = languageName

        // Segment discovery fires once per voice-activity chunk and is the only
        // progress signal the batch API exposes, so accumulate it to show text
        // appearing on long files instead of a frozen view.
        //
        // `SegmentDiscoveryCallback` is @Sendable and fires off the main actor,
        // so it must not capture `onTextUpdate` (a @MainActor closure) or self.
        // It yields into a stream that a single @MainActor consumer drains --
        // the same pattern the Whisper path above uses for window updates.
        let progressive = ProgressiveTranscript()
        let (updates, emit) = AsyncStream<(text: String, upTo: Double)>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await update in updates {
                onTextUpdate(update.text)
                if audioSeconds > 0 {
                    self?.pipelineProgress.transcription =
                        min(99, Int(update.upTo / audioSeconds * 100))
                }
            }
        }

        let results: [TranscriptionResult]
        do {
            results = try await qwen.transcribe(
                audioArray: samples,
                decodeOptions: decodeOptions,
                segmentCallback: { segments in
                    emit.yield(progressive.append(segments))
                }
            )
        } catch {
            emit.finish()
            await consumer.value
            throw error
        }
        emit.finish()
        await consumer.value

        pipelineProgress.transcription = 100
        guard let result = results.first else { return nil }
        onTextUpdate(result.text)
        return result
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
    
    /// Commits a rename for `speakerId` if `name` is non-empty (whitespace-stripped). Callers
    /// own the alert UI and the in-flight text-field state; the VM only persists the result.
    func applySpeakerRename(speakerId: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakerNames[speakerId] = trimmed
    }

    /// Raises a "user wants to rename speaker N" intent. Views observe `pendingSpeakerRename`
    /// and present their own alert; setting `pendingSpeakerRename = nil` dismisses it.
    func requestSpeakerRename(speakerId: Int) {
        pendingSpeakerRename = speakerId
    }
    
    func messageChainTimestamp(currentIndex: Int) -> String {
        guard !diarizedSpeakerSegments.isEmpty,
              currentIndex >= 0,
              currentIndex < diarizedSpeakerSegments.count
        else {
            return "[0.00 -> 0.00]"
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

        return "[\(String(format: "%.2f", chainStartTime)) -> \(String(format: "%.2f", chainEndTime))]"
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

/// Accumulates discovered segments during a batch Qwen transcription so the view
/// can show text appearing on a long file.
///
/// `segmentCallback` fires off the main actor and may fire concurrently, so the
/// state is lock-guarded rather than actor-isolated: the callback is
/// synchronous and cannot await.
private final class ProgressiveTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var furthestEnd: Double = 0

    /// Appends a batch of segments and returns the transcript so far, plus how
    /// far into the recording it now reaches.
    func append(_ segments: [TranscriptionSegment]) -> (text: String, upTo: Double) {
        lock.lock()
        defer { lock.unlock() }
        for segment in segments {
            text += segment.text
            furthestEnd = max(furthestEnd, Double(segment.end))
        }
        return (text, furthestEnd)
    }
}

/// Mutable timestamp bag shared between `transcribeWithQwenDictation` (MainActor) and the
/// `@Sendable` hypothesis closure. All writes happen inside `Task { @MainActor in }` and all
/// reads happen on the MainActor after those tasks have run, so the unchecked conformance is safe.
private final class _DictateTimestamps: @unchecked Sendable {
    var fastFinalApp: Double? = nil
}

