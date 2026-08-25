import Foundation
import Combine
import Argmax
import WhisperKit
import CoreAudio
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import ActivityKit
#endif

/// Live performance metrics for the Qwen3-ASR path, surfaced in the Stream and Transcribe tabs.
/// `nil` unless a Qwen session is/was active.
struct QwenStreamMetrics: Equatable {
    /// Duration of the recorded audio clip in seconds (dictate path). t=0 is recStart; rec stop lands at t=audioSeconds.
    var audioSeconds: Double?
    /// Total wall-clock from recStart to final result (audioSeconds + finish latency).
    var totalSeconds: Double?
    /// Duration of the prewarmFinalize() call fired during trailing silence (dictate path).
    var fastFinalSeconds: Double?
    /// Duration of the finish() call -- the user-perceived wait after the stop gesture (dictate path).
    var exactFinalSeconds: Double?
    /// Playground post-processing after SDK returns: diarization + segment assembly (dictate path only).
    var appOverheadSeconds: Double?
    /// Seconds from recStart when the first hypothesis Task ran on the MainActor (dictate path only).
    var timelineFastFinalApp: Double?
    var runningRTF: Double?
    var specDecMean: Double?
    var rtfSeries: [Double] = []
    var specDecSeries: [Double] = []
}

/// An `ObservableObject` that manages the state and logic for real-time audio streaming and transcription.
///
/// Uses session-based APIs (`TranscribeStreamSession` / `TranscribeDiarizeStreamSession`) for
/// both transcription and diarization. Each start creates fresh sessions with isolated diarizer state,
/// so no reconfiguration or reset is needed between start/stop cycles.
@MainActor
final class StreamViewModel: ObservableObject {
    /// Stream Results - per-stream data for UI
    @Published var deviceResult: StreamResult?
    @Published var systemResult: StreamResult?
    /// True once any result is initialized; only flips at session start/clear
    @Published var hasActiveResults: Bool = false
    /// Live device audio energy for waveform only; updated at poll rate to avoid re-rendering full result.
    @Published var deviceBufferEnergy: [Float] = []

    /// Live system/process-source audio energy for waveform only (macOS process tap). Mirrors
    /// `deviceBufferEnergy` but is computed from the source stream via `AudioProcessor` energy
    /// helpers, since the process tap has no built-in `relativeEnergy` like the device processor.
    @Published var systemBufferEnergy: [Float] = []

    // MARK: - Streaming Diarization

    /// Enable streaming diarization with Sortformer
    @Published var enableStreamingDiarization: Bool = false
    /// Latest diarization timings per source, updated on every combined result that carries timing data.
    /// Values are `StreamingDiarizationTimings` on macOS 15+ / iOS 18+, stored as `Any` for compatibility.
    @Published var lastDiarizationTimingsBySource: [String: Any] = [:]

    var deviceDiarizationTimings: StreamingDiarizationTimings? {
        lastDiarizationTimingsBySource.first { $0.key.starts(with: "device") }?.value as? StreamingDiarizationTimings
    }

    var systemDiarizationTimings: StreamingDiarizationTimings? {
        lastDiarizationTimingsBySource.first { !$0.key.starts(with: "device") }?.value as? StreamingDiarizationTimings
    }

    /// After stopTranscribing() completes, one URL per active source (device and/or system).
    /// Used to save one session per source with its own audio file.
    @Published var lastSessionAudioURLsBySource: [String: URL] = [:]
    /// Replay trace JSON URLs, one per source, populated alongside audio URLs after session ends.
    @Published var lastSessionTraceURLsBySource: [String: URL] = [:]

    private var traceEntriesBySource: [String: [StreamTraceEntry]] = [:]
    private var traceSessionStart: Date?
    private var pendingTraceComputeTime: TimeInterval?
    private var pendingTraceSpecDec: Double?
    private var pendingTraceAudioSeconds: TimeInterval?
    /// Set when a stream task fails mid-flight; observed by StreamTabView to reset recording state.
    @Published var streamTaskError: StreamingError?
    @Published var isStreaming: Bool = false

    /// One-shot signal: a fast stop->start hit the SDK's exclusive-decode gate because the
    /// previous Qwen session is still finalizing on the shared transcriber. The view shows a
    /// transient "Finalizing Stream" -> "Finalized Stream" button state instead of an error.
    @Published var transcriberBusyFinalizing: Bool = false

    // Live Activity Management (iOS only)
    #if os(iOS)
    let liveActivityManager: LiveActivityManager
    #endif
    
    #if os(macOS)
    let audioProcessDiscoverer: AudioProcessDiscoverer
    private var sleepObserver: (any NSObjectProtocol)?
    #endif
    let audioDeviceDiscoverer: AudioDeviceDiscoverer
    let sdkCoordinator: ArgmaxSDKCoordinator
    /// Mirrors `AppSettings.inverseTextNormalization` for the Live Activity hypothesis renderer,
    /// which runs inside the VM where settings are not directly accessible.
    var itnHighlight: Bool = false
    /// Mirrors `AppSettings.captureReplayTraces` (same pattern as `itnHighlight`). Off by
    /// default: traces accumulate per result for the whole session.
    var captureReplayTraces: Bool = false
    
    private var streamTasks: [Task<Void, Never>] = []
    /// Bumped at each session start; stream tasks capture the value at spawn and can be uniquely identified
    private var sessionGeneration = 0
    private var audioContinuations: [AsyncThrowingStream<[Float], Error>.Continuation] = []
    private var energyPollingTask: Task<Void, Never>?
    /// Underlying transcription sessions for each active stream -- kept here so settings changes
    /// (currently `minProcessInterval`) can hot-update the running session without forcing a
    /// stop/start cycle. The combined diarize+transcribe wrappers still own the same actor.
    private var activeTranscribeSessions: [TranscribeStreamSession] = []
    
    #if os(iOS)
    private var lastLiveActivityAudioUpdate: TimeInterval = 0
    private var lastAudioDataReceived: TimeInterval = 0
    private var interruptionMonitoringTask: Task<Void, Never>?
    /// Coalesces hypothesis-update calls: each tick cancels and replaces the prior pending task so
    /// we don't stack a Task per transcription event when the live activity is already throttling.
    private var liveActivityUpdateTask: Task<Void, Never>?
    #endif
    
    private var lastConfirmedTextBySource: [String: String] = [:]
    private var lastWaveformPublishTime: TimeInterval = 0
    private var confirmedResultCallback: ((String, TranscriptionResultPro) -> Void)?
    /// Registered by StreamTabView so external stops run the full stop path — history save and
    /// audio-session teardown — instead of a bare `stopTranscribing()`.
    var externalStopHandler: (() -> Void)?

    /// SDK emits one result per transcription update; speaker revisions carry `type == .speakerRevision`.
    /// Batches keyed by seekTime so speaker revision results replace the correct batch.
    private var confirmedBatchesBySource: [String: [(seekTime: Float, segments: [TranscriptionSegment], words: [WordWithSpeaker])]] = [:]

    private var audioWritersBySource: [String: AudioFileWriter] = [:]

    // MARK: - Qwen streaming

    /// Max points retained per metric series.
    private static let qwenSeriesCap = 300
    @Published var qwenStreamMetrics: QwenStreamMetrics?
    /// Cumulative compute seconds and audio seconds since the current Qwen session started.
    /// Used to produce the per-step RTF from SDK `onMetrics` callbacks.
    private var qwenCumulativeCompute: Double = 0
    private var qwenCumulativeSeconds: Double = 0
    /// Sample count behind `QwenStreamMetrics.specDecMean`'s incremental mean.
    private var qwenSpecDecCount: Int = 0

    // MARK: - Language Detection

    /// Most recently detected language (lowercase). Reset when results are cleared.
    @Published var detectedLanguage: String?
    /// All distinct languages detected so far this session, in order of first appearance.
    @Published var sessionLanguages: [String] = []

    /// Standalone WhisperKit `AudioProcessor` instances used to capture audio for Qwen (one per active
    /// device source). Process-tap sources do not have an AudioProcessor; they're stopped via their
    /// continuations, which are held in `audioContinuations` like all other sources.
    private var qwenAudioProcessors: [AudioProcessor] = []

    // MARK: - Audio Source Info

    /// Represents an audio source with its stream and metadata for session-based processing
    private struct AudioSourceInfo {
        let id: String
        let isDevice: Bool
        let audioStream: AsyncThrowingStream<[Float], Error>
        let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    }

    /// Computes audio streams from active input sources (device mic, process tapper, etc.)
    private func computeActiveAudioStreams(whisperKitPro: WhisperKitPro) async throws -> [AudioSourceInfo] {
        #if os(macOS)
        var result: [AudioSourceInfo] = []
        if let selectedDeviceID = audioDeviceDiscoverer.selectedDeviceID {
            let availableDevices = AudioProcessor.getAudioDevices()
            if availableDevices.contains(where: { $0.id == selectedDeviceID }) {
                Logging.debug("Creating device stream for valid device ID: \(selectedDeviceID)")
                let (rawStream, continuation) = whisperKitPro.audioProcessor.startStreamingRecordingLive(inputDeviceID: selectedDeviceID)
                result.append(AudioSourceInfo(
                    id: "device-\(selectedDeviceID)",
                    isDevice: true,
                    audioStream: rawStream,
                    continuation: continuation
                ))
            } else {
                let deviceName = audioDeviceDiscoverer.selectedAudioInput
                Logging.error("Selected device '\(deviceName)' (ID: \(selectedDeviceID)) is not available in current audio devices")
                throw StreamingError.deviceNotAvailable(deviceName: deviceName)
            }
        }
        if let processTapper = audioProcessDiscoverer.processTapper {
            let selectedProcess = audioProcessDiscoverer.selectedProcessForStream
            if selectedProcess != .noAudio {
                selectedProcess.updateIsRunning()
                if selectedProcess.isRunning {
                    Logging.debug("Creating process stream for valid process: \(selectedProcess.name)")
                    let (rawTapperStream, tapperContinuation) = await Task.detached {
                        return processTapper.startTapStream()
                    }.value
                    result.append(AudioSourceInfo(
                        id: "process-\(selectedProcess.name)",
                        isDevice: false,
                        audioStream: rawTapperStream,
                        continuation: tapperContinuation
                    ))
                } else {
                    Logging.error("Selected process '\(selectedProcess.name)' is no longer running")
                    throw StreamingError.processNotAvailable(processName: selectedProcess.name)
                }
            }
        }
        #else
        let (rawStream, continuation) = await Task.detached {
            return whisperKitPro.audioProcessor.startStreamingRecordingLive()
        }.value
        var result: [AudioSourceInfo] = [AudioSourceInfo(
            id: "device",
            isDevice: true,
            audioStream: rawStream,
            continuation: continuation
        )]
        #endif
        return result
    }

    private func audioStreamRecordingToFile(
        _ base: AsyncThrowingStream<[Float], Error>,
        writer: AudioFileWriter
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in base {
                        writer.append(samples: chunk)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Passthrough that computes per-chunk relative energy for a non-device (system/process)
    /// source and publishes a rolling window to `systemBufferEnergy`, so the system waveform
    /// renders live with the same green/gray silence-threshold coloring as the device source.
    ///
    /// Overhead is negligible: `AudioProcessor.calculateEnergy`/`calculateRelativeEnergy` are
    /// Accelerate (vDSP, SIMD) O(n) passes over ~0.1s chunks (~1600 samples) at ~10 chunks/s,
    /// and publishing is throttled to 3 Hz. It never blocks the SDK consumer -- the chunk is
    /// yielded downstream first, then energy is computed.
    private func audioStreamComputingSystemEnergy(
        _ base: AsyncThrowingStream<[Float], Error>
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                var rolling: [Float] = []
                var minAvgEnergy: Float = .infinity
                var lastPublish: TimeInterval = 0
                do {
                    for try await chunk in base {
                        continuation.yield(chunk)
                        let signal = AudioProcessor.calculateEnergy(of: chunk)
                        minAvgEnergy = Swift.min(minAvgEnergy, signal.avg)
                        let rel = AudioProcessor.calculateRelativeEnergy(of: chunk, relativeTo: minAvgEnergy)
                        rolling.append(rel)
                        if rolling.count > AudioConstants.energyHistoryLimit {
                            rolling.removeFirst(rolling.count - AudioConstants.energyHistoryLimit)
                        }
                        let now = Date().timeIntervalSince1970
                        if now - lastPublish >= 1.0 / 3.0 {
                            lastPublish = now
                            let snapshot = rolling
                            await MainActor.run { self?.systemBufferEnergy = snapshot }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns the stream result for the given source (for session history save).
    func result(for sourceId: String) -> StreamResult? {
        if isDeviceSource(sourceId) {
            return deviceResult
        }
        return systemResult
    }

    #if os(macOS)
    init(sdkCoordinator: ArgmaxSDKCoordinator, audioProcessDiscoverer: AudioProcessDiscoverer, audioDeviceDiscoverer: AudioDeviceDiscoverer) {
        self.sdkCoordinator = sdkCoordinator
        self.audioProcessDiscoverer = audioProcessDiscoverer
        self.audioDeviceDiscoverer = audioDeviceDiscoverer
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStreaming else { return }
                if let stopHandler = self.externalStopHandler {
                    stopHandler()
                } else {
                    await self.stopTranscribing()
                }
            }
        }
    }

    deinit {
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    #else
    init(sdkCoordinator: ArgmaxSDKCoordinator, audioDeviceDiscoverer: AudioDeviceDiscoverer, liveActivityManager: LiveActivityManager) {
        self.sdkCoordinator = sdkCoordinator
        self.audioDeviceDiscoverer = audioDeviceDiscoverer
        self.liveActivityManager = liveActivityManager
        observeStopTranscriptionIntent()
    }

    /// Raw-string Notification.Name matched by `StopTranscriptionIntent.perform()`. Kept inline
    /// so neither side depends on a shared typed extension.
    private static let stopTranscriptionNotification = Notification.Name(
        "com.argmax.playground.stopTranscriptionRequested"
    )

    private var stopIntentObserver: (any NSObjectProtocol)?

    private func observeStopTranscriptionIntent() {
        stopIntentObserver = NotificationCenter.default.addObserver(
            forName: Self.stopTranscriptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStreaming else { return }
                if let stopHandler = self.externalStopHandler {
                    stopHandler()
                } else {
                    await self.stopTranscribing()
                }
            }
        }
    }

    deinit {
        if let observer = stopIntentObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    #endif

    /// Contains all transcription data for a single stream including text results, timing information, and audio energy data
    struct StreamResult: Equatable {
        var title: String = ""
        var confirmedSegments: [TranscriptionSegment] = []
        var hypothesisSegments: [TranscriptionSegment] = []
        var customVocabularyResults: VocabularyResults = [:]
        var streamEndSeconds: Float?
        var bufferEnergy: [Float] = []

        /// Words with speaker assignments from diarization
        var confirmedWordsWithSpeakers: [WordWithSpeaker] = []
        var hypothesisWordsWithSpeakers: [WordWithSpeaker] = []

        var streamTimestampText: String {
            guard let end = streamEndSeconds else {
                return ""
            }
            return "[0 --> \(String(format: "%.2f", end))] "
        }

        // bufferEnergy excluded -- WaveformSection reads energy from a separate source.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title &&
            lhs.confirmedSegments == rhs.confirmedSegments &&
            lhs.hypothesisSegments == rhs.hypothesisSegments &&
            lhs.customVocabularyResults == rhs.customVocabularyResults &&
            lhs.streamEndSeconds == rhs.streamEndSeconds &&
            lhs.confirmedWordsWithSpeakers == rhs.confirmedWordsWithSpeakers &&
            lhs.hypothesisWordsWithSpeakers == rhs.hypothesisWordsWithSpeakers
        }
    }

    /// Clears all transcription results for both device and system streams
    func clearAllResults() {
        deviceResult = nil
        systemResult = nil
        hasActiveResults = false
        isStreaming = false
        lastDiarizationTimingsBySource = [:]
        streamTaskError = nil
        qwenStreamMetrics = nil
        qwenCumulativeCompute = 0
        qwenCumulativeSeconds = 0
        qwenSpecDecCount = 0
        detectedLanguage = nil
        sessionLanguages = []
    }
    
    /// Sets a callback function to be invoked when transcription results are confirmed
    /// - Parameter confirmedResultCallback: Callback function that receives the source ID and transcription result
    func setConfirmedResultCallback(confirmedResultCallback: @escaping (String, TranscriptionResultPro) -> Void) {
        self.confirmedResultCallback = confirmedResultCallback
    }

    /// Starts transcription for all active stream sources using session-based APIs.
    ///
    /// For device streams with diarization enabled, creates a `TranscribeDiarizeStreamSession`
    /// via `SpeakerKitPro.makeStreamSession()`. Each session gets its own diarizer instance,
    /// so no global state reset is needed between start/stop cycles.
    ///
    /// - Parameters:
    ///   - options: Decoding options to configure the transcription process
    ///   - saveAudioToFile: When true, writes each source's audio to a temp file; after stop, see `lastSessionAudioURLsBySource`
    /// - Throws: `StreamingError` if no sources are selected or if audio devices/processes are not available
    func startTranscribing(options: DecodingOptionsPro, diarizationOptions: (any DiarizationOptions)? = nil, saveAudioToFile: Bool = false) async throws {
        // stopTranscribing() yields at its `await task.value` loop. A rapid stop->start can
        // schedule both functions concurrently on the MainActor; without this drain the stop
        // resumes later and tears down continuations/tasks that start already set up.
        let priorTasks = streamTasks
        streamTasks = []
        for task in priorTasks { _ = await task.value }
        sessionGeneration += 1

        guard let whisperKitPro = sdkCoordinator.whisperKit else {
            throw WhisperError.transcriptionFailed("No transcriber found")
        }

        var audioSources = try await computeActiveAudioStreams(whisperKitPro: whisperKitPro)

        guard !audioSources.isEmpty else {
            throw StreamingError.noSourcesSelected
        }

        if saveAudioToFile {
            let sampleRate = Double(WhisperKit.sampleRate)
            for i in audioSources.indices {
                let writer = AudioFileWriter(sampleRate: sampleRate)
                let source = audioSources[i]
                audioWritersBySource[source.id] = writer
                audioSources[i] = AudioSourceInfo(
                    id: source.id,
                    isDevice: source.isDevice,
                    audioStream: audioStreamRecordingToFile(source.audioStream, writer: writer),
                    continuation: source.continuation
                )
            }
        }

        audioContinuations = audioSources.map { $0.continuation }

        let capturedAudioSources = audioSources

        deviceResult = nil
        systemResult = nil
        hasActiveResults = false
        deviceBufferEnergy = []
        systemBufferEnergy = []
        lastWaveformPublishTime = 0
        lastConfirmedTextBySource = [:]
        confirmedBatchesBySource = [:]
        lastSessionAudioURLsBySource = [:]
        lastSessionTraceURLsBySource = [:]
        traceEntriesBySource = [:]
        traceSessionStart = Date()
        pendingTraceComputeTime = nil
        pendingTraceSpecDec = nil
        pendingTraceAudioSeconds = nil

        for source in capturedAudioSources {
            #if os(macOS)
            if source.isDevice {
                deviceResult = StreamResult(
                    title: "Device: \(audioDeviceDiscoverer.selectedAudioInput)"
                )
            } else {
                systemResult = StreamResult(
                    title: "System: \(audioProcessDiscoverer.selectedProcessForStream.name)"
                )
            }
            #else
            if source.isDevice {
                deviceResult = StreamResult(title: "")
            }
            #endif
        }
        hasActiveResults = deviceResult != nil || systemResult != nil

        startEnergyPolling(whisperKitPro: whisperKitPro)
        
        #if os(iOS)
        do {
            try await liveActivityManager.startActivity()
            startInterruptionMonitoring()
        } catch {
            Logging.error("Failed to start live activity: \(error)")
        }
        #endif
        
        let useDiarization = enableStreamingDiarization
        let capturedSpeakerKit = useDiarization ? sdkCoordinator.speakerKit : nil
        let capturedDiarizationOptions: any DiarizationOptions = diarizationOptions ?? SortformerDiarizationOptions(
            sortformerMode: sdkCoordinator.currentSortformerMode.config(isRealtimeMode: true)
        )

        for source in audioSources {
            let writer = audioWritersBySource[source.id]
            let sourceId = source.id
            // Non-device (system/process) sources get a live energy passthrough so their waveform
            // renders like the device source; device energy comes from the shared audio processor.
            let inputStream = source.isDevice
                ? source.audioStream
                : audioStreamComputingSystemEnergy(source.audioStream)
            let task = Task.detached { [weak self] in
                guard let self else { return }
                do {
                    if useDiarization, let speakerKit = capturedSpeakerKit {
                        let transcribeSession = whisperKitPro.makeStreamSession(options: options)
                        await self.registerTranscribeSession(transcribeSession)
                        let diarizationConfig = capturedDiarizationOptions as? SortformerDiarizationOptions ?? SortformerDiarizationOptions()
                        let combinedSession = try await speakerKit.makeStreamSession(
                            transcriptionSession: transcribeSession,
                            diarizationConfig: diarizationConfig
                        )
                        await combinedSession.start(audioInputStream: inputStream)

                        for try await result in combinedSession.results {
                            await self.handleCombinedResult(result, for: sourceId)
                        }
                    } else {
                        let transcribeSession = whisperKitPro.makeStreamSession(options: options)
                        await self.registerTranscribeSession(transcribeSession)
                        await transcribeSession.start(audioInputStream: inputStream)

                        for try await result in transcribeSession.results {
                            await self.handleTranscriptionResult(result, for: sourceId)
                        }
                    }
                } catch {
                    Logging.error("Stream \(sourceId) failed: \(error)")
                    let streamingErr = error as? StreamingError ?? .deviceNotAvailable(deviceName: sourceId)
                    await MainActor.run { [weak self] in
                        self?.streamTaskError = streamingErr
                    }
                }
                if let w = writer {
                    let url = w.finalize()
                    await MainActor.run {
                        self.lastSessionAudioURLsBySource[sourceId] = url
                    }
                }
                await MainActor.run {
                    if let entries = self.traceEntriesBySource[sourceId], !entries.isEmpty,
                       let start = self.traceSessionStart {
                        if let traceURL = self.writeTrace(entries: entries, start: start) {
                            self.lastSessionTraceURLsBySource[sourceId] = traceURL
                        }
                    }
                }
            }
            self.streamTasks.append(task)
        }
        isStreaming = true
    }

    // MARK: - Qwen Streaming

    /// Starts a real-time Qwen3-ASR stream using the unified `TranscribeStreamSession` API.
    /// Qwen is a standalone transcriber (`sdkCoordinator.qwen`) with no WhisperKitPro audio processor.
    /// On iOS the device microphone is the only source. On macOS, both a selected audio device (mic)
    /// and a selected process tap (system audio) are supported simultaneously.
    ///
    /// - Parameters:
    ///   - options: Streaming options (mode, language, word timestamps).
    ///   - saveAudioToFile: When true, mirrors captured audio to a temp file for session history.
    func startQwenTranscribing(options: DecodingOptionsPro, diarizationOptions: (any DiarizationOptions)? = nil, saveAudioToFile: Bool) async throws {
        // Same drain as startTranscribing(): serialize with any concurrent stopTranscribing().
        let priorTasks = streamTasks
        streamTasks = []
        for task in priorTasks { _ = await task.value }
        sessionGeneration += 1
        let generation = sessionGeneration

        guard let qwen = sdkCoordinator.qwen else {
            throw WhisperError.transcriptionFailed("No Qwen transcriber loaded")
        }

        // Compute audio sources. On macOS: device mic and/or process tap (both may be active).
        // On iOS: single device mic, no process tap API.
        qwenAudioProcessors = []
        var audioSources: [AudioSourceInfo] = []
        #if os(macOS)
        if let deviceID = audioDeviceDiscoverer.selectedDeviceID {
            let available = AudioProcessor.getAudioDevices()
            if available.contains(where: { $0.id == deviceID }) {
                let processor = AudioProcessor()
                qwenAudioProcessors.append(processor)
                // Detached like the iOS mic and process-tap paths below: starting the audio
                // engine is a synchronous AVAudioEngine/CoreAudio call, and this function runs
                // on the MainActor, so calling it inline stalls the UI for the duration.
                let (stream, cont) = await Task.detached {
                    processor.startStreamingRecordingLive(inputDeviceID: deviceID)
                }.value
                audioSources.append(AudioSourceInfo(
                    id: "device-\(deviceID)", isDevice: true, audioStream: stream, continuation: cont
                ))
            } else {
                throw StreamingError.deviceNotAvailable(deviceName: audioDeviceDiscoverer.selectedAudioInput)
            }
        }
        if let tapper = audioProcessDiscoverer.processTapper {
            let proc = audioProcessDiscoverer.selectedProcessForStream
            if proc != .noAudio {
                proc.updateIsRunning()
                if proc.isRunning {
                    Logging.debug("Creating Qwen process stream for: \(proc.name)")
                    let (stream, cont) = await Task.detached { tapper.startTapStream() }.value
                    audioSources.append(AudioSourceInfo(
                        id: "process-\(proc.name)", isDevice: false, audioStream: stream, continuation: cont
                    ))
                } else {
                    Logging.error("Selected process '\(proc.name)' is no longer running")
                    // Stop the already-recording processors before throwing so the mic doesn't stay on.
                    qwenAudioProcessors.forEach { $0.stopRecording() }
                    qwenAudioProcessors = []
                    audioSources.forEach { $0.continuation.finish() }
                    throw StreamingError.processNotAvailable(processName: proc.name)
                }
            }
        }
        guard !audioSources.isEmpty else { throw StreamingError.noSourcesSelected }
        #else
        let processor = AudioProcessor()
        qwenAudioProcessors = [processor]
        let (iosStream, iosCont) = await Task.detached {
            return processor.startStreamingRecordingLive()
        }.value
        audioSources = [AudioSourceInfo(id: "device", isDevice: true, audioStream: iosStream, continuation: iosCont)]
        #endif

        // Reset per-session state.
        deviceResult = nil
        systemResult = nil
        hasActiveResults = false
        deviceBufferEnergy = []
        systemBufferEnergy = []
        lastWaveformPublishTime = 0
        lastConfirmedTextBySource = [:]
        confirmedBatchesBySource = [:]
        lastSessionAudioURLsBySource = [:]
        lastSessionTraceURLsBySource = [:]
        traceEntriesBySource = [:]
        traceSessionStart = Date()
        pendingTraceComputeTime = nil
        pendingTraceSpecDec = nil
        pendingTraceAudioSeconds = nil
        qwenStreamMetrics = QwenStreamMetrics()
        // Reset the accumulators that back the metrics we just cleared. Without this the RTF and
        // spec-decode mean carry over from the previous session whenever the caller starts
        // without going through clearAllResults() first.
        qwenCumulativeCompute = 0
        qwenCumulativeSeconds = 0
        qwenSpecDecCount = 0

        // Initialize a StreamResult for each active source.
        for source in audioSources {
            if source.isDevice {
                #if os(macOS)
                deviceResult = StreamResult(title: "Device: \(audioDeviceDiscoverer.selectedAudioInput)")
                #else
                deviceResult = StreamResult(title: "")
                #endif
            } else {
                #if os(macOS)
                systemResult = StreamResult(title: "System: \(audioProcessDiscoverer.selectedProcessForStream.name)")
                #endif
            }
        }
        hasActiveResults = deviceResult != nil || systemResult != nil
        audioContinuations = audioSources.map { $0.continuation }

        // Energy polling from the first device AudioProcessor (if any).
        if let firstProcessor = qwenAudioProcessors.first {
            startQwenEnergyPolling(audioProcessor: firstProcessor)
        }

        #if os(iOS)
        do {
            try await liveActivityManager.startActivity()
            startInterruptionMonitoring()
        } catch {
            Logging.error("Failed to start live activity: \(error)")
        }
        #endif

        let useDiarization = enableStreamingDiarization
        let capturedSpeakerKit = useDiarization ? sdkCoordinator.speakerKit : nil
        let capturedDiarizationOptions: any DiarizationOptions = diarizationOptions ?? SortformerDiarizationOptions(
            sortformerMode: sdkCoordinator.currentSortformerMode.config(isRealtimeMode: true)
        )

        for source in audioSources {
            var audioStream = source.audioStream
            if saveAudioToFile {
                let w = AudioFileWriter(sampleRate: Double(WhisperKit.sampleRate))
                audioWritersBySource[source.id] = w
                audioStream = audioStreamRecordingToFile(audioStream, writer: w)
            }
            // Non-device (system/process) sources get a live energy passthrough so their waveform
            // renders like the device source; device energy comes from the polled audio processor.
            if !source.isDevice {
                audioStream = audioStreamComputingSystemEnergy(audioStream)
            }
            let capturedStream = audioStream
            let capturedWriter = audioWritersBySource[source.id]
            let sourceId = source.id
            let task = Task.detached { [weak self] in
                guard let self else { return }
                do {
                    if useDiarization, let speakerKit = capturedSpeakerKit {
                        let transcribeSession = qwen.makeStreamSession(options: options, onMetrics: { [weak self] m in
                            Task { @MainActor [weak self] in self?.acceptQwenUpdateMetrics(m) }
                        })
                        await self.registerTranscribeSession(transcribeSession)
                        let diarizationConfig = capturedDiarizationOptions as? SortformerDiarizationOptions ?? SortformerDiarizationOptions()
                        let combinedSession = try await speakerKit.makeStreamSession(
                            transcriptionSession: transcribeSession,
                            diarizationConfig: diarizationConfig
                        )
                        // start() blocks; iterate results concurrently.
                        async let startDone: Void = combinedSession.start(audioInputStream: capturedStream)
                        for try await result in combinedSession.results {
                            await self.handleCombinedResult(result, for: sourceId)
                        }
                        // Detect premature result-sequence termination (SDK stall, not user stop).
                        // On normal stop, stopTranscribing() sets isStreaming=false before closing
                        // the continuation, so this check will be false by the time we reach here.
                        // The generation check ignores tasks from a previous session.
                        if await MainActor.run(body: { self.isStreaming && self.sessionGeneration == generation }) {
                            Logging.error("Qwen stream \(sourceId): combined results ended while still streaming")
                            await MainActor.run { [weak self] in
                                self?.streamTaskError = .streamFailed(reason: "Transcription session ended unexpectedly. Please restart.")
                            }
                        }
                        _ = await startDone
                    } else {
                        let session = qwen.makeStreamSession(options: options, onMetrics: { [weak self] m in
                            Task { @MainActor [weak self] in self?.acceptQwenUpdateMetrics(m) }
                        })
                        await self.registerTranscribeSession(session)
                        // start() blocks until the audio stream closes; iterate results
                        // concurrently so hypothesis/confirmed text flows during the session.
                        async let startDone: Void = session.start(audioInputStream: capturedStream)
                        for try await result in session.results {
                            await self.handleTranscriptionResult(result, for: sourceId)
                        }
                        // Detect premature result-sequence termination (SDK stall, not user stop).
                        if await MainActor.run(body: { self.isStreaming && self.sessionGeneration == generation }) {
                            Logging.error("Qwen stream \(sourceId): results ended while still streaming")
                            await MainActor.run { [weak self] in
                                self?.streamTaskError = .streamFailed(reason: "Transcription session ended unexpectedly. Please restart.")
                            }
                        }
                        _ = await startDone
                    }
                } catch {
                    if Self.isTranscriberBusyError(error) {
                        // Fast stop->start: the previous session is still draining on the shared
                        // transcriber's exclusive-decode gate. Surface it as a transient "finalizing"
                        // state (not a hard error) and tear down this half-started session.
                        Logging.info("Qwen stream \(sourceId): transcriber busy, previous session still finalizing")
                        // One-shot: only the first reporting source flips the signal; the view
                        // responds by draining the half-started session via stopStream(save:).
                        await MainActor.run { [weak self] in self?.transcriberBusyFinalizing = true }
                    } else {
                        Logging.error("Qwen stream \(sourceId) failed: \(error)")
                        await MainActor.run { [weak self] in
                            self?.streamTaskError = .streamFailed(reason: error.localizedDescription)
                        }
                    }
                }
                if let w = capturedWriter {
                    let url = w.finalize()
                    await MainActor.run { self.lastSessionAudioURLsBySource[sourceId] = url }
                }
                await MainActor.run {
                    if let entries = self.traceEntriesBySource[sourceId], !entries.isEmpty,
                       let start = self.traceSessionStart {
                        if let traceURL = self.writeTrace(entries: entries, start: start) {
                            self.lastSessionTraceURLsBySource[sourceId] = traceURL
                        }
                    }
                }
            }
            streamTasks.append(task)
        }
        isStreaming = true
    }

    /// Polls the standalone Qwen audio processor for waveform energy and updates live RTF. Reuses
    /// `energyPollingTask` so the generic `stopTranscribing` cancellation applies unchanged.
    private func startQwenEnergyPolling(audioProcessor: AudioProcessor) {
        energyPollingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.pollQwenEnergy(audioProcessor: audioProcessor)
                try? await Task.sleep(nanoseconds: 100_000_000) // 10 Hz
            }
        }
    }

    @MainActor private func pollQwenEnergy(audioProcessor: AudioProcessor) {
        // isStreaming is set to false before energyPollingTask.cancel() in stopTranscribing(),
        // so any already-queued MainActor hop from the polling task sees this guard and returns
        // without overwriting the deviceBufferEnergy = [] that stopTranscribing() just set.
        guard isStreaming else { return }

        #if os(iOS)
        lastAudioDataReceived = Date().timeIntervalSince1970
        #endif

        let energies = audioProcessor.relativeEnergy
        let newBufferEnergy = Array(energies.suffix(AudioConstants.energyHistoryLimit))
        let now = Date().timeIntervalSince1970
        if now - lastWaveformPublishTime >= 1.0 / 3.0 {
            deviceBufferEnergy = newBufferEnergy
            lastWaveformPublishTime = now
        }

        #if os(iOS)
        // Push the elapsed duration to the Live Activity, mirroring `pollEnergy` on the WhisperKit
        // path. Without this the Qwen real-time path never sent `audioSeconds`, so the Dynamic
        // Island's duration sat at the 0.0 the activity was started with.
        if liveActivityManager.isActivityRunning && now - lastLiveActivityAudioUpdate >= 1 {
            lastLiveActivityAudioUpdate = now
            let audioSeconds = Double(audioProcessor.audioSamples.count) / Double(WhisperKit.sampleRate)

            Task {
                await liveActivityManager.updateContentState { oldState in
                    var state = oldState
                    state.audioSeconds = audioSeconds
                    state.isInterrupted = false
                    return state
                }
            }
        }
        #endif
    }

    /// Appends a per-step RTF sample (compute seconds / audio seconds, from `onMetrics`) to
    /// the sparkline series and updates the running scalar shown in the collapsed strip.
    @MainActor private func updateQwenRTF(_ rtf: Double) {
        var m = qwenStreamMetrics ?? QwenStreamMetrics()
        m.runningRTF = rtf
        m.rtfSeries.append(rtf)
        if m.rtfSeries.count > Self.qwenSeriesCap {
            m.rtfSeries.removeFirst(m.rtfSeries.count - Self.qwenSeriesCap)
        }
        qwenStreamMetrics = m
    }

    /// Records a speculative-decode tokens-per-step sample from `onMetrics`: maintains a
    /// running mean and appends to the sparkline series.
    @MainActor private func updateQwenSpecDec(_ tokPerStep: Double) {
        var m = qwenStreamMetrics ?? QwenStreamMetrics()
        // True incremental mean over the session. `(prev + new) / 2` is an EMA with alpha 0.5,
        // which tracks the last two or three samples rather than the session, so the strip
        // labelled "mean" swung with every update.
        qwenSpecDecCount += 1
        let mean = m.specDecMean ?? 0
        m.specDecMean = mean + (tokPerStep - mean) / Double(qwenSpecDecCount)
        m.specDecSeries.append(tokPerStep)
        if m.specDecSeries.count > Self.qwenSeriesCap {
            m.specDecSeries.removeFirst(m.specDecSeries.count - Self.qwenSeriesCap)
        }
        qwenStreamMetrics = m
    }

    /// Records a detected language for the session chips (first appearance order preserved).
    private func recordDetectedLanguage(_ language: String?) {
        guard let lang = language, !lang.isEmpty, lang != "auto" else { return }
        let normalized = lang.lowercased()
        detectedLanguage = normalized
        if !sessionLanguages.contains(normalized) {
            sessionLanguages.append(normalized)
        }
    }

    /// Ingests one SDK `onMetrics` callback, accumulates compute/audio seconds, and updates
    /// the RTF and SpecDec sparklines. Called via a `Task { @MainActor }` dispatch from the
    /// `@Sendable` closure passed to `makeStreamSession(options:onMetrics:)`.
    @MainActor private func acceptQwenUpdateMetrics(_ m: Qwen3ASRUpdateMetrics) {
        qwenCumulativeCompute += m.computeTime
        qwenCumulativeSeconds += m.seconds
        let rtf = qwenCumulativeCompute / max(qwenCumulativeSeconds, .leastNonzeroMagnitude)
        updateQwenRTF(rtf)
        if let tps = m.specDecTokensPerStep {
            updateQwenSpecDec(tps)
        }
        pendingTraceComputeTime = m.computeTime
        pendingTraceSpecDec = m.specDecTokensPerStep
        pendingTraceAudioSeconds = m.seconds
    }

    /// Records one replay-trace entry for `sourceId`, pairing the result text with whatever
    /// `onMetrics` last reported and consuming that reading so it is attributed once.
    ///
    /// No-op until a session sets `traceSessionStart`. Metrics and results arrive on independent
    /// schedules, so the pairing is best-effort: two metrics callbacks between results drop the
    /// older reading, and two results between metrics leave the second with nils. The trace is a
    /// debugging aid, not an accounting record.
    @MainActor private func appendTraceEntry(
        sourceId: String,
        confirmedText: String,
        hypothesisSegments: [TranscriptionSegment]
    ) {
        guard captureReplayTraces, let start = traceSessionStart else { return }
        let entry = StreamTraceEntry(
            wallOffset: Date().timeIntervalSince(start),
            confirmedText: confirmedText,
            hypothesisText: hypothesisSegments.map(\.text).joined(separator: " "),
            computeTime: pendingTraceComputeTime,
            specDecTokensPerStep: pendingTraceSpecDec,
            audioSeconds: pendingTraceAudioSeconds,
            runningRTF: qwenStreamMetrics?.runningRTF
        )
        traceEntriesBySource[sourceId, default: []].append(entry)
        pendingTraceComputeTime = nil
        pendingTraceSpecDec = nil
        pendingTraceAudioSeconds = nil
    }

    @MainActor private func writeTrace(entries: [StreamTraceEntry], start: Date) -> URL? {
        let modelName = sdkCoordinator.whisperKit?.modelFolder?.lastPathComponent ?? "qwen3-asr"
        return StreamTrace.write(model: modelName, startedAt: start, entries: entries)
    }

    func stopTranscribing() async {
        isStreaming = false

        // Atomically capture and clear all shared mutable collections BEFORE any yield.
        // startTranscribing/startQwenTranscribing can interleave at the first `await` below;
        // by pre-clearing these collections we ensure the new session's tasks, sessions, and
        // processors are never touched by our post-drain cleanup.
        let tasksToWait = streamTasks
        let continuationsToClose = audioContinuations
        let qwenProcs = qwenAudioProcessors
        streamTasks = []
        audioContinuations = []
        qwenAudioProcessors = []
        activeTranscribeSessions = []
        audioWritersBySource = [:]

        sdkCoordinator.whisperKit?.audioProcessor.stopRecording()
        qwenProcs.forEach { $0.stopRecording() }

        // Closing continuations unblocks the result iterators in the stream tasks.
        continuationsToClose.forEach { $0.finish() }

        energyPollingTask?.cancel()
        energyPollingTask = nil
        // deviceBufferEnergy is cleared after drain too; setting here first so any frame
        // rendered between now and the drain doesn't flash the live waveform indicator.
        deviceBufferEnergy = []
        systemBufferEnergy = []

        // Drain captured tasks. This is the only yield point; startTranscribing() may run here.
        // All our cleanup uses captured locals so it cannot affect the newly started session.
        for task in tasksToWait {
            _ = await task.value
        }

        // A new session may have restarted streaming already; if so, it owns this state.
        if !isStreaming {
            // Re-clear in case a queued energy poll landed during the drain above.
            deviceBufferEnergy = []
            systemBufferEnergy = []
            if var r = deviceResult {
                r.hypothesisSegments = []
                r.hypothesisWordsWithSpeakers = []
                r.bufferEnergy = []
                deviceResult = r
            }
            if var r = systemResult {
                r.hypothesisSegments = []
                r.hypothesisWordsWithSpeakers = []
                r.bufferEnergy = []
                systemResult = r
            }

            #if os(iOS)
            liveActivityUpdateTask?.cancel()
            liveActivityUpdateTask = nil
            // `.immediate` clears the activity from Lock Screen / Dynamic Island / the Mac mirror
            // right when recording ends. The `.default` policy keeps it visible for up to ~4 hours
            // after `end()` so users can see the final state -- fine for a finished timer, wrong for
            // a "transcription is running" indicator that has stopped running.
            await liveActivityManager.stopActivity(dismissalPolicy: .immediate)
            stopInterruptionMonitoring()
            #endif

            // Reset WhisperKit's shared internal state (currentTimings, audio processor) so the next
            // session gets a clean baseline. No-op if Qwen is the active transcriber.
            sdkCoordinator.whisperKit?.clearState()
        }

        Logging.debug("Stopped all transcription streams")
    }

    // MARK: - Live setting updates

    /// Propagates the latest `minProcessInterval` to every running `.voiceTriggered` stream
    /// without forcing the user to stop and restart. The SDK validates the range (0.1...30) and
    /// throws on out-of-range; non-`.voiceTriggered` modes ignore the call inside the actor.
    func updateMinProcessInterval(_ interval: Double) async {
        guard isStreaming, !activeTranscribeSessions.isEmpty else { return }
        let value = Float(interval)
        for session in activeTranscribeSessions {
            do {
                try await session.updateMinProcessInterval(value)
            } catch {
                Logging.error("Failed to update minProcessInterval to \(value): \(error)")
            }
        }
    }

    private func registerTranscribeSession(_ session: TranscribeStreamSession) {
        activeTranscribeSessions.append(session)
    }

    /// Whether `error` is the SDK's exclusive-decode-gate rejection ("engine is busy"),
    /// thrown when a new Qwen session starts while a previous one is still in flight.
    private nonisolated static func isTranscriberBusyError(_ error: Error) -> Bool {
        guard case ArgmaxError.invalidConfiguration(let message) = error else { return false }
        return message.contains("engine is busy")
    }

    // MARK: - Private Helpers
    
    private func isDeviceSource(_ sourceId: String) -> Bool {
        return sourceId.starts(with: "device")
    }
    
    private func updateStreamResult(sourceId: String, updateBlock: (StreamResult) -> StreamResult) {
        if isDeviceSource(sourceId) {
            let old = deviceResult ?? StreamResult()
            deviceResult = updateBlock(old)
        } else {
            let old = systemResult ?? StreamResult()
            systemResult = updateBlock(old)
        }
    }
    
    private func mergeVocabularyResults(
        existing: inout VocabularyResults,
        newResults: VocabularyResults
    ) {
        guard !newResults.isEmpty else { return }
        for (key, occurrences) in newResults {
            if var stored = existing[key] {
                stored.append(contentsOf: occurrences)
                existing[key] = stored
            } else {
                existing[key] = occurrences
            }
        }
    }
    
    // MARK: - Result Handling

    /// Handles combined results from `TranscribeDiarizeStreamSession`.
    ///
    /// New transcription results append a batch (or replace last batch if same text).
    /// Speaker revision results find the batch by seekTime and replace its speaker assignments.
    private func handleCombinedResult(_ result: TranscribeDiarizeStreamResult, for sourceId: String) {
        var batches = confirmedBatchesBySource[sourceId] ?? []

        if result.type == .speakerRevision {
            if let idx = batches.firstIndex(where: { $0.seekTime == result.seekTime }) {
                batches[idx] = (result.seekTime, result.segments, result.confirmedWordsWithSpeakers)
            }
        } else {
            let isNewText = result.text != (lastConfirmedTextBySource[sourceId] ?? "")
            if isNewText {
                lastConfirmedTextBySource[sourceId] = result.text
                if !result.segments.isEmpty {
                    batches.append((result.seekTime, result.segments, result.confirmedWordsWithSpeakers))
                }
            } else if !result.confirmedWordsWithSpeakers.isEmpty {
                if batches.isEmpty {
                    batches.append((result.seekTime, result.segments, result.confirmedWordsWithSpeakers))
                } else {
                    batches[batches.count - 1] = (result.seekTime, result.segments, result.confirmedWordsWithSpeakers)
                }
            }
        }
        confirmedBatchesBySource[sourceId] = batches

        // Capture a replay-trace entry for real transcription updates (not speaker-only
        // revisions), so diarized sessions also produce a shareable trace.
        if result.type != .speakerRevision {
            appendTraceEntry(
                sourceId: sourceId,
                confirmedText: result.text,
                hypothesisSegments: result.hypothesisSegments ?? []
            )
        }

        let confirmedSegments = batches.flatMap { $0.segments }
        let confirmedWords = batches.flatMap { $0.words }

        updateStreamResult(sourceId: sourceId) { oldResult in
            var newResult = oldResult
            newResult.confirmedSegments = confirmedSegments
            newResult.confirmedWordsWithSpeakers = confirmedWords
            if result.type != .speakerRevision {
                newResult.hypothesisSegments = result.hypothesisSegments ?? []
                newResult.hypothesisWordsWithSpeakers = result.hypothesisWordsWithSpeakers
                newResult.streamEndSeconds = result.seekTime
            }
            // Speaker revisions update confirmedWordsWithSpeakers without touching
            // hypothesisWordsWithSpeakers, leaving the same words visible in both
            // sections of the speaker view for one render frame. Filter hypothesis
            // words that now fall within the confirmed time range.
            let confirmedEnd = confirmedWords.last?.wordTiming.end ?? 0
            if confirmedEnd > 0 {
                newResult.hypothesisWordsWithSpeakers = newResult.hypothesisWordsWithSpeakers.filter {
                    $0.wordTiming.start >= confirmedEnd
                }
            }
            mergeVocabularyResults(existing: &newResult.customVocabularyResults, newResults: result.customVocabularyResults)
            newResult.bufferEnergy = isDeviceSource(sourceId) ? deviceBufferEnergy : systemBufferEnergy
            return newResult
        }

        if let timings = result.diarizationTimings {
            lastDiarizationTimingsBySource[sourceId] = timings
        }

        #if os(iOS)
        updateLiveActivityHypothesis()
        #endif
    }

    /// Handles transcription-only results from `TranscribeStreamSession`.
    private func handleTranscriptionResult(_ result: TranscriptionResultPro, for sourceId: String) {
        let hasNewConfirmedText = result.text != (lastConfirmedTextBySource[sourceId] ?? "")
        if hasNewConfirmedText {
            lastConfirmedTextBySource[sourceId] = result.text
            confirmedResultCallback?(sourceId, result)
            recordDetectedLanguage(result.language)
        }

        appendTraceEntry(
            sourceId: sourceId,
            confirmedText: result.text,
            hypothesisSegments: result.hypothesisSegments
        )

        updateStreamResult(sourceId: sourceId) { oldResult in
            var newResult = oldResult
            if hasNewConfirmedText && !result.segments.isEmpty {
                newResult.confirmedSegments.append(contentsOf: result.segments)
            }
            newResult.hypothesisSegments = result.hypothesisSegments
            mergeVocabularyResults(existing: &newResult.customVocabularyResults, newResults: result.customVocabularyResults)
            newResult.streamEndSeconds = result.seekTime
            newResult.bufferEnergy = isDeviceSource(sourceId) ? deviceBufferEnergy : systemBufferEnergy
            return newResult
        }
        
        #if os(iOS)
        updateLiveActivityHypothesis()
        #endif
    }
    
    #if os(iOS)
    private func updateLiveActivityHypothesis() {
        liveActivityUpdateTask?.cancel()
        liveActivityUpdateTask = Task { [weak self] in
            guard let self else { return }
            await self.liveActivityManager.updateContentState { oldState in
                var state = oldState
                state.currentHypothesis = HighlightedTextView.createHighlightedAttributedString(
                    segments: self.deviceResult?.hypothesisSegments ?? [],
                    customVocabularyResults: self.deviceResult?.customVocabularyResults ?? [:],
                    itnHighlight: self.itnHighlight,
                    font: .body,
                    foregroundColor: .primary
                )
                return state
            }
        }
    }
    #endif

    // MARK: - Energy Polling

    /// Starts a periodic task to read audio energy from the audio processor.
    /// The audio processor updates energy data as it records from the device, so the task
    /// polls at ~10Hz for UI updates.
    private func startEnergyPolling(whisperKitPro: WhisperKitPro) {
        energyPollingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.pollEnergy(whisperKitPro: whisperKitPro)
                try? await Task.sleep(nanoseconds: 100_000_000) // 10 Hz
            }
        }
    }
    
    @MainActor private func pollEnergy(whisperKitPro: WhisperKitPro) {
        #if os(iOS)
        lastAudioDataReceived = Date().timeIntervalSince1970
        #endif
        
        let energies = whisperKitPro.audioProcessor.relativeEnergy
        let newBufferEnergy = Array(energies.suffix(AudioConstants.energyHistoryLimit))
        let sampleCount = whisperKitPro.audioProcessor.audioSamples.count
        let audioSeconds = Double(sampleCount) / Double(WhisperKit.sampleRate)

        let now = Date().timeIntervalSince1970
        if now - lastWaveformPublishTime >= 1.0 / 3.0 {
            deviceBufferEnergy = newBufferEnergy
            lastWaveformPublishTime = now
        }
        
        #if os(iOS)
        if liveActivityManager.isActivityRunning && now - lastLiveActivityAudioUpdate >= 1 {
            lastLiveActivityAudioUpdate = now
            
            Task {
                await liveActivityManager.updateContentState { oldState in
                    var state = oldState
                    state.audioSeconds = audioSeconds
                    state.isInterrupted = false
                    return state
                }
            }
        }
        #endif
    }
    
    // MARK: - iOS Interruption Monitoring
    
    #if os(iOS)
    private func startInterruptionMonitoring() {
        lastAudioDataReceived = Date().timeIntervalSince1970
        
        interruptionMonitoringTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.checkForInterruption()
                // Check every 200ms, data should keep flowing every 100ms
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
    
    private func stopInterruptionMonitoring() {
        interruptionMonitoringTask?.cancel()
        interruptionMonitoringTask = nil
    }
    
    private func checkForInterruption() async {
        guard liveActivityManager.isActivityRunning else { return }

        let now = Date().timeIntervalSince1970
        let timeSinceLastAudio = now - lastAudioDataReceived
        let isInterrupted = timeSinceLastAudio > 0.5

        if isInterrupted {
            Task {
                await liveActivityManager.updateContentState { oldState in
                    var state = oldState
                    state.isInterrupted = true
                    return state
                }
            }
            stopInterruptionMonitoring()
        }
    }
    #endif
}

enum StreamingError: Error, LocalizedError, Equatable {
    case noSourcesSelected
    case deviceNotAvailable(deviceName: String)
    case processNotAvailable(processName: String)
    /// A stream failed mid-flight for a reason surfaced verbatim by the transcriber (e.g. an unsupported
    /// language for Qwen). Carries the underlying message so the alert isn't misleading.
    case streamFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .noSourcesSelected:
            return "No stream sources available to start transcription"
        case .deviceNotAvailable(let deviceName):
            return "Selected audio device '\(deviceName)' is not available"
        case .processNotAvailable(let processName):
            return "Selected audio process '\(processName)' is not available"
        case .streamFailed(let reason):
            return reason
        }
    }

    var alertTitle: String {
        switch self {
        case .noSourcesSelected:
            return "No Audio Source Selected"
        case .deviceNotAvailable:
            return "Audio Device Not Available"
        case .processNotAvailable:
            return "Audio Process Not Available"
        case .streamFailed:
            return "Streaming Failed"
        }
    }

    var alertMessage: String {
        switch self {
        case .noSourcesSelected:
            return "Select at least one source"
        case .deviceNotAvailable(let deviceName):
            return "The selected audio device '\(deviceName)' is not available. Please select a different device."
        case .processNotAvailable(let processName):
            return "The selected audio process '\(processName)' is no longer running. Please select a different process."
        case .streamFailed(let reason):
            return reason
        }
    }
}
