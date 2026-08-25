import SwiftUI
import Argmax
import AVFoundation
import UniformTypeIdentifiers

/// Stream tab: real-time audio streaming with live transcription and optional diarization.
struct StreamTabView: View {
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var streamViewModel: StreamViewModel
    @EnvironmentObject private var audioDevicesDiscoverer: AudioDeviceDiscoverer
    @EnvironmentObject private var sessionHistory: SessionHistoryManager
    @EnvironmentObject private var settings: AppSettings
    #if os(macOS)
    @EnvironmentObject private var audioProcessDiscoverer: AudioProcessDiscoverer
    #endif

    @Environment(\.isFocusMode) private var isFocusMode
    #if os(macOS)
    @Environment(\.openPlaygroundSettings) private var openPlaygroundSettings
    #endif

    @State private var selectedMode: TabMode = .transcription
    @State private var isRecording = false
    @State private var showAdvancedOptions = false
    @State private var showExportSheet = false
    @State private var bufferSeconds: Double = 0
    @State private var currentEncodingLoops: Int = 0
    @State private var currentDecodingLoops: Int = 0
    @State private var tokensPerSecond: TimeInterval = 0
    @State private var streamStartTime: Date?

    @State private var showStreamingErrorAlert = false
    @State private var streamingError: StreamingError?
    @State private var autoScroll = true

    /// Transient button state for a fast stop->start that hit the SDK's exclusive-decode gate:
    /// the previous session is still finalizing, so the button shows progress instead of erroring.
    @State private var finalizationPhase: FinalizationPhase = .idle

    private enum FinalizationPhase {
        case idle, finalizing, finalized
    }


    var body: some View {
        VStack(spacing: 0) {
            StreamResultView(selectedMode: selectedMode, isRecording: isRecording, autoScroll: autoScroll)

            Divider()

            controlsView
        }
        .toolbar {
            if isFocusMode {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { resetState() } label: {
                            Label("New Session", systemImage: "plus")
                        }
                        .disabled(isRecording)
                        Toggle(isOn: $settings.saveAudioToFile) {
                            Label("Save Audio", systemImage: settings.saveAudioToFile ? "waveform.circle.fill" : "waveform.circle")
                        }
                        Button { showExportSheet = true } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(!streamViewModel.hasActiveResults)
                        #if os(iOS)
                        Button { showAdvancedOptions.toggle() } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        .disabled(isRecording)
                        #else
                        Button { openPlaygroundSettings() } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        .disabled(isRecording)
                        #endif
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            } else {
                ToolbarItem {
                    Button { resetState() } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .help("Start new session")
                    .disabled(isRecording)
                }
                ToolbarItem {
                    Toggle(isOn: $settings.saveAudioToFile) {
                        Label("Save Audio", systemImage: settings.saveAudioToFile ? "waveform.circle.fill" : "waveform.circle")
                    }
                    .help("Save streaming audio to file for later replay")
                }
                ToolbarItem {
                    Button { showExportSheet = true } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!streamViewModel.hasActiveResults)
                }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdvancedOptions.toggle() } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .disabled(isRecording)
                }
                #else
                ToolbarItem {
                    Button { openPlaygroundSettings() } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(isRecording)
                }
                #endif
            }
        }
        .sheet(isPresented: $showExportSheet) {
            let segments = collectStreamSegments()
            ExportSheet(isPresented: $showExportSheet, segments: segments, speakerSegments: nil)
        }
        #if os(iOS)
        // macOS reaches Settings through the window-toolbar entry, embedded in the detail
        // column (no sheet); only iOS presents it from here.
        .sheet(isPresented: $showAdvancedOptions) {
            SettingsView(isPresented: $showAdvancedOptions, isStreamMode: true)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
        }
        #endif
        .alert(streamingError?.alertTitle ?? "Error", isPresented: $showStreamingErrorAlert) {
            Button("OK") { showStreamingErrorAlert = false; streamingError = nil }
        } message: {
            Text(streamingError?.alertMessage ?? "An error occurred")
        }
        .onAppear {
            isRecording = streamViewModel.isStreaming
            streamViewModel.itnHighlight = settings.inverseTextNormalization
            streamViewModel.captureReplayTraces = settings.captureReplayTraces
            // External stops run the full stop path: history save + session teardown.
            streamViewModel.externalStopHandler = { stopStream() }
            streamViewModel.setConfirmedResultCallback { sourceId, confirmedResult in
                if sourceId.contains("device") {
                    updateStats(transcription: confirmedResult)
                }
            }
        }
        .onChange(of: streamViewModel.isStreaming) { _, streaming in
            if !streaming && isRecording {
                isRecording = false
                streamStartTime = nil
            }
        }
        .onChange(of: streamViewModel.streamTaskError) { _, error in
            guard let error else { return }
            streamingError = error
            showStreamingErrorAlert = true
            streamViewModel.streamTaskError = nil
            stopStream()
        }
        .onChange(of: streamViewModel.transcriberBusyFinalizing) { _, busy in
            guard busy else { return }
            streamViewModel.transcriberBusyFinalizing = false
            // Same finalizing UX as a normal stop, but don't persist the aborted session.
            stopStream(save: false)
        }
        .onChange(of: settings.minProcessInterval) { _, newValue in
            // Hot-apply minProcessInterval to any live `.voiceTriggered` session -- no need to
            // stop/start the stream. The session is a no-op for other transcription modes.
            guard streamViewModel.isStreaming,
                  settings.transcriptionMode == .voiceTriggered else { return }
            Task { await streamViewModel.updateMinProcessInterval(newValue) }
        }
        .onChange(of: settings.inverseTextNormalization) { _, newValue in
            streamViewModel.itnHighlight = newValue
        }
        .onChange(of: settings.captureReplayTraces) { _, newValue in
            streamViewModel.captureReplayTraces = newValue
        }
    }

    private func speakerCount(confirmed: [WordWithSpeaker], hypothesis: [WordWithSpeaker] = []) -> Int? {
        let all = confirmed + hypothesis.filter { $0.speaker != nil }
        let count = Set(all.compactMap { $0.speaker }).count
        return count > 0 ? count : nil
    }

    private var streamDiarizationBreakdown: [StreamDiarizationEntry]? {
        guard streamViewModel.enableStreamingDiarization else { return nil }
        var entries: [StreamDiarizationEntry] = []

        if let device = streamViewModel.deviceResult {
            let spk = speakerCount(confirmed: device.confirmedWordsWithSpeakers, hypothesis: device.hypothesisWordsWithSpeakers)
            if spk != nil || streamViewModel.deviceDiarizationTimings != nil {
                entries.append(StreamDiarizationEntry(
                    label: "Device",
                    speakers: spk,
                    diarizationTimings: streamViewModel.deviceDiarizationTimings
                ))
            }
        }

        #if os(macOS)
        if let system = streamViewModel.systemResult {
            let spk = speakerCount(confirmed: system.confirmedWordsWithSpeakers, hypothesis: system.hypothesisWordsWithSpeakers)
            if spk != nil || streamViewModel.systemDiarizationTimings != nil {
                entries.append(StreamDiarizationEntry(
                    label: "System",
                    speakers: spk,
                    diarizationTimings: streamViewModel.systemDiarizationTimings
                ))
            }
        }
        #endif

        return isRecording ? entries : (entries.isEmpty ? nil : entries)
    }

    private var totalDetectedSpeakerCount: Int? {
        guard streamViewModel.enableStreamingDiarization else { return nil }
        let allConfirmed = (streamViewModel.deviceResult?.confirmedWordsWithSpeakers ?? [])
            + (streamViewModel.systemResult?.confirmedWordsWithSpeakers ?? [])
        let allHypothesis = (streamViewModel.deviceResult?.hypothesisWordsWithSpeakers ?? [])
            + (streamViewModel.systemResult?.hypothesisWordsWithSpeakers ?? [])
        let allWords = allConfirmed + allHypothesis.filter { $0.speaker != nil }
        let count = Set(allWords.compactMap { $0.speaker }).count
        return count > 0 ? count : nil
    }

    // MARK: - Controls

    private var controlsView: some View {
        VStack(spacing: 8) {
            #if os(macOS)
            ZStack {
                Picker("", selection: $selectedMode) {
                    ForEach(TabMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                HStack {
                    Spacer()
                    Toggle(isOn: $autoScroll) {
                        Text("Auto-scroll").font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            #else
            Picker("", selection: $selectedMode) {
                ForEach(TabMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            #endif

            #if os(macOS)
            MacAudioDevicesView(isRecording: $isRecording, multiDeviceMode: true)
            #endif

            // Auto-scroll on its own row (iOS) so it never overlaps the perf strip, which can grow
            // vertically when expanded. macOS keeps auto-scroll up beside the mode picker.
            #if !os(macOS)
            HStack {
                Spacer()
                Button {
                    autoScroll.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: autoScroll ? "checkmark.square.fill" : "square")
                            .foregroundStyle(autoScroll ? Color.accentColor : .secondary)
                        Text("Auto-scroll")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            #endif

            Group {
                if sdkCoordinator.qwen != nil {
                    // Qwen has no WhisperKit token/encoder/decoder timings; show its own metrics.
                    QwenMetricsView(metrics: streamViewModel.qwenStreamMetrics, isActive: isRecording)
                } else {
                    PerformanceStripView(
                        tokensPerSecond: tokensPerSecond,
                        encodingRuns: currentEncodingLoops,
                        decodingLoops: currentDecodingLoops,
                        diarizationSpeakerCount: totalDetectedSpeakerCount,
                        streamBreakdown: streamDiarizationBreakdown,
                        isActive: isRecording
                    )
                    .equatable()
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                Button {
                    withAnimation { toggleRecording() }
                } label: {
                    if isRecording, let start = streamStartTime {
                        TimelineView(.periodic(from: .now, by: 0.1)) { context in
                            HStack(spacing: 8) {
                                Image(systemName: "stop.fill")
                                Text("Stop Streaming")
                                Text(String(format: "%.1f", context.date.timeIntervalSince(start)) + "s")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .monospacedDigit()
                                    .frame(minWidth: 32, alignment: .leading)
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                        }
                    } else {
                        HStack(spacing: 8) {
                            switch finalizationPhase {
                            case .finalizing:
                                ProgressView().controlSize(.small)
                                Text("Finalizing Stream")
                            case .finalized:
                                Image(systemName: "checkmark.circle.fill")
                                Text("Finalized Stream")
                            case .idle:
                                Image(systemName: isRecording ? "stop.fill" : "waveform.badge.mic")
                                Text(isRecording ? "Stop Streaming" : "Start Streaming")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                    }
                }
                .glassProminentButtonStyle()
                .tint(isRecording ? .red : .accentColor)
                .contentTransition(.symbolEffect(.replace))
                .disabled(!sdkCoordinator.areModelsReady || finalizationPhase != .idle)
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.horizontal)
        .padding(.bottom)
    }

    // MARK: - Actions

    private func resetState() {
        // Do NOT set isRecording = false here. toggleRecording() manages isRecording:
        // it is already `true` when resetState() is called during a start, and the
        // permission-denied paths in startStream() set it back to `false` explicitly.
        // Setting it here caused a one-frame render with the wrong button label.
        bufferSeconds = 0
        streamStartTime = nil
        currentEncodingLoops = 0
        currentDecodingLoops = 0
        tokensPerSecond = 0
        streamViewModel.clearAllResults()
    }

    private func toggleRecording() {
        isRecording.toggle()
        if isRecording {
            resetState()
            startStream()
        } else {
            stopStream()
        }
    }

    private func startStream() {
        Task {
            do {
                #if os(iOS)
                guard await AudioProcessor.requestRecordPermission() else {
                    isRecording = false   // permission denied -- undo the optimistic toggle
                    return
                }
                #else
                if audioDevicesDiscoverer.selectedDeviceID != nil {
                    guard await AudioProcessor.requestRecordPermission() else {
                        isRecording = false
                        return
                    }
                }
                #endif

                isRecording = true
                streamStartTime = Date()

                let streamMode: StreamTranscriptionMode
                switch settings.transcriptionMode {
                case .alwaysOn: streamMode = .alwaysOn
                case .voiceTriggered: streamMode = .voiceTriggered(silenceThreshold: Float(settings.silenceThreshold), maxBufferLength: Float(settings.maxSilenceBufferLength), minProcessInterval: Float(settings.minProcessInterval))
                case .batteryOptimized: streamMode = .batteryOptimized
                }

                // Qwen3-ASR is a standalone transcriber with its own stream session (no WhisperKitPro
                // audio processor / diarization). Route to the Qwen path when it's the loaded transcriber.
                if sdkCoordinator.qwen != nil {
                    // Qwen wants a Title-Case language *name* ("English"), not the app's lowercase
                    // key ("english"); nil = auto-detect. `.capitalized` bridges the two.
                    let language: String? = settings.selectedLanguage == AppSettings.detectLanguageOption
                        ? nil
                        : settings.selectedLanguage.capitalized
                    try await streamViewModel.startQwenTranscribing(
                        options: DecodingOptionsPro(
                            base: DecodingOptions(language: language),
                            transcribeInterval: settings.transcribeInterval,
                            streamTranscriptionMode: streamMode,
                            // Streaming diarization needs stream-global (absolute) timestamps to
                            // align words to speaker segments -- required whenever diarization is on.
                            alignTimestampsToGlobal: true
                        ),
                        diarizationOptions: settings.diarizationOptions(isRealtimeMode: true),
                        saveAudioToFile: settings.saveAudioToFile
                    )
                    return
                }

                try await streamViewModel.startTranscribing(
                    options: DecodingOptionsPro(
                        base: settings.decodingOptions(),
                        transcribeInterval: settings.transcribeInterval,
                        streamTranscriptionMode: streamMode,
                        alignTimestampsToGlobal: true
                    ),
                    diarizationOptions: settings.diarizationOptions(isRealtimeMode: true),
                    saveAudioToFile: settings.saveAudioToFile
                )
            } catch {
                isRecording = false
                if let err = error as? StreamingError {
                    streamingError = err
                    showStreamingErrorAlert = true
                }
                Logging.error("Error starting stream: \(error)")
            }
        }
    }

    /// Tears down the stream and always renders the "Finalizing Stream" -> "Finalized Stream"
    /// button sequence while the session actually drains (finalization is tied to the real
    /// `stopTranscribing()` drain, not a fixed timer). `save` is false for the transcriber-busy path,
    /// where the just-attempted session produced nothing worth persisting.
    private func stopStream(save: Bool = true) {
        isRecording = false
        // Capture elapsed before nilling streamStartTime; the async save below runs after the reset.
        let elapsed = streamStartTime.map { Date().timeIntervalSince($0) } ?? bufferSeconds
        streamStartTime = nil
        withAnimation { finalizationPhase = .finalizing }
        Task {
            await streamViewModel.stopTranscribing()

            #if os(iOS)
            await Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playback)
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }.value
            #endif

            if save { saveStreamToHistory(elapsed: elapsed) }

            withAnimation { finalizationPhase = .finalized }
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation { finalizationPhase = .idle }
        }
    }

    private func updateStats(transcription: TranscriptionResultPro) {
        tokensPerSecond = transcription.timings.tokensPerSecond
        currentEncodingLoops = Int(transcription.timings.totalEncodingRuns)
        currentDecodingLoops = Int(transcription.timings.totalDecodingLoops)
        bufferSeconds = transcription.timings.inputAudioSeconds
    }

    private func collectStreamSegments() -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []
        if let device = streamViewModel.deviceResult {
            segments += device.confirmedSegments + device.hypothesisSegments
        }
        if let system = streamViewModel.systemResult {
            segments += system.confirmedSegments + system.hypothesisSegments
        }
        return segments
    }

    private func collectStreamWordsWithSpeakers() -> [WordWithSpeaker]? {
        var allWords: [WordWithSpeaker] = []
        if let device = streamViewModel.deviceResult {
            allWords += device.confirmedWordsWithSpeakers + device.hypothesisWordsWithSpeakers
        }
        if let system = streamViewModel.systemResult {
            allWords += system.confirmedWordsWithSpeakers + system.hypothesisWordsWithSpeakers
        }
        return allWords.isEmpty ? nil : allWords
    }

    private func saveStreamToHistory(elapsed: TimeInterval) {
        let urlsBySource = streamViewModel.lastSessionAudioURLsBySource
        let resolvedMode = streamViewModel.enableStreamingDiarization
            ? (SortformerModeSelection(rawValue: settings.sortformerModeRaw)?.displayLabel(isStream: true) ?? "Realtime (auto)")
            : nil

        let deviceTimings: Any? = streamViewModel.deviceDiarizationTimings

        if urlsBySource.isEmpty {
            let segments = collectStreamSegments()
            guard !segments.isEmpty else { return }
            sessionHistory.saveStreamSession(
                settings: settings,
                segments: segments,
                wordsWithSpeakers: collectStreamWordsWithSpeakers(),
                streamingDiarizationTimings: deviceTimings,
                audioFileURL: nil,
                audioDuration: elapsed,
                resolvedSortformerMode: resolvedMode
            )
            return
        }

        for (sourceId, audioFileURL) in urlsBySource {
            guard let result = streamViewModel.result(for: sourceId) else { continue }
            let segments = result.confirmedSegments + result.hypothesisSegments
            guard !segments.isEmpty else { continue }
            let words = result.confirmedWordsWithSpeakers + result.hypothesisWordsWithSpeakers
            let sourceLabel = result.title.isEmpty ? "Live Stream" : result.title
            sessionHistory.saveStreamSession(
                settings: settings,
                segments: segments,
                wordsWithSpeakers: words.isEmpty ? nil : words,
                streamingDiarizationTimings: streamViewModel.lastDiarizationTimingsBySource[sourceId],
                audioFileURL: audioFileURL,
                traceFileURL: streamViewModel.lastSessionTraceURLsBySource[sourceId],
                audioDuration: elapsed,
                sourceDescription: sourceLabel,
                resolvedSortformerMode: resolvedMode
            )
        }
    }
}

// MARK: - Qwen metrics panel

/// Collapsed/expandable perf strip shown when Qwen3-ASR is the active transcriber.
/// Displays wall-clock RTF and SpecDec tok/step from SDK `onMetrics` callbacks with sparkline plots.
struct QwenMetricsView: View {
    let metrics: QwenStreamMetrics?
    let isActive: Bool

    @State private var isExpanded = false

    private var hasData: Bool {
        guard let m = metrics else { return false }
        return isActive || m.runningRTF != nil
    }

    var body: some View {
        Group {
            if let m = metrics, hasData {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                    } label: {
                        collapsedRow(m)
                            #if os(iOS)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            #endif
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        expandedContent(m)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Color.clear.frame(height: 22).padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func collapsedRow(_ m: QwenStreamMetrics) -> some View {
        HStack(spacing: 8) {
            if m.totalSeconds != nil {
                // Dictate path: sdk total + finalization + app overhead.
                // RTF is suppressed here -- it is the inverse of PerformancePanel's Speed Factor.
                if let t = m.totalSeconds {
                    metricLabel(String(format: "%.2fs", t), caption: "total")
                }
                if let e = m.exactFinalSeconds {
                    metricLabel(String(format: "%.2fs", e), caption: "to result")
                }
                if let a = m.appOverheadSeconds {
                    metricLabel(String(format: "%.2fs", a), caption: "overhead")
                }
            } else {
                // Streaming path: compute RTF + specDec + exact final (when finalization ran)
                if let rtf = m.runningRTF {
                    metricLabel(String(format: "%.2fx", rtf), caption: "RTF")
                }
                if let sd = m.specDecMean {
                    metricLabel(String(format: "%.1f", sd), caption: "tok/step")
                }
                if let e = m.exactFinalSeconds {
                    metricLabel(String(format: "%.2fs", e), caption: "final")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(height: 22)
    }

    private func expandedContent(_ m: QwenStreamMetrics) -> some View {
        VStack(alignment: .center, spacing: 3) {
            if m.totalSeconds != nil {
                // Dictate path: timeline + compact scalars.
                DictateTimelineView(events: dictateTimelineEvents(m))
                    .padding(.top, 4)

                if let audio = m.audioSeconds {
                    scalarRow(title: "Recording", value: String(format: "%.3fs", audio))
                }
                if let f = m.fastFinalSeconds {
                    scalarRow(title: "Prewarm", value: String(format: "%.3fs", f))
                }
                if let e = m.exactFinalSeconds {
                    scalarRow(title: "Stop to result", value: String(format: "%.3fs", e))
                }
                if let a = m.appOverheadSeconds {
                    scalarRow(title: "App overhead", value: String(format: "%.3fs", a))
                }
            } else {
                // Streaming path: running compute sparklines + optional finalization scalars.
                sectionLabel("Compute (running)")
                plotRow(
                    title: "RTF",
                    latest: m.runningRTF.map { String(format: "%.2fx", $0) },
                    series: m.rtfSeries,
                    color: .accentColor
                )
                plotRow(
                    title: "SpecDec tok/step",
                    latest: m.specDecMean.map { String(format: "%.1f", $0) },
                    series: m.specDecSeries,
                    color: .green
                )
                if m.fastFinalSeconds != nil || m.exactFinalSeconds != nil {
                    sectionLabel("Finalization")
                    if let f = m.fastFinalSeconds {
                        scalarRow(title: "Prewarm", value: String(format: "%.3fs", f))
                    }
                    if let e = m.exactFinalSeconds {
                        scalarRow(title: "Exact final", value: String(format: "%.3fs", e))
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func dictateTimelineEvents(_ m: QwenStreamMetrics) -> [DictateTimelineView.Event] {
        // t=0 = recStart. Recording and real-time feeding run simultaneously.
        // prewarmFinalize() fires during trailing silence (inside the recording window).
        // finish() is called at the stop gesture; exact final lands just after rec stop.
        var events: [DictateTimelineView.Event] = []

        events.append(.init(label: "rec start", t: 0, above: true))

        if let ffa = m.timelineFastFinalApp {
            events.append(.init(
                label: "fast final\n+\(String(format: "%.2f", ffa))s",
                t: ffa, above: false
            ))
        }

        if let audio = m.audioSeconds {
            events.append(.init(
                label: "rec stop\n+\(String(format: "%.2f", audio))s",
                t: audio, above: false, xNudge: -18
            ))
        }

        if let ts = m.totalSeconds {
            events.append(.init(
                label: "exact final\n+\(String(format: "%.2f", ts))s",
                t: ts, above: true, xNudge: 18
            ))
        }

        return events
    }

    private func scalarRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)
            Spacer()
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .bold()
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func plotRow(title: String, latest: String?, series: [Double], color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)
            QwenSparkline(values: series, color: color)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
            Text(latest ?? "--")
                .font(.system(.caption2, design: .monospaced))
                .bold()
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func metricLabel(_ value: String, caption: String) -> some View {
        HStack(spacing: 2) {
            Text(value).bold()
            Text(caption).foregroundColor(.secondary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary)
    }
}

// MARK: - Dictate Timeline

/// Horizontal event timeline for the Qwen dictation path. t=0 is recording start; every
/// event is a non-negative offset from it. Labels are pre-formatted by the caller.
private struct DictateTimelineView: View {
    struct Event {
        let label: String
        let t: Double
        let above: Bool
        /// Horizontal nudge applied to the label only (not the tick mark), in points.
        /// Use a non-zero value on adjacent events whose labels would otherwise collide.
        var xNudge: CGFloat = 0
    }

    let events: [Event]

    // Padded range so no label is flush against the edge.
    private var tBounds: (lo: Double, hi: Double) {
        let allT = events.map(\.t)
        let lo = allT.min() ?? 0
        let hi = max(allT.max() ?? 0, 0.001)
        let pad = max((hi - lo) * 0.05, 0.04)
        return (lo - pad, hi + pad)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lineY: CGFloat = 30
            let (tLo, tHi) = tBounds
            let span = max(tHi - tLo, 0.001)

            Canvas { ctx, size in
                var line = Path()
                line.move(to: CGPoint(x: 0, y: lineY))
                line.addLine(to: CGPoint(x: w, y: lineY))
                ctx.stroke(line, with: .color(.secondary.opacity(0.35)), lineWidth: 0.75)

                for event in events {
                    let x = CGFloat((event.t - tLo) / span) * w
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: lineY - 5))
                    tick.addLine(to: CGPoint(x: x, y: lineY + 5))
                    ctx.stroke(tick, with: .color(.primary.opacity(0.75)), lineWidth: 1.5)
                }
            }
            .overlay(
                ZStack(alignment: .topLeading) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        let rawX = CGFloat((event.t - tLo) / span) * w
                        let x = max(4, min(w - 4, rawX + event.xNudge))
                        Text(event.label)
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize()
                            .position(x: x, y: event.above ? lineY - 17 : lineY + 17)
                    }
                }
            )
        }
        .frame(height: 64)
    }
}

// MARK: - Sparkline

/// Minimal dependency-free line plot (Path, not Swift Charts) used in QwenMetricsView.
private struct QwenSparkline: View {
    let values: [Double]
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            if values.count >= 2 {
                let lo = values.min() ?? 0
                let hi = values.max() ?? 1
                let range = max(hi - lo, 0.0001)
                let step = w / CGFloat(values.count - 1)
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * step
                        let y = h * (1 - CGFloat((v - lo) / range))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h / 2))
                    path.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(color.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }
}
