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


    var body: some View {
        VStack(spacing: 0) {
            StreamResultView(selectedMode: selectedMode, isRecording: isRecording, autoScroll: autoScroll)

            Divider()

            controlsView
        }
        .toolbar {
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
            ToolbarItem(placement: .primaryAction) {
                Button { showAdvancedOptions.toggle() } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .disabled(isRecording)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            let segments = collectStreamSegments()
            ExportSheet(isPresented: $showExportSheet, segments: segments, speakerSegments: nil)
        }
        .sheet(isPresented: $showAdvancedOptions) {
            SettingsView(isPresented: $showAdvancedOptions, isStreamMode: true)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
        }
        .alert(streamingError?.alertTitle ?? "Error", isPresented: $showStreamingErrorAlert) {
            Button("OK") { showStreamingErrorAlert = false; streamingError = nil }
        } message: {
            Text(streamingError?.alertMessage ?? "An error occurred")
        }
        .onAppear {
            isRecording = streamViewModel.isStreaming
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
    }

    private func speakerCount(confirmed: [WordWithSpeaker], hypothesis: [WordWithSpeaker] = []) -> Int? {
        let all = confirmed + hypothesis.filter { $0.speaker != nil }
        let count = Set(all.compactMap { $0.speaker }).count
        return count > 0 ? count : nil
    }

    private var streamDiarizationBreakdown: [StreamDiarizationEntry]? {
        guard streamViewModel.enableStreamingDiarization else { return nil }
        if #available(macOS 15, iOS 18, *) {
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
        return nil
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

            ZStack(alignment: .topTrailing) {
                PerformanceStripView(
                    tokensPerSecond: tokensPerSecond,
                    encodingRuns: currentEncodingLoops,
                    decodingLoops: currentDecodingLoops,
                    diarizationSpeakerCount: totalDetectedSpeakerCount,
                    streamBreakdown: streamDiarizationBreakdown,
                    isActive: isRecording
                ).equatable()

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
                #endif
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
                            Image(systemName: isRecording ? "stop.fill" : "waveform.badge.mic")
                            Text(isRecording ? "Stop Streaming" : "Start Streaming")
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                    }
                }
                .glassProminentButtonStyle()
                .tint(isRecording ? .red : .accentColor)
                .contentTransition(.symbolEffect(.replace))
                .disabled(!sdkCoordinator.areModelsReady)
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
        isRecording = false
        bufferSeconds = 0
        streamStartTime = nil
        currentEncodingLoops = 0
        currentDecodingLoops = 0
        tokensPerSecond = 0
        streamViewModel.clearAllResults()
        Task { await streamViewModel.stopTranscribing() }
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
                guard await AudioProcessor.requestRecordPermission() else { return }
                #else
                if audioDevicesDiscoverer.selectedDeviceID != nil {
                    guard await AudioProcessor.requestRecordPermission() else { return }
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

    private func stopStream() {
        Task {
            await streamViewModel.stopTranscribing()

            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            #endif

            saveStreamToHistory()
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

    private func saveStreamToHistory() {
        let elapsed = streamStartTime.map { Date().timeIntervalSince($0) } ?? bufferSeconds
        let urlsBySource = streamViewModel.lastSessionAudioURLsBySource
        let resolvedMode = streamViewModel.enableStreamingDiarization
            ? (SortformerModeSelection(rawValue: settings.sortformerModeRaw)?.displayLabel(isStream: true) ?? "Realtime (auto)")
            : nil

        let deviceTimings: Any?
        if #available(macOS 15, iOS 18, *) {
            deviceTimings = streamViewModel.deviceDiarizationTimings
        } else {
            deviceTimings = nil
        }

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
                audioDuration: elapsed,
                sourceDescription: sourceLabel,
                resolvedSortformerMode: resolvedMode
            )
        }
    }
}
