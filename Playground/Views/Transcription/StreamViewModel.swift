import Foundation
import SwiftUI
#if canImport(ArgmaxSDK)
import ArgmaxSDK
#endif
import Argmax
import WhisperKit
import CoreAudio
#if os(iOS)
import ActivityKit
#endif

/// An `ObservableObject` that manages the state and logic for real-time audio streaming and transcription.
///
/// Uses session-based APIs (`TranscribeStreamSession` / `TranscribeDiarizeStreamSession`) for
/// both transcription and diarization. Each start creates fresh sessions with isolated diarizer state,
/// so no reconfiguration or reset is needed between start/stop cycles.
@MainActor
class StreamViewModel: ObservableObject {
    /// Stream Results - per-stream data for UI
    @Published var deviceResult: StreamResult?
    @Published var systemResult: StreamResult?
    /// True once any result is initialized; only flips at session start/clear
    @Published var hasActiveResults: Bool = false
    /// Live device audio energy for waveform only; updated at poll rate to avoid re-rendering full result.
    @Published var deviceBufferEnergy: [Float] = []

    // MARK: - Streaming Diarization

    /// Enable streaming diarization with Sortformer
    @Published var enableStreamingDiarization: Bool = false
    /// Latest diarization timings per source, updated on every combined result that carries timing data.
    /// Values are `StreamingDiarizationTimings` on macOS 15+ / iOS 18+, stored as `Any` for compatibility.
    @Published var lastDiarizationTimingsBySource: [String: Any] = [:]

    @available(macOS 15, iOS 18, *)
    var deviceDiarizationTimings: StreamingDiarizationTimings? {
        lastDiarizationTimingsBySource.first { $0.key.starts(with: "device") }?.value as? StreamingDiarizationTimings
    }

    @available(macOS 15, iOS 18, *)
    var systemDiarizationTimings: StreamingDiarizationTimings? {
        lastDiarizationTimingsBySource.first { !$0.key.starts(with: "device") }?.value as? StreamingDiarizationTimings
    }

    /// After stopTranscribing() completes, one URL per active source (device and/or system).
    /// Used to save one session per source with its own audio file.
    @Published var lastSessionAudioURLsBySource: [String: URL] = [:]
    /// Set when a stream task fails mid-flight; observed by StreamTabView to reset recording state.
    @Published var streamTaskError: StreamingError?
    @Published var isStreaming: Bool = false

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
    
    private var streamTasks: [Task<Void, Never>] = []
    private var audioContinuations: [AsyncThrowingStream<[Float], Error>.Continuation] = []
    private var energyPollingTask: Task<Void, Never>?
    
    #if os(iOS)
    private var lastLiveActivityAudioUpdate: TimeInterval = 0
    private var lastAudioDataReceived: TimeInterval = 0
    private var interruptionMonitoringTask: Task<Void, Never>?
    #endif
    
    private var lastConfirmedTextBySource: [String: String] = [:]
    private var lastWaveformPublishTime: TimeInterval = 0
    private var confirmedResultCallback: ((String, TranscriptionResultPro) -> Void)?

    /// SDK emits one result per transcription update; speaker revisions carry `type == .speakerRevision`.
    /// Batches keyed by seekTime so speaker revision results replace the correct batch.
    private var confirmedBatchesBySource: [String: [(seekTime: Float, segments: [TranscriptionSegment], words: [WordWithSpeaker])]] = [:]

    private var audioWritersBySource: [String: AudioFileWriter] = [:]

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
        let (rawStream, continuation) = whisperKitPro.audioProcessor.startStreamingRecordingLive()
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
            guard let self, self.isStreaming else { return }
            Task { @MainActor [weak self] in
                await self?.stopTranscribing()
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

        // bufferEnergy excluded — WaveformSection reads energy from a separate source.
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
        lastWaveformPublishTime = 0
        lastConfirmedTextBySource = [:]
        confirmedBatchesBySource = [:]
        lastSessionAudioURLsBySource = [:]

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
            await startInterruptionMonitoring()
        } catch {
            Logging.error("Failed to start live activity: \(error)")
        }
        #endif
        
        let useDiarization = enableStreamingDiarization
        let capturedSpeakerKit = useDiarization ? sdkCoordinator.speakerKit : nil
        let capturedDiarizationOptions: (any DiarizationOptions)?
        if #available(macOS 15, iOS 18, *) {
            capturedDiarizationOptions = diarizationOptions ?? SortformerDiarizationOptions(
                sortformerMode: sdkCoordinator.currentSortformerMode.config(isRealtimeMode: true)
            )
        } else {
            capturedDiarizationOptions = diarizationOptions
        }

        for source in audioSources {
            let writer = audioWritersBySource[source.id]
            let sourceId = source.id
            let task = Task.detached { [weak self] in
                guard let self else { return }
                do {
                    if useDiarization, let speakerKit = capturedSpeakerKit {
                        if #available(macOS 15, iOS 18, *) {
                            let transcribeSession = whisperKitPro.makeStreamSession(options: options)
                            let diarizationConfig = capturedDiarizationOptions as? SortformerDiarizationOptions ?? SortformerDiarizationOptions()
                            let combinedSession = try await speakerKit.makeStreamSession(
                                transcriptionSession: transcribeSession,
                                diarizationConfig: diarizationConfig
                            )
                            await combinedSession.start(audioInputStream: source.audioStream)

                            for try await result in combinedSession.results {
                                await self.handleCombinedResult(result, for: sourceId)
                            }
                        } else {
                            let transcribeSession = whisperKitPro.makeStreamSession(options: options)
                            await transcribeSession.start(audioInputStream: source.audioStream)

                            for try await result in transcribeSession.results {
                                await self.handleTranscriptionResult(result, for: sourceId)
                            }
                        }
                    } else {
                        let transcribeSession = whisperKitPro.makeStreamSession(options: options)
                        await transcribeSession.start(audioInputStream: source.audioStream)

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
            }
            self.streamTasks.append(task)
        }
        isStreaming = true
    }
    
    func stopTranscribing() async {
        isStreaming = false
        sdkCoordinator.whisperKit?.audioProcessor.stopRecording()

        for continuation in audioContinuations {
            continuation.finish()
        }
        audioContinuations.removeAll()

        energyPollingTask?.cancel()
        energyPollingTask = nil
        deviceBufferEnergy = []

        for task in streamTasks {
            _ = await task.value
        }
        streamTasks.removeAll()
        audioWritersBySource.removeAll()

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
        await liveActivityManager.stopActivity()
        await stopInterruptionMonitoring()
        #endif

        Logging.debug("Stopped all transcription streams")
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
    @available(macOS 15, iOS 18, *)
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
            mergeVocabularyResults(existing: &newResult.customVocabularyResults, newResults: result.customVocabularyResults)
            if isDeviceSource(sourceId) { newResult.bufferEnergy = deviceBufferEnergy }
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
        }

        updateStreamResult(sourceId: sourceId) { oldResult in
            var newResult = oldResult
            if hasNewConfirmedText && !result.segments.isEmpty {
                newResult.confirmedSegments.append(contentsOf: result.segments)
            }
            newResult.hypothesisSegments = result.hypothesisSegments
            mergeVocabularyResults(existing: &newResult.customVocabularyResults, newResults: result.customVocabularyResults)
            newResult.streamEndSeconds = result.seekTime
            if isDeviceSource(sourceId) { newResult.bufferEnergy = deviceBufferEnergy }
            return newResult
        }
        
        #if os(iOS)
        updateLiveActivityHypothesis()
        #endif
    }
    
    #if os(iOS)
    private func updateLiveActivityHypothesis() {
        Task {
            await liveActivityManager.updateContentState { oldState in
                var state = oldState
                let highlightedHypothesis = HighlightedTextView.createHighlightedAttributedString(
                    segments: self.deviceResult?.hypothesisSegments ?? [],
                    customVocabularyResults: self.deviceResult?.customVocabularyResults ?? [:],
                    font: .body,
                    foregroundColor: .primary
                )
                state.currentHypothesis = highlightedHypothesis
                return state
            }
        }
    }
    #endif

    // MARK: - Energy Polling

    /// Starts a periodic task to read audio energy from the audio processor.
    /// Energy data is updated by the audio processor as it records from the device,
    /// so we just poll it at ~10Hz for UI updates.
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
    
    var errorDescription: String? {
        switch self {
        case .noSourcesSelected:
            return "No stream sources available to start transcription"
        case .deviceNotAvailable(let deviceName):
            return "Selected audio device '\(deviceName)' is not available"
        case .processNotAvailable(let processName):
            return "Selected audio process '\(processName)' is not available"
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
        }
    }
}
