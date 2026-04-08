import SwiftUI
import Argmax

/// Transcribe tab: file upload, recording, and transcription results display.
struct TranscribeTabView: View {
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var transcribeViewModel: TranscribeViewModel
    @EnvironmentObject private var audioDevicesDiscoverer: AudioDeviceDiscoverer
    @EnvironmentObject private var sessionHistory: SessionHistoryManager
    @EnvironmentObject private var settings: AppSettings

    @State private var selectedMode: TabMode = .transcription
    @State private var isRecording = false
    @State private var isFilePickerPresented = false
    @State private var showAdvancedOptions = false
    @State private var showExportSheet = false
    @State private var recordStartTime: Date?
    @State private var transcriptionSignatureOnOpen: String = ""
    @State private var diarizationSignatureOnOpen: String = ""

    @State private var tokensPerSecond: TimeInterval = 0
    @State private var firstTokenTime: TimeInterval = 0
    @State private var pipelineStart: TimeInterval = 0
    @State private var totalInferenceTime: TimeInterval = 0
    @State private var currentEncodingLoops: Int = 0
    @State private var currentDecodingLoops: Int = 0
    @State private var lastTranscriptionResult: TranscriptionResult?

    var body: some View {
        VStack(spacing: 0) {
            TranscribeResultView(
                selectedMode: $selectedMode,
                isRecording: $isRecording
            )

            Divider()

            TranscribeControlsArea(
                selectedMode: $selectedMode,
                isRecording: $isRecording,
                isFilePickerPresented: $isFilePickerPresented,
                isTranscribing: transcribeViewModel.isTranscribing,
                isDiarizing: transcribeViewModel.isDiarizing,
                areModelsReady: sdkCoordinator.areModelsReady,
                recordStartTime: recordStartTime,
                isDiarizePyannote: settings.selectedDiarizationModel?.isPyannote == true,
                minSpeakerCountDisplay: settings.minSpeakerCountRaw < 0 ? 0 : settings.minSpeakerCountRaw,
                lastTranscriptionTimings: lastTranscriptionResult?.timings,
                lastDiarizationTimings: transcribeViewModel.lastDiarizationTimings,
                lastDiarizationDurationMs: transcribeViewModel.lastDiarizationDurationMs,
                diarizedSpeakerCount: transcribeViewModel.diarizedSpeakerSegments.isEmpty ? nil : Set(transcribeViewModel.diarizedSpeakerSegments.compactMap { $0.speaker.speakerId }).count,
                audioSampleDuration: transcribeViewModel.audioSampleDuration,
                onToggleRecording: { withAnimation { toggleRecording() } },
                onSpeakerCountChange: { newValue in
                    settings.minSpeakerCountRaw = newValue == 0 ? -1 : newValue
                    rerunDiarizationOnly()
                }
            ).equatable()
        }
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false,
            onCompletion: handleFilePicker
        )
        .toolbar {
            ToolbarItem {
                Button { resetState() } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("Start new session")
            }
            ToolbarItem {
                // Isolated so that unrelated ViewModel publishes don't re-render
                // the Export button and trigger ResolvedButtonStyle churn.
                TranscribeExportButton(
                    hasResults: transcribeViewModel.hasConfirmedResults,
                    onTap: { showExportSheet = true }
                ).equatable()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showAdvancedOptions.toggle() } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(
                isPresented: $showExportSheet,
                segments: transcribeViewModel.confirmedSegments,
                speakerSegments: transcribeViewModel.diarizedSpeakerSegments.isEmpty ? nil : transcribeViewModel.diarizedSpeakerSegments
            )
        }
        .sheet(isPresented: $showAdvancedOptions) {
            SettingsView(isPresented: $showAdvancedOptions, isStreamMode: false) {
                guard transcribeViewModel.currentAudioPath != nil,
                      !transcribeViewModel.isTranscribing,
                      !transcribeViewModel.isDiarizing else { return }

                let transcriptionChanged = transcriptionSettingsSignature() != transcriptionSignatureOnOpen
                let diarizationChanged = diarizationSettingsSignature() != diarizationSignatureOnOpen

                if transcriptionChanged {
                    rerunTranscription()
                } else if diarizationChanged {
                    rerunDiarizationOnly()
                }
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled)
            .presentationContentInteraction(.scrolls)
        }
        .onChange(of: showAdvancedOptions) { _, isOpen in
            if isOpen {
                transcriptionSignatureOnOpen = transcriptionSettingsSignature()
                diarizationSignatureOnOpen = diarizationSettingsSignature()
            }
        }
        .onChange(of: settings.sortformerMaxWordGap) { _, _ in reapplyMatchingIfPossible() }
        .onChange(of: settings.sortformerTolerance) { _, _ in reapplyMatchingIfPossible() }
        .alert("Rename Speaker", isPresented: $transcribeViewModel.showSpeakerRenameAlert) {
            TextField("Speaker Name", text: $transcribeViewModel.newSpeakerName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { transcribeViewModel.applySpeakerRename() }
        } message: {
            Text("Enter a new name for \(transcribeViewModel.speakerDisplayName(speakerId: transcribeViewModel.selectedSpeakerForRename))")
        }
        #if os(macOS)
        .onDrop(of: [.audio, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        #endif
    }

    // MARK: - Actions

    private func resetState() {
        isRecording = false
        recordStartTime = nil
        pipelineStart = .greatestFiniteMagnitude
        firstTokenTime = .greatestFiniteMagnitude
        totalInferenceTime = 0
        tokensPerSecond = 0
        currentEncodingLoops = 0
        currentDecodingLoops = 0
        lastTranscriptionResult = nil
        sdkCoordinator.whisperKit?.audioProcessor.stopRecording()
        sdkCoordinator.modelDownloadFailed = false
        transcribeViewModel.resetStates()
    }

    private func handleFilePicker(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: tempURL)
                try? FileManager.default.copyItem(at: url, to: tempURL)
                transcribeFile(path: tempURL.path)
            }
        case .failure(let error):
            Logging.error("File selection error: \(error)")
        }
    }

    private func transcribeFile(path: String) {
        resetState()
        transcribeViewModel.startFileTranscriptionTask(
            path: path,
            decodingOptions: settings.decodingOptions(clipTimestamps: [transcribeViewModel.lastConfirmedSegmentEndSeconds]),
            diarizationMode: settings.diarizationMode,
            diarizationOptions: settings.diarizationOptions(),
            speakerInfoStrategy: settings.speakerInfoStrategy
        ) { transcription in
            updateStats(transcription: transcription)
            currentDecodingLoops += 1
            lastTranscriptionResult = transcription
            saveToHistory(mode: .transcribeFile, source: URL(fileURLWithPath: path).lastPathComponent, result: transcription)
        }
    }

    private func toggleRecording() {
        isRecording.toggle()
        if isRecording {
            resetState()
            startTranscribe()
        } else {
            stopTranscribe()
        }
    }

    private func startTranscribe() {
        #if os(macOS)
        if audioDevicesDiscoverer.selectedAudioInput == AudioDeviceDiscoverer.noAudioDevice.name { return }
        #endif
        Task {
            guard await AudioProcessor.requestRecordPermission() else { return }
            isRecording = true
            recordStartTime = Date()
            do {
                try transcribeViewModel.startRecordAudio(
                    inputDeviceID: audioDevicesDiscoverer.selectedDeviceID
                ) { _ in }
            } catch {
                await MainActor.run {
                    isRecording = false
                    recordStartTime = nil
                }
                Logging.error("Failed to start recording: \(error)")
            }
        }
    }

    private func stopTranscribe() {
        isRecording = false
        recordStartTime = nil
        transcribeViewModel.stopRecordAndTranscribe(
            delayInterval: Float(settings.transcribeInterval),
            options: settings.decodingOptions(clipTimestamps: [transcribeViewModel.lastConfirmedSegmentEndSeconds]),
            diarizationMode: settings.diarizationMode,
            diarizationOptions: settings.diarizationOptions(),
            speakerInfoStrategy: settings.speakerInfoStrategy
        ) { transcription in
            currentDecodingLoops += 1
            updateStats(transcription: transcription)
            lastTranscriptionResult = transcription
            saveToHistory(mode: .transcribeRecord, source: "Microphone", result: transcription)
        }
    }

    private func rerunTranscription() {
        if let path = transcribeViewModel.currentAudioPath {
            transcribeFile(path: path)
        } else {
            stopTranscribe()
        }
    }

    private func rerunDiarizationOnly() {
        guard let path = transcribeViewModel.currentAudioPath else { return }
        transcribeViewModel.rerunDiarizationFromFile(
            path: path,
            decodingOptions: settings.decodingOptions(clipTimestamps: []),
            diarizationOptions: settings.diarizationOptions(),
            speakerInfoStrategy: settings.speakerInfoStrategy
        )
    }

    private func reapplyMatchingIfPossible() {
        guard #available(macOS 15, iOS 18, *) else { return }
        guard transcribeViewModel.hasConfirmedResults,
              !transcribeViewModel.isTranscribing,
              !transcribeViewModel.isDiarizing else { return }
        let options = SortformerDiarizationOptions(
            maxWordGapInterval: settings.sortformerMaxWordGap,
            tolerance: Float(settings.sortformerTolerance)
        )
        transcribeViewModel.reapplyWordSpeakerMatching(options: options)
    }

    private func updateStats(transcription: TranscriptionResult?) {
        tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
        currentEncodingLoops = Int(transcription?.timings.totalEncodingRuns ?? 0)
        firstTokenTime = transcription?.timings.firstTokenTime ?? 0
        pipelineStart = transcription?.timings.pipelineStart ?? 0
    }

    private func transcriptionSettingsSignature() -> String {
        [
            settings.selectedTask,
            settings.selectedLanguage,
            String(settings.enableTimestamps),
            String(settings.enableSpecialCharacters),
            String(settings.enablePromptPrefill),
            String(settings.enableCachePrefill),
            String(settings.temperatureStart),
            String(settings.fallbackCount),
            String(settings.compressionCheckWindow),
            String(settings.sampleLength),
            settings.chunkingStrategy.rawValue,
            String(settings.concurrentWorkerCount),
            settings.diarizationModeRaw,
        ].joined(separator: "|")
    }

    private func diarizationSettingsSignature() -> String {
        [
            settings.sortformerModeRaw,
            settings.speakerInfoStrategyRaw,
            String(settings.minActiveOffsetRaw),
            String(settings.useExclusiveReconciliation),
            String(settings.minSpeakerCountRaw),
        ].joined(separator: "|")
    }

    private func saveToHistory(mode: SessionMode, source: String, result: TranscriptionResult?) {
        sessionHistory.saveTranscribeSession(
            settings: settings,
            sdkCoordinator: sdkCoordinator,
            mode: mode,
            source: source,
            diarizationMode: settings.diarizationModeRaw,
            segments: transcribeViewModel.confirmedSegments,
            speakerSegments: transcribeViewModel.diarizedSpeakerSegments.isEmpty ? nil : transcribeViewModel.diarizedSpeakerSegments,
            result: result,
            diarizationTimings: transcribeViewModel.lastDiarizationTimings,
            diarizationDurationMs: transcribeViewModel.lastDiarizationDurationMs,
            audioFileURL: transcribeViewModel.currentAudioPath.map { URL(fileURLWithPath: $0) },
            audioDuration: transcribeViewModel.audioSampleDuration
        )
    }

    #if os(macOS)
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let audioExtensions = ["wav", "mp3", "m4a", "flac", "aac", "ogg", "caf"]
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { return }
            Task { @MainActor in
                transcribeFile(path: url.path)
            }
        }
        return true
    }
    #endif
}

// MARK: - Controls area

private struct TranscribeControlsArea: View, Equatable {
    @Binding var selectedMode: TabMode
    @Binding var isRecording: Bool
    @Binding var isFilePickerPresented: Bool

    let isTranscribing: Bool
    let isDiarizing: Bool
    let areModelsReady: Bool
    let recordStartTime: Date?
    let isDiarizePyannote: Bool
    let minSpeakerCountDisplay: Int

    let lastTranscriptionTimings: TranscriptionTimings?
    let lastDiarizationTimings: PyannoteDiarizationTimings?
    let lastDiarizationDurationMs: Double?
    let diarizedSpeakerCount: Int?
    let audioSampleDuration: Double

    let onToggleRecording: () -> Void
    let onSpeakerCountChange: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedMode == rhs.selectedMode &&
        lhs.isRecording == rhs.isRecording &&
        lhs.isTranscribing == rhs.isTranscribing &&
        lhs.isDiarizing == rhs.isDiarizing &&
        lhs.areModelsReady == rhs.areModelsReady &&
        (lhs.recordStartTime != nil) == (rhs.recordStartTime != nil) && // presence only — TimelineView handles display
        lhs.isDiarizePyannote == rhs.isDiarizePyannote &&
        lhs.minSpeakerCountDisplay == rhs.minSpeakerCountDisplay &&
        lhs.lastTranscriptionTimings?.tokensPerSecond == rhs.lastTranscriptionTimings?.tokensPerSecond &&
        lhs.lastTranscriptionTimings?.fullPipeline == rhs.lastTranscriptionTimings?.fullPipeline &&
        lhs.lastDiarizationTimings?.fullPipeline == rhs.lastDiarizationTimings?.fullPipeline &&
        lhs.lastDiarizationDurationMs == rhs.lastDiarizationDurationMs &&
        lhs.diarizedSpeakerCount == rhs.diarizedSpeakerCount &&
        lhs.audioSampleDuration == rhs.audioSampleDuration
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $selectedMode) {
                ForEach(TabMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if selectedMode == .diarize && isDiarizePyannote {
                HStack {
                    Label("Speakers", systemImage: "person.2")
                    Picker("", selection: Binding(
                        get: { minSpeakerCountDisplay },
                        set: { onSpeakerCountChange($0) }
                    )) {
                        Text("Auto").tag(0)
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .frame(width: 80)
                }
                .frame(maxWidth: 200)
            }

            PerformanceStripView(
                timings: lastTranscriptionTimings,
                diarizationTimings: lastDiarizationTimings,
                diarizationDurationMs: lastDiarizationDurationMs,
                diarizationSpeakerCount: diarizedSpeakerCount,
                diarizationAudioDuration: audioSampleDuration > 0 ? audioSampleDuration : nil
            ).equatable()

            #if os(macOS)
            MacAudioDevicesView(isRecording: $isRecording, multiDeviceMode: false)
            #endif

            HStack(spacing: 10) {
                Button {
                    isFilePickerPresented = true
                } label: {
                    Label("From File", systemImage: "doc.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                }
                .glassProminentButtonStyle()
                .disabled(!areModelsReady || isDiarizing || isTranscribing || isRecording)

                Button {
                    onToggleRecording()
                } label: {
                    if isRecording, let start = recordStartTime {
                        TimelineView(.periodic(from: .now, by: 0.1)) { context in
                            HStack(spacing: 8) {
                                Image(systemName: "stop.fill")
                                Text("Stop")
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
                            Image(systemName: "mic.fill")
                            Text("Record")
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                    }
                }
                .glassProminentButtonStyle()
                .tint(isRecording ? .red : .accentColor)
                .contentTransition(.symbolEffect(.replace))
                .disabled(!areModelsReady || isDiarizing || isTranscribing)
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.top, 16)
        .padding(.bottom)
    }
}

// MARK: - Toolbar export button

private struct TranscribeExportButton: View, Equatable {
    let hasResults: Bool
    let onTap: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasResults == rhs.hasResults
    }

    var body: some View {
        Button { onTap() } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(!hasResults)
    }
}
