import Argmax
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
#if canImport(ArgmaxSecrets)
import ArgmaxSecrets
#endif
import AppKit
#endif
import AVFoundation
import CoreML
import Hub

/// The main content view for the Playground application that provides a comprehensive interface for audio transcription and streaming.
/// This view serves as the central hub integrating live streaming, file transcription, and speaker diarization capabilities.
///
/// ## Core Features
///
/// - **Multi-Modal Transcription:** Supports both real-time streaming and file-based transcription workflows
/// - **Model Management:** Provides interface for loading and configuring WhisperKit and SpeakerKit models
/// - **Audio Source Configuration:** Integrates with audio device and process discovery for flexible input selection
/// - **Speaker Diarization:** Offers concurrent and sequential diarization modes with customizable speaker assignment
/// - **Settings & Configuration:** Comprehensive settings interface for model parameters, audio processing, and UI preferences
///
/// ## Architecture
///
/// The view integrates with several key components:
/// - `StreamViewModel`: Manages real-time audio streaming and transcription
/// - `TranscribeViewModel`: Handles file-based transcription and recording workflows
/// - `ArgmaxSDKCoordinator`: Coordinates access to WhisperKit and SpeakerKit instances
/// - Audio discovery services for device and process selection (macOS)
///
/// ## Tab-Based Interface
///
/// The interface is organized into distinct modes:
/// - **Stream:** Real-time audio streaming with live transcription results
/// - **Transcribe:** File upload and recording-based transcription
/// - **Settings:** Model configuration, audio parameters, and UI preferences
struct ContentView: View {
    @EnvironmentObject private var streamViewModel: StreamViewModel
    @EnvironmentObject private var transcribeViewModel: TranscribeViewModel
    #if os(macOS)
    @EnvironmentObject private var audioProcessDiscoverer: AudioProcessDiscoverer
    #endif
    @EnvironmentObject private var audioDevicesDiscoverer: AudioDeviceDiscoverer
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @Environment(\.scenePhase) private var scenePhase
    
    // TODO: Make this configurable in the UI
    @State private var appStartTime = Date()
    private let analyticsLogger: AnalyticsLogger

    // MARK: Model management
    
    @State private var availableLanguages: [String] = []

    @AppStorage("selectedModel") private var selectedModel: String = ""
    @AppStorage("selectedTab") private var selectedTab: String = "Transcribe"
    @AppStorage("selectedTask") private var selectedTask: String = "transcribe"
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "english"
    @AppStorage("enableFastLoad") private var enableFastLoad: Bool = false
    @AppStorage("enableTimestamps") private var enableTimestamps: Bool = true
    @AppStorage("enablePromptPrefill") private var enablePromptPrefill: Bool = true
    @AppStorage("enableCachePrefill") private var enableCachePrefill: Bool = true
    @AppStorage("enableSpecialCharacters") private var enableSpecialCharacters: Bool = false
    @AppStorage("enableDecoderPreview") private var enableDecoderPreview: Bool = true
    @AppStorage("showNerdStats") private var showNerdStats: Bool = false
    @AppStorage("temperatureStart") private var temperatureStart: Double = 0
    @AppStorage("fallbackCount") private var fallbackCount: Double = 5
    @AppStorage("compressionCheckWindow") private var compressionCheckWindow: Double = 60
    @AppStorage("sampleLength") private var sampleLength: Double = 224
    @AppStorage("silenceThreshold") private var silenceThreshold: Double = 0.2
    @AppStorage("maxSilenceBufferLength") private var maxSilenceBufferLength: Double = 10.0
    @AppStorage("transcribeInterval") private var transcribeInterval: Double = 0.1
    @AppStorage("minProcessInterval") private var minProcessInterval: Double = 0.3
    @AppStorage("transcriptionMode") private var transcriptionModeRawValue: String = TranscriptionModeSelection.voiceTriggered.rawValue
    @AppStorage("useVAD") private var useVAD: Bool = true
    @AppStorage("tokenConfirmationsNeeded") private var tokenConfirmationsNeeded: Double = 2
    @AppStorage("concurrentWorkerCount") private var concurrentWorkerCount: Double = 4
    @AppStorage("chunkingStrategy") private var chunkingStrategy: ChunkingStrategy = .vad
    @AppStorage("encoderComputeUnits") private var encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    @AppStorage("decoderComputeUnits") private var decoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    @AppStorage("segmenterComputeUnits") private var segmenterComputeUnits: MLComputeUnits = .cpuOnly
    @AppStorage("embedderComputeUnits") private var embedderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    #if os(macOS)
    @AppStorage("fastLoadEncoderComputeUnits") private var fastLoadEncoderComputeUnits: MLComputeUnits = .cpuAndGPU
    @AppStorage("fastLoadDecoderComputeUnits") private var fastLoadDecoderComputeUnits: MLComputeUnits = .cpuAndGPU
    #else
    @AppStorage("fastLoadEncoderComputeUnits") private var fastLoadEncoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    @AppStorage("fastLoadDecoderComputeUnits") private var fastLoadDecoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    #endif
    @AppStorage("trackingPermissionStatePro") private var trackingPermissionStateRawValue: Int = TrackingPermissionState.undetermined.rawValue
    
    // MARK: DiarizationOptions
    @AppStorage("minNumOfSpeakers") private var storedMinNumOfSpeakers: Int = -1
    @AppStorage("minActiveOffset") private var storedMinActiveOffset: Double = -1.0
    @AppStorage("speakerInfoStrategyRaw") private var speakerInfoStrategyRaw: String = "segment"
    @AppStorage("clustererVersionRaw") private var clustererVersionRaw: String = ClustererVersion.pyannote4.description
    @AppStorage("useExclusiveReconciliation") private var useExclusiveReconciliation: Bool = true
    
    private var minNumOfSpeakers: Int? {
        get { storedMinNumOfSpeakers == -1 ? nil : storedMinNumOfSpeakers }
        set { storedMinNumOfSpeakers = newValue ?? -1 }
    }

    private var minActiveOffset: Double? {
        get { storedMinActiveOffset == -1.0 ? nil : storedMinActiveOffset }
        set { storedMinActiveOffset = newValue ?? -1.0 }
    }

    private var speakerInfoStrategy: SpeakerInfoStrategy {
        get { SpeakerInfoStrategy(from: speakerInfoStrategyRaw) ?? .segment }
        set { speakerInfoStrategyRaw = newValue == .word ? "word" : "segment" }
    }

    private var clustererVersion: ClustererVersion {
        get { ClustererVersion(stringValue: clustererVersionRaw) ?? .pyannote4 }
        set { clustererVersionRaw = newValue.description }
    }
    
    /// Computed property to work with transcription mode as an enum
    private var transcriptionMode: TranscriptionModeSelection {
        get {
            TranscriptionModeSelection(rawValue: transcriptionModeRawValue) ?? .voiceTriggered
        }
        set {
            transcriptionModeRawValue = newValue.rawValue
        }
    }

    // MARK: Standard properties

    @State private var isFilePickerPresented = false
    @State private var modelLoadingTime: TimeInterval = 0
    @State private var firstTokenTime: TimeInterval = 0
    @State private var pipelineStart: TimeInterval = 0
    @State private var effectiveRealTimeFactor: TimeInterval = 0
    @State private var effectiveSpeedFactor: TimeInterval = 0
    @State private var totalInferenceTime: TimeInterval = 0
    @State private var tokensPerSecond: TimeInterval = 0
    @State private var currentLag: TimeInterval = 0
    @State private var currentEncodingLoops: Int = 0
    @State private var currentDecodingLoops: Int = 0
    @State private var bufferSeconds: Double = 0
    @State private var selectedMode: TabMode = .transcription
    @State private var enableDiarization: Bool = true
    @State private var diarizationMode: DiarizationMode = .disabled
    @State private var isTranslation: Bool = false
    @State private var isRecording: Bool = false

    // MARK: Eager mode properties

    @State private var streamEndSeconds: Float?

    // MARK: UI properties

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showWhisperKitComputeUnits: Bool = true
    @State private var showAdvancedOptions: Bool = false
    @State private var transcriptionTask: Task<Void, Never>?
    #if os(macOS)
    @State private var selectedCategoryId: MenuItem.ID? = MenuItem.transcribe.id
    #else
    @State private var selectedCategoryId: MenuItem.ID? = nil
    #endif
    @State private var isTranscriptionFullscreen: Bool = false
    @State private var speakerKitComputeUnitsExpanded = false

    // MARK: Alerts

    @State private var showShortAudioWarningAlert: Bool = false
    @State private var showPermissionAlert: Bool = false
    @State private var permissionAlertMessage: String = ""
    @State private var showStreamingErrorAlert: Bool = false
    @State private var streamingError: StreamingError?

    // MARK: Diagnostic info

    @State private var currentSDKInfo: [String: String] = [:]
    @State private var currentAnalyticsTags: [String: String] = [:]
    @State private var showDiagnosticInfo: Bool = false
    @State private var showCustomVocabularySheet: Bool = false
    @State private var customVocabularyInput: String = ""
    @State private var customVocabularyWords: [String] = []
    @State private var showCustomVocabularyErrorAlert: Bool = false
    @State private var customVocabularyErrorMessage: String = ""
    @State private var showDeleteModelAlert: Bool = false
    @State private var isEditingCustomVocabulary: Bool = false
    @AppStorage("enableCustomVocabulary") private var enableCustomVocabulary: Bool = false
    @State private var lastConfirmedSegmentEndTime: Float = 0.0

    private enum TrackingPermissionState: Int {
        case undetermined = 0
        case granted = 1
        case denied = 2
    }

    enum DiarizationMode: String, CaseIterable {
        case disabled = "Disabled"
        case concurrent = "Enabled: Concurrent"
        case sequential = "Enabled: Sequential"
    }

    enum TabMode: String, CaseIterable {
        case transcription = "Transcription"
        case diarize = "Speakers"
    }

    private var supportsCustomVocabulary: Bool {
        selectedModel.lowercased().contains("parakeet")
    }

    init(analyticsLogger: AnalyticsLogger = NoOpAnalyticsLogger()) {
        self.analyticsLogger = analyticsLogger
    }


    private var trackingPermissionBinding: Binding<Bool> {
        Binding<Bool>(
            get: {
                trackingPermissionStateRawValue == TrackingPermissionState.granted.rawValue
            },
            set: { newValue in
                trackingPermissionStateRawValue = newValue ? TrackingPermissionState.granted.rawValue : TrackingPermissionState.denied.rawValue
                Logging.debug(newValue)
            }
        )
    }

    struct MenuItem: Identifiable, Hashable {
        var id = UUID()
        var name: String
        var image: String
        static let transcribe: MenuItem = .init(name: "Transcribe", image: "book.pages")
        static let stream: MenuItem = .init(name: "Stream", image: "waveform.badge.mic")
    }

    private var menu: [MenuItem] = [
        .transcribe,
        .stream,
    ]

    private var isStreamMode: Bool {
        selectedCategoryId == menu.first(where: { $0.name == MenuItem.stream.name })?.id
    }

    // MARK: Computed Properties
    
    var decodingOptions: DecodingOptions {
        let languageCode = Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode]
        let task: DecodingTask = selectedTask == "transcribe" ? .transcribe : .translate
        return DecodingOptions(
            verbose: true,
            task: task,
            language: languageCode,
            temperature: Float(temperatureStart),
            temperatureFallbackCount: Int(fallbackCount),
            sampleLength: Int(sampleLength),
            usePrefillPrompt: enablePromptPrefill,
            usePrefillCache: enableCachePrefill,
            skipSpecialTokens: !enableSpecialCharacters,
            withoutTimestamps: !enableTimestamps,
            wordTimestamps: true,
            clipTimestamps: [transcribeViewModel.lastConfirmedSegmentEndSeconds],
            concurrentWorkerCount: Int(concurrentWorkerCount),
            chunkingStrategy: chunkingStrategy
        )
    }

    var diarizationOptions: DiarizationOptions? {
        DiarizationOptions(
            numberOfSpeakers: minNumOfSpeakers,
            minActiveOffset: minActiveOffset.map { Float($0) },
            useExclusiveReconciliation: useExclusiveReconciliation
        )
    }

    // MARK: Views

    func resetState() {
        // Clear all UI state
        isRecording = false
        bufferSeconds = 0
        pipelineStart = Double.greatestFiniteMagnitude
        firstTokenTime = Double.greatestFiniteMagnitude
        effectiveRealTimeFactor = 0
        effectiveSpeedFactor = 0
        totalInferenceTime = 0
        tokensPerSecond = 0
        currentLag = 0
        currentEncodingLoops = 0
        currentDecodingLoops = 0
        lastConfirmedSegmentEndTime = 0.0
        
        if isStreamMode {
            streamViewModel.clearAllResults()
            streamViewModel.stopTranscribing()
        } else {
            // Stop audio processing
            sdkCoordinator.whisperKit?.audioProcessor.stopRecording()
            sdkCoordinator.modelDownloadFailed = false // Reset download failure state
            transcribeViewModel.resetStates()
        }
    }

    var body: some View {
        Group {
            if isTranscriptionFullscreen {
                fullscreenTranscriptionView
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    VStack(alignment: .leading) {
                        #if !os(macOS)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Playground")
                                .font(.largeTitle)
                                .fontWeight(.bold)
                            Text("by Argmax")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .offset(x: 2, y: -2)
                        }
                        #endif
                        modelSelectorView
                            .padding(.vertical)
                        computeUnitsView
                            .disabled(sdkCoordinator.whisperKitModelState != .loaded && sdkCoordinator.whisperKitModelState != .unloaded)
                        speakerKitComputeUnitsView
                            .disabled(sdkCoordinator.speakerKitModelState != .loaded && sdkCoordinator.speakerKitModelState != .unloaded)
                            .padding(.bottom)

                        List(menu, selection: $selectedCategoryId) { item in
                            HStack {
                                Image(systemName: item.image)
                                Text(item.name)
                                    .font(.system(.title3))
                                    .bold()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: selectedCategoryId) {
                            let newTab = menu.first(where: { $0.id == selectedCategoryId })?.name ?? MenuItem.transcribe.name
                            
                            // Stop streaming when navigating away from Stream tab on iPhone
                            #if !os(macOS)
                            if selectedTab == MenuItem.stream.name && newTab != MenuItem.stream.name {
                                Task {
                                    streamViewModel.stopTranscribing()
                                }
                            }
                            #endif
                            
                            selectedTab = newTab
                        }
                        .disabled(sdkCoordinator.whisperKitModelState != .loaded)
                        .foregroundColor(sdkCoordinator.whisperKitModelState != .loaded ? .secondary : .primary)
                        .scrollContentBackground(.hidden)

                        Spacer()

                        // Section for app and device info
                        AppInfoView()
                    }
                    .frame(maxHeight: .infinity)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 350)
                    .padding(.horizontal)
                } detail: {
                    VStack {
                        #if os(iOS)
                        modelSelectorView
                            .padding()
                        transcriptionView
                        #elseif os(macOS)
                        VStack(alignment: .leading) {
                            transcriptionView
                        }
                        .padding()
                        #endif
                        controlsView
                    }
                    .toolbar(
                        content: {
                            ToolbarItem {
                                Button {
                                    let fullTranscript: String
                                    if isStreamMode {
                                        // Combine streaming results from device and system
                                        var streamingText: [String] = []
                                        
                                        if let device = streamViewModel.deviceResult {
                                            let deviceSegments = device.confirmedSegments + device.hypothesisSegments
                                            let deviceText = TranscriptionUtilities.formatSegments(
                                                deviceSegments,
                                                withTimestamps: enableTimestamps
                                            ).joined(separator: " ")
                                            if !deviceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                streamingText.append("Device: " + deviceText)
                                            }
                                        }
                                        
                                        if let system = streamViewModel.systemResult {
                                            let systemSegments = system.confirmedSegments + system.hypothesisSegments
                                            let systemText = TranscriptionUtilities.formatSegments(
                                                systemSegments,
                                                withTimestamps: enableTimestamps
                                            ).joined(separator: " ")
                                            if !systemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                streamingText.append("System: " + systemText)
                                            }
                                        }
                                        
                                        fullTranscript = streamingText.joined(separator: "\n")
                                    } else {
                                        // Use transcribe results
                                        fullTranscript = TranscriptionUtilities.formatSegments(
                                            transcribeViewModel.confirmedSegments + transcribeViewModel.unconfirmedSegments,
                                            withTimestamps: enableTimestamps
                                        ).joined(separator: "\n")
                                    }
                                    #if os(iOS)
                                    UIPasteboard.general.string = fullTranscript
                                    #elseif os(macOS)
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fullTranscript, forType: .string)
                                    #endif
                                } label: {
                                    Label("Copy Text", systemImage: "doc.on.doc")
                                }
                                .keyboardShortcut("c", modifiers: .command)
                                .foregroundColor(.primary)
                                .frame(minWidth: 0, maxWidth: .infinity)
                            }

                            ToolbarItem {
                                Button {
                                    isTranscriptionFullscreen = true
                                } label: {
                                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                                }
                                .keyboardShortcut("f", modifiers: .command)
                                .foregroundColor(.primary)
                            }
                        })
                }
                .navigationTitle("Argmax Playground")
            }
        }
        .onAppear {
            #if os(macOS)
            selectedCategoryId = menu.first(where: { $0.name == selectedTab })?.id
            #else
            if UIDevice.current.userInterfaceIdiom == .pad {
                selectedCategoryId = menu.first(where: { $0.name == selectedTab })?.id
            }
            #endif

            diarizationMode = .sequential

            // Set initial state for compute units sections
            showWhisperKitComputeUnits = true
            speakerKitComputeUnitsExpanded = false
            
            streamViewModel.setConfirmedResultCallback { sourceId, confirmedResult in
                if sourceId.contains("device"){
                    self.updateStatsFromStreaming(transcription: confirmedResult)
                }
            }
        }
        .onChange(of: diarizationMode) { oldValue, newMode in
            if selectedMode == .diarize {
                resetState()
                rerunTranscription()
            }
        }
        .onChange(of: speakerInfoStrategy) { oldValue, newStrategy in
            if selectedMode == .diarize && !transcribeViewModel.diarizedSpeakerSegments.isEmpty {
                // Re-run just the speaker info assignment with the new strategy
                Task {
                    await rerunSpeakerInfoAssignment()
                }
            }
        }
        .alert("Rename Speaker", isPresented: $transcribeViewModel.showSpeakerRenameAlert) {
            TextField("Speaker Name", text: $transcribeViewModel.newSpeakerName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                transcribeViewModel.applySpeakerRename()
            }
        } message: {
            Text("Enter a new name for \(transcribeViewModel.speakerDisplayName(speakerId: transcribeViewModel.selectedSpeakerForRename))")
        }
        .task {
            await sdkCoordinator.updateModelList()
            await MainActor.run {
                // Only update to first available if selectedModel is not available
                if !sdkCoordinator.availableModelNames.contains(selectedModel) {
                    if let firstModel = sdkCoordinator.modelStore.availableModels.flatMap({ $0.models }).first {
                        selectedModel = firstModel
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if os(iOS)
            if newPhase == .active {
                // Dismiss interrupted Live Activities when user opens the app
                Task {
                    await streamViewModel.liveActivityManager.handleAppEnteredForeground()
                }
            }
            #endif
        }
        .alert("Delete Model", isPresented: $showDeleteModelAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteModel()
            }
        } message: {
            if enableCustomVocabulary {
                Text("Are you sure you want to delete the model '\(selectedModel)' and custom vocabulary models?")
            } else {
                Text("Are you sure you want to delete the model '\(selectedModel)'?")
            }
        }
    }

    private func updateTracking(state: TrackingPermissionState) {
        Task {
            await MainActor.run {
                trackingPermissionBinding.wrappedValue = (state == .granted)
            }
        }
    }

    struct AppInfoView: View {
        var body: some View {
            HStack(alignment: .top) {
                // Left side - original device info
                VStack(alignment: .leading, spacing: 4) {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
                    Text("App Version: \(version) (\(build))")
                    Text("Device Model: \(WhisperKit.deviceName())")
                    #if os(iOS)
                    Text("OS Version: \(UIDevice.current.systemVersion)")
                    #elseif os(macOS)
                    Text("OS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    #endif
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

                Spacer()

                // Right side - new links
                VStack(alignment: .trailing, spacing: 4) {
                    let sdkVersion = ArgmaxSDK.sdkVersion
                    Text("SDK Version: \(sdkVersion)")
                        .foregroundColor(.secondary)
                    Link(destination: URL(string: "https://argmaxinc.com/")!) {
                        Text("Get access to Argmax SDK")
                            .font(.footnote)
                            .foregroundColor(.blue)
                    }
                }
                .font(.system(.caption, design: .monospaced))
            }
            .padding(.vertical)
        }
    }

    var diarizationOptionsView: some View {
        VStack(spacing: 16) {
            Text("Enable Diarization (SpeakerKitPro)")
                .font(.headline)
                .foregroundColor(.primary)

            HStack(spacing: 30) {
                Button(action: {
                    enableDiarization = true
                }) {
                    VStack(spacing: 8) {
                        Image(systemName: enableDiarization ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundColor(enableDiarization ? .blue : .gray)
                        Text("Hell yes!")
                            .font(.subheadline)
                            .foregroundColor(enableDiarization ? .primary : .gray)
                    }
                }
                .buttonStyle(.plain)

                Button(action: {
                    enableDiarization = false
                }) {
                    VStack(spacing: 8) {
                        Image(systemName: !enableDiarization ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundColor(!enableDiarization ? .blue : .gray)
                        Text("No thanks.")
                            .font(.subheadline)
                            .foregroundColor(!enableDiarization ? .primary : .gray)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Transcription

    var fullscreenTranscriptionView: some View {
        #if os(macOS)
        ZStack {
            transcriptionView
            VStack {
                HStack {
                    Spacer()
                    Button {
                        isTranscriptionFullscreen = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        #else
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playground")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("by Argmax")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .offset(x: 2, y: -2)
                }
                Spacer()
                Button {
                    isTranscriptionFullscreen = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            transcriptionView
        }
        #endif
    }

    var transcriptionView: some View {
        Group {
            if isStreamMode {
                StreamResultView()
            } else {
                TranscribeResultView(
                    selectedMode: $selectedMode,
                    isRecording: $isRecording,
                    loadModel: loadModel
                )
            }
        }
    }

    

    // MARK: - Models

    var modelSelectorView: some View {
        Group {
            VStack(alignment: .trailing) {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(sdkCoordinator.whisperKitModelState == .loaded ? .green : (sdkCoordinator.whisperKitModelState == .unloaded ? .red : .yellow))
                        .symbolEffect(.variableColor, isActive: sdkCoordinator.whisperKitModelState != .loaded && sdkCoordinator.whisperKitModelState != .unloaded)
                    Text(sdkCoordinator.whisperKitModelState.description)

                    Spacer()
                    HStack(spacing: 4) {
                        Link(destination: URL(string: "http://argmaxinc.com/#SDK")!) {
                            Image(systemName: "info.circle")
                                .font(.footnote)
                                .foregroundColor(.blue)
                        }
                        Text("Pro")
                    }
                }
                .padding(.bottom, 4)
                .alert("Microphone Permission Required", isPresented: $showPermissionAlert) {
                    Button("OK") {
                        showPermissionAlert = false
                    }
                } message: {
                    Text(permissionAlertMessage)
                }
                .alert(streamingError?.alertTitle ?? "Error", isPresented: $showStreamingErrorAlert) {
                    Button("OK") {
                        showStreamingErrorAlert = false
                        streamingError = nil
                    }
                } message: {
                    Text(streamingError?.alertMessage ?? "An error occurred")
                }
                .alert("Custom Vocabulary Error", isPresented: $showCustomVocabularyErrorAlert) {
                    Button("OK") {
                        showCustomVocabularyErrorAlert = false
                    }
                } message: {
                    Text(customVocabularyErrorMessage)
                }
                HStack {
                    if !sdkCoordinator.availableModelNames.isEmpty {
                        let localModelNames = sdkCoordinator.modelStore.localModels.flatMap { $0.models }.map { $0.description }
                        Picker("", selection: $selectedModel) {
                            ForEach(sdkCoordinator.availableModelNames, id : \.self) { model in
                                HStack {
                                    let modelIcon = localModelNames.contains(model) ? "checkmark.circle" : "arrow.down.circle.dotted"
                                    Text("\(Image(systemName: modelIcon)) \(model.components(separatedBy: "_").dropFirst().joined(separator: " "))").tag(model)
                                }
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .disabled(sdkCoordinator.whisperKitModelState != .loaded && sdkCoordinator.whisperKitModelState != .unloaded)
                        .onChange(of: selectedModel, initial: false) { _, newValue in
                            sdkCoordinator.modelDownloadFailed = false // Reset failure state when model changes
                            if !newValue.lowercased().contains("parakeet") {
                                enableCustomVocabulary = false
                            }
                            Task {
                                await sdkCoordinator.reset()
                            }
                        }
                    } else {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.5)
                    }
                    
                    if supportsCustomVocabulary && enableCustomVocabulary && sdkCoordinator.whisperKitModelState == .loaded {
                        Button {
                            customVocabularyInput = customVocabularyWords.joined(separator: "\n")
                            isEditingCustomVocabulary = customVocabularyWords.isEmpty
                            showCustomVocabularySheet = true
                        } label: {
                            Image(systemName: "character.book.closed")
                                .symbolRenderingMode(.hierarchical)
                                .imageScale(.medium)
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $showCustomVocabularySheet) {
                            CustomVocabularySheet(
                                isPresented: $showCustomVocabularySheet,
                                words: $customVocabularyWords,
                                input: $customVocabularyInput,
                                isEditing: $isEditingCustomVocabulary,
                                canUpdateVocabulary: { supportsCustomVocabulary && enableCustomVocabulary && sdkCoordinator.whisperKit != nil },
                                onError: { message in
                                    customVocabularyErrorMessage = message
                                    showCustomVocabularyErrorAlert = true
                                }
                            )
                        }
                        .accessibilityLabel("Set Custom Vocabulary")
#if os(macOS)
                        .help("Set Custom Vocabulary")
#endif
                    }
                    
                    Button(action: {
                        showDeleteModelAlert = true
                    }, label: {
                        Image(systemName: "trash")
                    })
                    .help("Delete model")
                    .buttonStyle(BorderlessButtonStyle())
                    .disabled({
                        let localModels = sdkCoordinator.modelStore.localModels.flatMap { $0.models }
                        return localModels.isEmpty || !localModels.contains(selectedModel)
                    }())

                    #if os(macOS)
                    Button(action: {
                        let folderURL = sdkCoordinator.modelStore.baseModelFolder()
                        NSWorkspace.shared.open(folderURL)
                    }, label: {
                        Image(systemName: "folder")
                    })
                    .buttonStyle(BorderlessButtonStyle())
                    #endif
                }

                if sdkCoordinator.whisperKitModelState == .unloaded {
                    Divider()
                    if sdkCoordinator.modelDownloadFailed {
                        Text("Model download failed or was interrupted")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.bottom, 4)
                    }

                    if supportsCustomVocabulary {
#if os(macOS)
                        Toggle(isOn: $enableCustomVocabulary) {
                            Label("Enable Custom Vocabulary", systemImage: "character.book.closed")
                        }
                        .toggleStyle(.checkbox)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .center)
#else
                        Toggle(isOn: $enableCustomVocabulary) {
                            Label("Enable Custom Vocabulary", systemImage: "character.book.closed")
                        }
                        .padding(.bottom, 4)
#endif
                    }

                    Button {
                        let shouldRedownload = sdkCoordinator.modelDownloadFailed // Capture before reset
                        resetState()
                        // If download failed before, automatically use redownload: true
                        loadModel(selectedModel, redownload: shouldRedownload)
                    } label: {
                        Text("Load Model")
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                } else if sdkCoordinator.whisperKitModelState != .loaded {
                    VStack {
                        HStack {
                            ProgressView(value: sdkCoordinator.whisperKitModelProgress, total: 1.0)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: .infinity)

                            Text(String(format: "%.1f%%", sdkCoordinator.whisperKitModelProgress * 100))
                                .font(.caption)
                                .foregroundColor(.gray)

                            Button {
                                // Only delete if model wasnt fully downloaded
                                cancelDownload(delete: sdkCoordinator.whisperKitModelProgress < 0.7)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        if sdkCoordinator.whisperKitModelState == .prewarming {
                            Text("Specializing \(selectedModel) for your device...\nThis can take several minutes on first load\(enableFastLoad ? ". Performance will keep improving over the next few minutes." : "")")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }

            }
        }
    }

    var computeUnitsView: some View {
        DisclosureGroup(isExpanded: $showWhisperKitComputeUnits) {
            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(sdkCoordinator.whisperKitModelState == .unloaded ? .red : sdkCoordinator.whisperKitModelState == .loaded ? .green : .yellow)
                        .symbolEffect(.variableColor, isActive: sdkCoordinator.whisperKitModelState != .loaded && sdkCoordinator.whisperKitModelState != .unloaded)
                    Text("Audio Encoder")
                    Spacer()
                    Picker("", selection: $encoderComputeUnits) {
                        Text("CPU").tag(MLComputeUnits.cpuOnly)
                        Text("GPU").tag(MLComputeUnits.cpuAndGPU)
                        Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
                    }
                    .onChange(of: encoderComputeUnits, initial: false) { _, _ in
                        loadModel(selectedModel)
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 150)
                }
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(sdkCoordinator.whisperKitModelState == .unloaded ? .red : sdkCoordinator.whisperKitModelState == .loaded ? .green : .yellow)
                        .symbolEffect(.variableColor, isActive: sdkCoordinator.whisperKitModelState != .loaded && sdkCoordinator.whisperKitModelState != .unloaded)
                    Text("Text Decoder")
                    Spacer()
                    Picker("", selection: $decoderComputeUnits) {
                        Text("CPU").tag(MLComputeUnits.cpuOnly)
                        Text("GPU").tag(MLComputeUnits.cpuAndGPU)
                        Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
                    }
                    .onChange(of: decoderComputeUnits, initial: false) { _, _ in
                        loadModel(selectedModel)
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 150)
                }
            }
            .padding(.top)
        } label: {
            Text("WhisperKit")
                .font(.headline)
        }
        .onChange(of: showWhisperKitComputeUnits) { _, newValue in
            if newValue {
                speakerKitComputeUnitsExpanded = false
            }
        }
    }

    var speakerKitComputeUnitsView: some View {
        DisclosureGroup(isExpanded: $speakerKitComputeUnitsExpanded) {
            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(
                            sdkCoordinator.speakerKitModelState == .loaded ? .green :
                                (sdkCoordinator.speakerKitModelState == .unloaded ? .red : .yellow)
                        )
                        .symbolEffect(.variableColor, isActive: sdkCoordinator.speakerKitModelState != .loaded && sdkCoordinator.speakerKitModelState != .unloaded)
                    Text("Segmenter")
                    Spacer()
                    Picker("", selection: $segmenterComputeUnits) {
                        Text("CPU").tag(MLComputeUnits.cpuOnly)
                        Text("GPU").tag(MLComputeUnits.cpuAndGPU)
                        Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
                    }
                    .frame(width: 150)
                    .onChange(of: segmenterComputeUnits, initial: false) { _, _ in
                        loadModel(selectedModel)
                    }
                    .disabled(true)
                }
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(
                            sdkCoordinator.speakerKitModelState == .loaded ? .green :
                                (sdkCoordinator.speakerKitModelState == .unloaded ? .red : .yellow)
                        )
                        .symbolEffect(.variableColor, isActive: sdkCoordinator.speakerKitModelState != .loaded && sdkCoordinator.speakerKitModelState != .unloaded)
                    Text("Embedder")
                    Spacer()
                    Picker("", selection: $embedderComputeUnits) {
                        Text("CPU").tag(MLComputeUnits.cpuOnly)
                        Text("GPU").tag(MLComputeUnits.cpuAndGPU)
                        Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
                    }
                    .frame(width: 150)
                    .onChange(of: embedderComputeUnits, initial: false) { _, _ in
                        loadModel(selectedModel)
                    }
                    // TODO - undisable it
                    .disabled(true)
                }
            }
            .padding(.top)
        } label: {
            Text("SpeakerKit")
                .font(.headline)
        }
        .onChange(of: speakerKitComputeUnitsExpanded) { _, newValue in
            if newValue {
                showWhisperKitComputeUnits = false
            }
        }
    }

    // MARK: - Controls

    var controlsView: some View {
        VStack {
            basicSettingsView

            if let selectedCategoryId, let item = menu.first(where: { $0.id == selectedCategoryId }) {
                switch item.name {
                    case MenuItem.transcribe.name:
                        VStack {
                            HStack {
                                Button {
                                    resetState()
                                } label: {
                                    Label("Reset", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)

                                Spacer()

                                #if os(macOS)
                                MacAudioDevicesView(
                                    isRecording: $isRecording,
                                    multiDeviceMode: false
                                )
                                #endif

                                Spacer()

                                Button {
                                    showAdvancedOptions.toggle()
                                } label: {
                                    Label("Settings", systemImage: "slider.horizontal.3")
                                }
                                .buttonStyle(.borderless)
                            }

                            HStack {
                                let color: Color = sdkCoordinator.whisperKitModelState != .loaded ? .gray : .red
                                Button(action: {
                                    withAnimation {
                                        selectFile()
                                    }
                                }) {
                                    Text("FROM FILE")
                                        .font(.headline)
                                        .foregroundColor(color)
                                        .padding()
                                        .cornerRadius(40)
                                        .frame(minWidth: 70, minHeight: 70)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 40)
                                                .stroke(color, lineWidth: 4)
                                        )
                                }
                                .fileImporter(
                                    isPresented: $isFilePickerPresented,
                                    allowedContentTypes: [.audio],
                                    allowsMultipleSelection: false,
                                    onCompletion: handleFilePicker
                                )
                                .lineLimit(1)
                                .contentTransition(.symbolEffect(.replace))
                                .buttonStyle(BorderlessButtonStyle())
                                .disabled(sdkCoordinator.whisperKitModelState != .loaded)
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .padding()

                                ZStack {
                                    Button(action: {
                                        withAnimation {
                                            toggleRecording()
                                        }
                                    }) {
                                        if !isRecording {
                                            Text("RECORD")
                                                .font(.headline)
                                                .foregroundColor(color)
                                                .padding()
                                                .cornerRadius(40)
                                                .frame(minWidth: 70, minHeight: 70)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 40)
                                                        .stroke(color, lineWidth: 4)
                                                )
                                        } else {
                                            Image(systemName: "stop.circle.fill")
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 70, height: 70)
                                                .padding()
                                                .foregroundColor(sdkCoordinator.whisperKitModelState != .loaded ? .gray : .red)
                                        }
                                    }
                                    .lineLimit(1)
                                    .contentTransition(.symbolEffect(.replace))
                                    .buttonStyle(BorderlessButtonStyle())
                                    .disabled(sdkCoordinator.whisperKitModelState != .loaded)
                                    .frame(minWidth: 0, maxWidth: .infinity)
                                    .padding()

                                    if isRecording {
                                        Text("\(String(format: "%.1f", bufferSeconds)) s")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                            .offset(x: 80, y: 0)
                                    }
                                }
                            }
                        }
                    case MenuItem.stream.name:
                        VStack {
                            HStack {
                                Button {
                                    resetState()
                                } label: {
                                    Label("Reset", systemImage: "arrow.clockwise")
                                }
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .buttonStyle(.borderless)

                                Spacer()
                                #if os(macOS)
                                MacAudioDevicesView(
                                    isRecording: $isRecording,
                                    multiDeviceMode: true
                                )
                                #endif

                                Spacer()

                                VStack {
                                    Button {
                                        showAdvancedOptions.toggle()
                                    } label: {
                                        Label("Settings", systemImage: "slider.horizontal.3")
                                    }
                                    .frame(minWidth: 0, maxWidth: .infinity)
                                    .buttonStyle(.borderless)
                                }
                            }

                            ZStack {
                                Button {
                                    withAnimation {
                                        toggleRecording()
                                    }
                                } label: {
                                    Image(systemName: !isRecording ? "record.circle" : "stop.circle.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 70, height: 70)
                                        .padding()
                                        .foregroundColor(sdkCoordinator.whisperKitModelState != .loaded ? .gray : .red)
                                }
                                .contentTransition(.symbolEffect(.replace))
                                .buttonStyle(BorderlessButtonStyle())
                                .disabled(sdkCoordinator.whisperKitModelState != .loaded)
                                .frame(minWidth: 0, maxWidth: .infinity)

                                VStack {
                                    Text("Encoder runs: \(currentEncodingLoops)")
                                        .font(.caption)
                                    Text("Decoder runs: \(currentDecodingLoops)")
                                        .font(.caption)
                                }
                                .offset(x: -120, y: 0)

                                if isRecording {
                                    Text("\(String(format: "%.1f", bufferSeconds)) s")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .offset(x: 80, y: 0)
                                }
                            }
                        }
                    default:
                        EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .sheet(isPresented: $showAdvancedOptions, content: {
            advancedSettingsView
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
        })
    }

    var basicSettingsView: some View {
        VStack {
            HStack {
                Picker("", selection: $selectedMode) {
                    ForEach(TabMode.allCases, id: \.self) { mode in
                        if isStreamMode && mode == .diarize {
                            Text("\(mode.rawValue) (Not Available)")
                                .foregroundColor(.gray)
                        } else {
                            Text(mode.rawValue)
                        }
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .onChange(of: isStreamMode) { _, newValue in
                    if newValue && selectedMode == .diarize {
                        selectedMode = .transcription
                    }
                }
                .onChange(of: selectedMode) { _, newValue in
                    if isStreamMode && newValue == .diarize {
                        selectedMode = .transcription
                    }
                }
            }
            .padding(.horizontal)

            if isStreamMode {
                Text("Speaker diarization coming soon to stream mode")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            if selectedMode == .diarize && !isStreamMode {
                HStack {
                    Label("Number of Speakers", systemImage: "person.2")
                        .fixedSize(horizontal: true, vertical: true)
                        .lineLimit(1)
                    #if os(macOS)
                    Spacer(minLength: 30)
                    #endif
                    let hasDetectedSpeakers = !transcribeViewModel.diarizedSpeakerSegments.isEmpty
                    let pickerWidth: CGFloat = {
                        if minNumOfSpeakers != nil && minNumOfSpeakers != 0 {
                            return 65
                        } else if hasDetectedSpeakers {
                            return 105
                        } else {
                            return 80
                        }
                    }()

                    Picker("", selection: Binding<Int>(
                        get: { storedMinNumOfSpeakers < 0 ? 0 : storedMinNumOfSpeakers },
                        set: { newValue in
                            storedMinNumOfSpeakers = newValue == 0 ? -1 : newValue
                            resetState()
                            rerunTranscription()
                        }
                    )) {
                        if (minNumOfSpeakers == nil || minNumOfSpeakers == 0) && hasDetectedSpeakers {
                            let speakerIds = transcribeViewModel.diarizedSpeakerSegments.compactMap { $0.speaker.speakerId }
                            let uniqueSpeakerCount = Set(speakerIds).count
                            Text("Auto (\(uniqueSpeakerCount))").tag(0)
                        } else {
                            Text("Auto").tag(0)
                        }

                        ForEach(1...5, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .frame(width: pickerWidth)

                    InfoButton("Set the number of speakers to detect. Use 'Auto' to let the system determine the optimal number or select a specific value to constrain the amount of speakers detected in the audio.")
                    #if os(macOS)
                        .padding(.horizontal)
                    #endif
                    #if os(iOS)
                    .padding(.leading, 2)
                    #endif
                }
                .padding()
                .frame(maxWidth: 200)
            } else {
                HStack {
                    VStack {
                        if !showNerdStats && !isStreamMode {
                            HStack {
                                VStack(alignment: .center, spacing: 4) {
                                    Text("Audio:")
                                        .font(.system(.body))
                                    Text(transcribeViewModel.audioSampleDuration.formatted(.number.precision(.fractionLength(2))) + "s")
                                        .font(.system(.body))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }

                                VStack(alignment: .center, spacing: 4) {
                                    Text("Transcribe:")
                                        .font(.system(.body))
                                    Text(transcribeViewModel.transcriptionDuration.formatted(.number.precision(.fractionLength(2))) + "s")
                                        .font(.system(.body))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                                VStack(alignment: .center, spacing: 4) {
                                    Text("Total:")
                                        .font(.system(.body))
                                    Text(transcribeViewModel.totalProcessTime.formatted(.number.precision(.fractionLength(2))) + "s")
                                        .font(.system(.body))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                            }
                        } else {
                            HStack {
                                Text(effectiveRealTimeFactor.formatted(.number.precision(.fractionLength(3))) + " RTF")
                                    .font(.system(.body))
                                    .lineLimit(1)
                                Spacer()

                                #if os(macOS)
                                Text(effectiveSpeedFactor.formatted(.number.precision(.fractionLength(1))) + " Speed Factor")
                                    .font(.system(.body))
                                    .lineLimit(1)
                                Spacer()
                                #endif

                                Text(tokensPerSecond.formatted(.number.precision(.fractionLength(0))) + " tok/s")
                                    .font(.system(.body))
                                    .lineLimit(1)
                                Spacer()

                                Text("First token: " + (firstTokenTime - pipelineStart).formatted(.number.precision(.fractionLength(2))) + "s")
                                    .font(.system(.body))
                                    .lineLimit(1)
                            }
                        }
                    }
                    #if os(macOS)
                    .frame(height: 20)
                    #else
                    .frame(height: 35)
                    #endif
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
    }

    var advancedSettingsView: some View {
        #if os(iOS)
        NavigationView {
            settingsForm
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        VStack {
            Text("Decoding Options")
                .font(.title2)
                .padding()
            settingsForm
                .frame(minWidth: 500, minHeight: 500)
        }
        #endif
    }

    var settingsForm: some View {
        List {
            HStack {
                Text("Decoding Task")
                InfoButton("Select the task to use for decoding. Do you want to transcribe or translate?")
                Spacer()
                Picker("", selection: $selectedTask) {
                    ForEach(DecodingTask.allCases, id: \.self) { task in
                        Text(task.description.capitalized)
                            .tag(task.description)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            .padding(.horizontal)
            HStack {
                LabeledContent {
                    Picker("", selection: $selectedLanguage) {
                        ForEach(availableLanguages, id: \.self) { language in
                            Text(language.description).tag(language.description)
                        }
                    }
                    .disabled(!(sdkCoordinator.whisperKit?.modelVariant.isMultilingual ?? false))
                } label: {
                    Label("Source Language", systemImage: "globe")
                }
                .padding(.horizontal)
            }
            HStack {
                Text("Decoding Stats")
                InfoButton("Toggling this will enable the decoding stats. Toggle it back to view basic stats.")
                Spacer()
                Toggle("", isOn: $showNerdStats)
            }
            .padding(.horizontal)
            HStack {
                Text("Show Timestamps")
                InfoButton("Toggling this will include/exclude timestamps in both the UI and the prefill tokens.\nEither <|notimestamps|> or <|0.00|> will be forced based on this setting unless \"Prompt Prefill\" is de-selected.")
                Spacer()
                Toggle("", isOn: $enableTimestamps)
            }
            .padding(.horizontal)

            HStack {
                Text("Special Characters")
                InfoButton("Toggling this will include/exclude special characters in the transcription text.")
                Spacer()
                Toggle("", isOn: $enableSpecialCharacters)
            }
            .padding(.horizontal)

            HStack {
                Text("Show Decoder Preview")
                InfoButton("Toggling this will show a small preview of the decoder output in the UI under the transcribe. This can be useful for debugging.")
                Spacer()
                Toggle("", isOn: $enableDecoderPreview)
            }
            .padding(.horizontal)

            HStack {
                Text("Prompt Prefill")
                InfoButton("When Prompt Prefill is on, it will force the task, language, and timestamp tokens in the decoding loop. \nToggle it off if you'd like the model to generate those tokens itself instead.")
                Spacer()
                Toggle("", isOn: $enablePromptPrefill)
            }
            .padding(.horizontal)

            HStack {
                Text("Cache Prefill")
                InfoButton("When Cache Prefill is on, the decoder will try to use a lookup table of pre-computed KV caches instead of computing them during the decoding loop. \nThis allows the model to skip the compute required to force the initial prefill tokens, and can speed up inference")
                Spacer()
                Toggle("", isOn: $enableCachePrefill)
            }
            .padding(.horizontal)

            VStack {
                HStack {
                    Text("Chunking Strategy")
                    InfoButton("Select the strategy to use for chunking audio data. If VAD is selected, the audio will be chunked based on voice activity (split on silent portions).")
                    Spacer()
                    Picker("", selection: $chunkingStrategy) {
                        Text("None").tag(ChunkingStrategy.none)
                        Text("VAD").tag(ChunkingStrategy.vad)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                HStack {
                    Text("Workers:")
                    Slider(value: $concurrentWorkerCount, in: 0...32, step: 1)
                    Text(concurrentWorkerCount.formatted(.number))
                    InfoButton("How many workers to run transcription concurrently. Higher values increase memory usage but saturate the selected compute unit more, resulting in faster transcriptions. A value of 0 will use unlimited workers.")
                }
            }
            .padding(.horizontal)
            .padding(.bottom)

            VStack {
                Text("Starting Temperature")
                HStack {
                    Slider(value: $temperatureStart, in: 0...1, step: 0.1)
                    Text(temperatureStart.formatted(.number))
                        .frame(width: 44, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    InfoButton("Controls the initial randomness of the decoding loop token selection.\nA higher temperature will result in more random choices for tokens, and can improve accuracy.")
                }
            }
            .padding(.horizontal)
            
            VStack {
                Text("Max Fallback Count")
                HStack {
                    Slider(value: $fallbackCount, in: 0...5, step: 1)
                    Text(fallbackCount.formatted(.number))
                        .frame(width: 44, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    InfoButton("Controls how many times the decoder will fallback to a higher temperature if any of the decoding thresholds are exceeded.\n Higher values will cause the decoder to run multiple times on the same audio, which can improve accuracy at the cost of speed.")
                }
            }
            .padding(.horizontal)
            
            VStack {
                Text("Compression Check Tokens")
                HStack {
                    Slider(value: $compressionCheckWindow, in: 0...100, step: 5)
                    Text(compressionCheckWindow.formatted(.number))
                        .frame(width: 44, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    InfoButton("Amount of tokens to use when checking for whether the model is stuck in a repetition loop.\nRepetition is checked by using zlib compressed size of the text compared to non-compressed value.\n Lower values will catch repetitions sooner, but too low will miss repetition loops of phrases longer than the window.")
                }
            }
            .padding(.horizontal)
            
            VStack {
                Text("Max Tokens Per Loop")
                HStack {
                    Slider(value: $sampleLength, in: 0...Double(min(sdkCoordinator.whisperKit?.textDecoder.kvCacheMaxSequenceLength ?? Constants.maxTokenContext, Constants.maxTokenContext)), step: 10)
                    Text(sampleLength.formatted(.number))
                        .frame(width: 56, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    InfoButton("Maximum number of tokens to generate per loop.\nCan be lowered based on the type of speech in order to further prevent repetition loops from going too long.")
                }
            }
            .padding(.horizontal)
            
            Section(header: Text("Stream Mode Settings")) {
                HStack {
                    Picker("Mode", selection: Binding(
                        get: { TranscriptionModeSelection(rawValue: transcriptionModeRawValue) ?? .voiceTriggered },
                        set: { transcriptionModeRawValue = $0.rawValue }
                    )) {
                        ForEach(TranscriptionModeSelection.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    Spacer()
                    InfoButton(transcriptionMode.description)
                }
                
                if transcriptionMode == .voiceTriggered {
                    VStack {
                        Text("Silence Threshold")
                        HStack {
                            Slider(value: $silenceThreshold, in: 0...1, step: 0.05)
                            Text(silenceThreshold.formatted(.number.precision(.fractionLength(1))))
                                .frame(width: 44, alignment: .trailing)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            InfoButton("Relative silence threshold for the audio. \n Baseline is set by the quietest 100ms in the previous 2 seconds.")
                        }
                    }
                    .padding(.horizontal)
                    
                    VStack {
                        Text("Max Silence Buffer Size")
                        HStack {
                            Slider(value: $maxSilenceBufferLength, in: 10...60, step: 1)
                            Text(maxSilenceBufferLength.formatted(.number.precision(.fractionLength(0))))
                                .frame(width: 44, alignment: .trailing)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            InfoButton("Seconds of silence to buffer before audio is sent for transcription.")
                        }
                    }
                    .padding(.horizontal)
                    
                    VStack {
                        Text("Min Process Interval")
                        HStack {
                            Slider(
                                value: Binding<Double>(
                                    get: {
                                        if minProcessInterval <= 2.0 {
                                            return minProcessInterval / 4.0
                                        } else {
                                            return 0.5 + (minProcessInterval - 2.0) / 26.0
                                        }
                                    },
                                    set: { position in
                                        let clamped = min(max(position, 0.0), 1.0)
                                        if clamped <= 0.5 {
                                            let mapped = clamped * 4.0
                                            minProcessInterval = (mapped * 10.0).rounded() / 10.0
                                        } else {
                                            let mapped = 2.0 + (clamped - 0.5) * 26.0
                                            minProcessInterval = mapped.rounded()
                                        }
                                    }
                                ),
                                in: 0...1
                            )
                            Text(minProcessInterval <= 2
                                 ? minProcessInterval.formatted(.number.precision(.fractionLength(1)))
                                 : minProcessInterval.formatted(.number.precision(.fractionLength(0))))
                                .frame(width: 44, alignment: .trailing)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            InfoButton("Minimum interval the incoming stream data is fed to transcription pipeline.")
                        }
                    }
                    .padding(.horizontal)
                }
            }
            
            VStack {
                Text("Transcribe Interval")
                HStack {
                    Slider(value: $transcribeInterval, in: 0...30)
                    Text(transcribeInterval.formatted(.number.precision(.fractionLength(1))))
                        .frame(width: 44, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    InfoButton("Controls how often the transcription will get invoked in streaming mode.")
                }
            }
            .padding(.horizontal)

            Section(header: Text("Diarization Settings")) {
                HStack {
                    Picker("Diarization", selection: $diarizationMode) {
                        ForEach(DiarizationMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    InfoButton("You can change the way diarization runs. You can disable it, run it sequentially with transcription, or run it concurrently. Switching modes will re-run the transcription and diarization.")
                }
                .disabled(isStreamMode)
                
                HStack {
                    Picker("Clusterer Version", selection: Binding(
                        get: { clustererVersion },
                        set: { newVersion in
                            clustererVersionRaw = newVersion.description
                        }
                    )) {
                        ForEach(ClustererVersion.allCases, id: \.self) { version in
                            Text(version.description).tag(version)
                        }
                    }
                    InfoButton("Select the clusterer version for speaker diarization.")
                }
                
                HStack {
                    Text("Use Exclusive Reconciliation")
                    Toggle("", isOn: $useExclusiveReconciliation)
                    Spacer()
                    InfoButton("When enabled, ensures that speech from different speakers does not overlap in the diarization output.")
                }
                
                    VStack {
                        Text("Minimum Gap Between Speakers")
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { minActiveOffset ?? 0 },
                                set: { newValue in
                                    storedMinActiveOffset = newValue == 0 ? -1.0 : newValue
                                }
                                ),
                                in: 0...5,
                                step: 0.1
                            )
                            Text(minActiveOffset == nil || minActiveOffset == 0 ? "Auto" : String(format: "%.1fs", minActiveOffset ?? 0))
                            .frame(width: 45)
                        InfoButton("Controls the minimum time gap in seconds between speaker segments. Higher values will combine nearby segments from the same speaker.")
                    }
                }

                    HStack {
                        Text("Speaker Info Strategy")
                        InfoButton("Select the strategy for assigning speaker info: 'word' for word-level, 'segment' for segment-level.")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { speakerInfoStrategy },
                            set: { newStrategy in
                                speakerInfoStrategyRaw = newStrategy == .word ? "word" : "segment"
                            }
                        )) {
                        Text("Word").tag(SpeakerInfoStrategy.word)
                        Text("Segment").tag(SpeakerInfoStrategy.segment)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
            }
            Section(header: Text("Experimental")) {
                HStack {
                    Text("Fast Model Load")
                    InfoButton("This is an experimental feature to load models on different compute units in parallel to speed up the initial load time. This will speed up specialization significantly on first load. Recommend using the delete button next to the model version dropdown in order to test the impact of this feature on a freshly downloaded model.")
                    Spacer()
                    Toggle("", isOn: $enableFastLoad)
                }
                .padding(.horizontal)
                if enableFastLoad {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Fast Encoder Units")
                            Spacer()
                            Picker("", selection: $fastLoadEncoderComputeUnits) {
                                Text("CPU").tag(MLComputeUnits.cpuOnly)
                                Text("GPU").tag(MLComputeUnits.cpuAndGPU)
                                Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 150)
                        }
                        HStack {
                            Text("Fast Decoder Units")
                            Spacer()
                            Picker("", selection: $fastLoadDecoderComputeUnits) {
                                Text("CPU").tag(MLComputeUnits.cpuOnly)
                                Text("GPU").tag(MLComputeUnits.cpuAndGPU)
                                Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 150)
                        }
                    }
                    .padding(.horizontal)
                }
                VStack {
                    Text("Token Confirmations")
                    HStack {
                        Slider(value: $tokenConfirmationsNeeded, in: 1...10, step: 1)
                        Text(tokenConfirmationsNeeded.formatted(.number))
                            .frame(width: 44, alignment: .trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        InfoButton("Controls the number of consecutive tokens required to agree between decoder loops before considering them as confirmed in the streaming process.")
                    }
                }
                .padding(.horizontal)
            }

            Section(header: Text("Diagnostics")) {
                VStack(alignment: .leading, spacing: 8) {
                    // Memory Usage
                    let memoryInfo = getMemoryInfo()
                    // TODO: consolidate these into helper function
                    let bytesToGB = { (bytes: UInt64) -> String in
                        String(format: "%.2f GB", Double(bytes) / 1024 / 1024 / 1024)
                    }
                    Group {
                        HStack {
                            Text("App Memory Usage:")
                            Spacer()
                            Text(bytesToGB(memoryInfo.appUsed))
                        }
                        HStack {
                            Text("System Memory Used:")
                            Spacer()
                            Text(bytesToGB(memoryInfo.totalUsed))
                        }
                        HStack {
                            Text("Total Memory:")
                            Spacer()
                            Text(bytesToGB(memoryInfo.totalPhysical))
                        }
                    }
                    .font(.system(.subheadline, design: .monospaced))

                    Divider()

                    Group {
                        DiagnosticInfoView(
                            currentSDKInfo: currentSDKInfo,
                            currentAnalyticsTags: currentAnalyticsTags,
                            deviceInfo: getDeviceInfo(),
                            expandInfo: $showDiagnosticInfo
                        )
                    }
                }
                .padding(.horizontal)
                .task {
                    // Update SDK info in background
                    let info = await ArgmaxSDK.licenseInfo()
                    let tags = getDiagnosticTags("Diagnostics")
                    await MainActor.run {
                        currentSDKInfo = info.asDictionary()
                        currentAnalyticsTags = tags
                    }
                }
            }
        }
        .navigationTitle("Decoding Options")
        .toolbar(content: {
            ToolbarItem {
                Button {
                    showAdvancedOptions = false
                } label: {
                    Label("Done", systemImage: "xmark.circle.fill")
                        .foregroundColor(.primary)
                }
            }
        })
    }

    struct DiagnosticInfoView: View {
        var currentSDKInfo: [String: String]
        var currentAnalyticsTags: [String: String]
        var deviceInfo: AppDeviceInfo
        @Binding var expandInfo: Bool

        let bytesToGB = { (bytes: UInt64) -> String in
            String(format: "%.2f GB", Double(bytes) / 1024 / 1024 / 1024)
        }

        var body: some View {
            // Device Info
            VStack {
                HStack {
                    Text("Thermal State:")
                    Spacer()
                    Text(deviceInfo.thermalState.description.capitalized)
                        .foregroundColor(deviceInfo.thermalState == .nominal ? .green :
                            deviceInfo.thermalState == .fair ? .yellow :
                            deviceInfo.thermalState == .serious ? .orange : .red)
                }

                #if os(iOS)
                if deviceInfo.batteryLevel >= 0 {
                    HStack {
                        Text("Battery Level:")
                        Spacer()
                        Text(String(format: "%.0f%%", deviceInfo.batteryLevel * 100))
                            .foregroundColor(deviceInfo.batteryLevel > 0.2 ? .primary : .red)
                    }
                }

                HStack {
                    Text("Low Power Mode:")
                    Spacer()
                    Text(deviceInfo.isLowPowerMode ? "Enabled" : "Disabled")
                        .foregroundColor(deviceInfo.isLowPowerMode ? .yellow : .primary)
                }
                #endif

                HStack {
                    Text("Available Storage:")
                    Spacer()
                    Text(bytesToGB(deviceInfo.diskFreeSpace))
                }
            }
            .font(.system(.subheadline, design: .monospaced))

            Divider()

            VStack {
                // Header button
                Button {
                    expandInfo.toggle()
                } label: {
                    HStack {
                        Image(systemName: expandInfo ? "chevron.down" : "chevron.right")

                        Text("Debug Info")
                            .font(.headline)
                        Spacer()

                        // Copy button
                        Button {
                            var info = currentSDKInfo.map { "\($0.key): \($0.value)" }
                            if !currentAnalyticsTags.isEmpty {
                                info.append("") // Empty line between sections
                                info.append(contentsOf: currentAnalyticsTags.map { "\($0.key): \($0.value)" })
                            }
                            let fullInfo = info.joined(separator: "\n")
                            #if os(iOS)
                            UIPasteboard.general.string = fullInfo
                            #elseif os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fullInfo, forType: .string)
                            #endif
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .buttonStyle(.plain)

                if expandInfo {
                    ExpandedLicenseView(
                        currentSDKInfo: currentSDKInfo,
                        currentAnalyticsTags: currentAnalyticsTags
                    )
                }
            }
        }
    }

    struct ExpandedLicenseView: View {
        var currentSDKInfo: [String: String]
        var currentAnalyticsTags: [String: String]

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                // SDK Info
                ForEach(Array(currentSDKInfo.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                    HStack {
                        Text(key + ":")
                            .foregroundColor(.secondary)
                        Spacer()
                        if key == "pro_access" {
                            Text(value)
                                .foregroundColor(value == "Valid" ? .green : .red)
                                .textSelection(.enabled)
                        } else {
                            Text(value)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !currentAnalyticsTags.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    // Sentry Tags
                    ForEach(Array(currentAnalyticsTags.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                        HStack {
                            Text(key + ":")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(value)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    struct InfoButton: View {
        var infoText: String
        @State private var showInfo = false

        init(_ infoText: String) {
            self.infoText = infoText
        }

        var body: some View {
            Button(action: {
                showInfo = true
            }) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
            }
            .popover(isPresented: $showInfo) {
                Text(infoText)
                    .padding()
            }
            .buttonStyle(BorderlessButtonStyle())
        }
    }

    // MARK: - Logic
    func loadModel(_ model: String, redownload: Bool = false) {
        sdkCoordinator.modelDownloadFailed = false // Reset failure state on new attempt
        Logging.shared.logLevel = Logging.LogLevel.debug
        Logging.debug("Selected Model: \(UserDefaults.standard.string(forKey: "selectedModel") ?? "nil")")
        let computeUnits = ModelComputeOptions(audioEncoderCompute: encoderComputeUnits, textDecoderCompute: decoderComputeUnits)
        Logging.debug("""
            Computing Options:
            - Mel Spectrogram:  \(computeUnits.melCompute.description)
            - Audio Encoder:    \(computeUnits.audioEncoderCompute.description)
            - Text Decoder:     \(computeUnits.textDecoderCompute.description)
            - Prefill Data:     \(computeUnits.prefillCompute.description)
        """)

        let supportsCustomVocabularyForModel = model.lowercased().contains("parakeet")
        let shouldEnableCustomVocabulary = supportsCustomVocabularyForModel && enableCustomVocabulary
        let vocabularySnapshot = customVocabularyWords

        Task {
            do {
                let customVocabularyConfig: CustomVocabularyConfig? = shouldEnableCustomVocabulary ? .init(words: nil) : nil
                
                let proConfig = WhisperKitProConfig(
                    computeOptions: computeUnits,
                    verbose: true,
                    logLevel: .debug,
                    prewarm: true,
                    load: false,
                    useBackgroundDownloadSession: false,
                    fastLoad: enableFastLoad,
                    fastLoadEncoderComputeUnits: fastLoadEncoderComputeUnits,
                    fastLoadDecoderComputeUnits: fastLoadDecoderComputeUnits,
                    customVocabularyConfig: customVocabularyConfig
                )
                try await sdkCoordinator.prepare(
                    modelName: model,
                    config: proConfig,
                    redownload: redownload,
                    clustererVersion: clustererVersion
                )

                await sdkCoordinator.updateModelList()

                await MainActor.run {
                    availableLanguages = Constants.languages.map { $0.key }.sorted()
                    sdkCoordinator.modelDownloadFailed = false // Success - clear any previous failure
                }

                if shouldEnableCustomVocabulary && !vocabularySnapshot.isEmpty {
                    do {
                        try await sdkCoordinator.updateCustomVocabulary(words: vocabularySnapshot)
                    } catch {
                        Logging.error("Failed to update custom vocabulary after model load: \(error)")
                        await MainActor.run {
                            let message = error.localizedDescription.isEmpty ? "Unable to update custom vocabulary." : error.localizedDescription
                            customVocabularyErrorMessage = message
                            showCustomVocabularyErrorAlert = true
                        }
                    }
                }
            } catch {
                Logging.debug("Error loading model via coordinator: \(error)")
                await MainActor.run {
                    sdkCoordinator.modelDownloadFailed = true // Set failure state
                }
            }
        }
    }
    

    func deleteModel() {
        Task {
            do {
                try await sdkCoordinator.delete(modelName: selectedModel)
                await sdkCoordinator.updateModelList()
                await sdkCoordinator.reset()
                if enableCustomVocabulary {
                    try await sdkCoordinator.deleteCustomVocabularyModels()
                }
            } catch {
                Logging.debug("Error deleting model: \(error)")
            }
        }
    }

    func cancelDownload(delete: Bool = false) {
        Task {
            do {
                // Cancel the download first
                sdkCoordinator.modelStore.cancelDownload()

                // Find which repository the model is being downloaded from
                let availableRepos = sdkCoordinator.modelStore.availableModelRepos()
                if delete {
                    for repo in availableRepos {
                        if sdkCoordinator.modelStore.modelExists(variant: selectedModel, from: repo) {
                            // Delete the partially downloaded model
                            try await sdkCoordinator.modelStore.deleteModel(variant: selectedModel, from: repo)
                            break
                        }
                    }
                }

                // Reset the transcriber state
                await sdkCoordinator.reset()
                await sdkCoordinator.updateModelList()
            } catch {
                Logging.debug("Error canceling download and deleting model: \(error)")
            }
        }
    }

    func selectFile() {
        isFilePickerPresented = true
    }

    func handleFilePicker(result: Result<[URL], Error>) {
        switch result {
            case let .success(urls):
                guard let selectedFileURL = urls.first else { return }
                if selectedFileURL.startAccessingSecurityScopedResource() {
                    do {
                        // Access the document data from the file URL
                        let audioFileData = try Data(contentsOf: selectedFileURL)

                        // Create a unique file name to avoid overwriting any existing files
                        let uniqueFileName = UUID().uuidString + "." + selectedFileURL.pathExtension

                        // Construct the temporary file URL in the app's temp directory
                        let tempDirectoryURL = FileManager.default.temporaryDirectory
                        let localFileURL = tempDirectoryURL.appendingPathComponent(uniqueFileName)
                        // Write the data to the temp directory
                        try audioFileData.write(to: localFileURL)

                        Logging.debug("File saved to temporary directory: \(localFileURL)")

                        transcribeFile(path: selectedFileURL.path)
                    } catch {
                        Logging.debug("File selection error: \(error.localizedDescription)")
                    }
                }
            case let .failure(error):
                Logging.debug("File selection error: \(error.localizedDescription)")
        }
    }

    func transcribeFile(path: String) {
        resetState()
        transcribeViewModel.startFileTranscriptionTask(
            path: path,
            decodingOptions: decodingOptions,
            diarizationMode: diarizationMode,
            diarizationOptions: diarizationOptions,
            speakerInfoStrategy: speakerInfoStrategy
        ) { transcription in
            updateStatsFromTranscribing(transcription: transcription)
            currentDecodingLoops += 1
            logTimingsToAnalytics("File")
        }
    }

    func toggleRecording() {
        isRecording.toggle()

        // Clear current file if exists
        transcribeViewModel.clearCurrentAudioPath()

        switch (isRecording, isStreamMode) {
            case (true, true):
                resetState()
                startStream()
            case (false, true):
                stopStream()
            case (true, false):
                resetState()
                startTranscribe()
            case (false, false):
                stopTranscribe()
        }
    }

    // MARK: - Audio Permission Helper
    private func checkAudioPermission() async -> Bool {
        guard await AudioProcessor.requestRecordPermission() else {
            Logging.debug("Microphone access was not granted.")
            await MainActor.run {
                #if os(macOS)
                permissionAlertMessage = "Please grant microphone access in System Settings > Privacy & Security > Microphone > Playground to use transcription features."
                #else
                permissionAlertMessage = "Please grant microphone access in iOS Settings > Privacy & Security > Microphone > Playground to use transcription features."
                #endif
                showPermissionAlert = true
            }
            return false
        }
        return true
    }

    // MARK: - Transcribe Logic
    func startTranscribe() {
        #if os(macOS)
        if (audioDevicesDiscoverer.selectedAudioInput == AudioDeviceDiscoverer.noAudioDevice.name) {
            return
        }
        #endif
        Task {
            guard await checkAudioPermission() else {
                return
            }
            isRecording = true
            do {
                try transcribeViewModel.startRecordAudio(
                  inputDeviceID: audioDevicesDiscoverer.selectedDiviceID
                ) { bufferSecondsValue in
                  await MainActor.run {
                      bufferSeconds = bufferSecondsValue
                  }
                }
            } catch {
                await MainActor.run {
                    isRecording = false
                }
                Logging.error("Failed to start recording audio: \(error)")
            }
        }
    }

    func stopTranscribe() {
        isRecording = false
        transcribeViewModel.stopRecordAndTranscribe(
            delayInterval: Float(transcribeInterval),
            options: decodingOptions,
            diarizationMode: diarizationMode,
            diarizationOptions: diarizationOptions,
            speakerInfoStrategy: speakerInfoStrategy
        ) { transcription in
            currentDecodingLoops += 1
            updateStatsFromTranscribing(transcription: transcription)
            // currentBuffer has different logic to update effectiveRealTimeFactor and effectiveSpeedFactor
            let totalAudio = Double(transcribeViewModel.lastBufferSize) / Double(WhisperKit.sampleRate)
            totalInferenceTime += transcription?.timings.fullPipeline ?? 0
            effectiveRealTimeFactor = Double(totalInferenceTime) / totalAudio
            effectiveSpeedFactor = totalAudio / Double(totalInferenceTime)
            
            logTimingsToAnalytics("Realtime Decoding")
        }
    }

    func rerunTranscription() {
        if let currentPath = transcribeViewModel.currentAudioPath {
            transcribeViewModel.startFileTranscriptionTask(
                path: currentPath,
                decodingOptions: decodingOptions,
                diarizationMode: diarizationMode,
                diarizationOptions: diarizationOptions,
                speakerInfoStrategy: speakerInfoStrategy
            ) {
                transcription in
                    updateStatsFromTranscribing(transcription: transcription)
                    currentDecodingLoops += 1
                    logTimingsToAnalytics("File")
            }
        } else {
            stopTranscribe()
        }
    }

    func rerunSpeakerInfoAssignment() async {
        do {
            try await transcribeViewModel.rerunSpeakerInfoAssignment(
                diarizationOptions: diarizationOptions,
                speakerInfoStrategy: speakerInfoStrategy,
                selectedLanguage: selectedLanguage
            )
        } catch {
            Logging.error("Error re-running speaker info assignment: \(error)")
        }
    }
    
    // update UI states when transcribing has an available result
    func updateStatsFromTranscribing(transcription: TranscriptionResult?) {
        tokensPerSecond = transcription?.timings.tokensPerSecond ?? 0
        effectiveRealTimeFactor = transcription?.timings.realTimeFactor ?? 0
        effectiveSpeedFactor = transcription?.timings.speedFactor ?? 0
        currentEncodingLoops = Int(transcription?.timings.totalEncodingRuns ?? 0)
        firstTokenTime = transcription?.timings.firstTokenTime ?? 0
        modelLoadingTime = transcription?.timings.modelLoading ?? 0
        pipelineStart = transcription?.timings.pipelineStart ?? 0
        currentLag = transcription?.timings.decodingLoop ?? 0
    }

    // MARK: Streaming Logic
    func startStream() {
        // Check permission when on iOS or when a specific device is selected on macOS
        #if os(iOS)
        let shouldCheckPermission = true
        #else
        let shouldCheckPermission = audioDevicesDiscoverer.selectedDiviceID != nil
        #endif
        
        Task {
            do {
                if shouldCheckPermission {
                    guard await checkAudioPermission() else {
                        return
                    }
                }
                
                await MainActor.run {
                    isRecording = true
                }
                
                let streamMode: StreamTranscriptionMode
                switch transcriptionMode {
                case .alwaysOn:
                    streamMode = .alwaysOn
                case .voiceTriggered:
                    streamMode = .voiceTriggered(silenceThreshold: Float(silenceThreshold), maxBufferLength: Float(maxSilenceBufferLength), minProcessInterval: Float(minProcessInterval))
                case .batteryOptimized:
                    streamMode = .batteryOptimized
                }
                
                try await streamViewModel.startTranscribing(
                    options: DecodingOptionsPro(
                        base: decodingOptions,
                        transcribeInterval: transcribeInterval,
                        streamTranscriptionMode: streamMode
                    )
                )
            } catch {
                await MainActor.run {
                    isRecording = false
                    // Check if this is a StreamingError and show appropriate alert
                    if let streamingError = error as? StreamingError {
                        self.streamingError = streamingError
                        showStreamingErrorAlert = true
                    }
                }
                Logging.error("Error starting transcription: \(error)")
            }
        }
    }
    
    func stopStream() {
        streamViewModel.stopTranscribing()
    }
    
    // update UI states when streaming has a confirmed result
    func updateStatsFromStreaming(transcription: TranscriptionResultPro) {
        tokensPerSecond = transcription.timings.tokensPerSecond
        firstTokenTime = transcription.timings.firstTokenTime
        modelLoadingTime = transcription.timings.modelLoading
        pipelineStart = transcription.timings.pipelineStart
        currentLag = transcription.timings.decodingLoop
        currentEncodingLoops += Int(transcription.timings.totalEncodingRuns)
        currentDecodingLoops += Int(transcription.timings.totalDecodingLoops)

        totalInferenceTime += transcription.timings.fullPipeline
        bufferSeconds = transcription.timings.inputAudioSeconds
        if bufferSeconds > 0 {
            effectiveSpeedFactor = totalInferenceTime / bufferSeconds
            effectiveRealTimeFactor = bufferSeconds / totalInferenceTime
        }
    }

    // MARK: - Firebase Analytics Functions
    func logTimingsToAnalytics(_ method: String) {
        Logging.debug("Logging performance to AnalyticsLogger")
        let tags = getDiagnosticTags(method)
        var parameters: [String: Any] = [
            "method": method,
            "time_to_first_token": firstTokenTime,
            "tokens_per_second": tokensPerSecond,
            "encoding_loops": Double(currentEncodingLoops),
            "decoding_loops": Double(currentDecodingLoops),
            "total_inference_time": totalInferenceTime,
            "real_time_factor": effectiveRealTimeFactor,
            "speed_factor": effectiveSpeedFactor,
            "model_loading": modelLoadingTime,
        ]
        for (key, value) in tags {
            parameters[key] = value
        }
        analyticsLogger.logEvent("transcription_performance", parameters: parameters)
    }

    func getDiagnosticTags(_ method: String) -> [String: String] {
        var tags = [String: String]()
        #if os(iOS)
        let platform = "ios"
        #elseif os(macOS)
        let platform = "macos"
        #else
        let platform = "unknown"
        #endif

        let memoryInfo = getMemoryInfo()
        let deviceInfo = getDeviceInfo()

        // Convert bytes to gigabytes
        let bytesToGB = { (bytes: UInt64) -> String in
            String(format: "%.3f", Double(bytes) / 1024 / 1024 / 1024)
        }

        let deviceName = WhisperKit.deviceName().trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(macOS)
        let selectedAudioInput = audioDevicesDiscoverer.selectedAudioInput
        #else
        let selectedAudioInput = ""
        #endif
        
        tags = [
            "platform": platform,
            "device_name": deviceName,
            "method": method,
            "memory_app_used_gb": bytesToGB(memoryInfo.appUsed),
            "memory_app_allocated_gb": bytesToGB(memoryInfo.appAvailable),
            "memory_total_used_gb": bytesToGB(memoryInfo.totalUsed),
            "memory_total_available_gb": bytesToGB(memoryInfo.totalAvailable),
            "memory_total_device_gb": bytesToGB(memoryInfo.totalPhysical),
            "memory_swap_used_gb": bytesToGB(memoryInfo.swapUsed),
            "selected_audio_input": selectedAudioInput,
            "selected_model": selectedModel,
            "selected_tab": selectedTab,
            "selected_task": selectedTask,
            "selected_language": selectedLanguage,
            // "repo_name": repoName,
            "enable_timestamps": "\(enableTimestamps)",
            "enable_prompt_prefill": "\(enablePromptPrefill)",
            "enable_cache_prefill": "\(enableCachePrefill)",
            "enable_special_characters": "\(enableSpecialCharacters)",
            "enable_decoder_preview": "\(enableDecoderPreview)",
            "temperature_start": "\(temperatureStart)",
            "fallback_count": "\(fallbackCount)",
            "compression_check_window": "\(compressionCheckWindow)",
            "sample_length": "\(sampleLength)",
            "silence_threshold": "\(silenceThreshold)",
            "transcription_mode": "\(transcriptionMode.rawValue)",
            "use_vad": "\(useVAD)",
            "token_confirmations_needed": "\(tokenConfirmationsNeeded)",
            "chunking_strategy": "\(chunkingStrategy)",
            "encoder_compute_units": "\(computeUnitsDescription(encoderComputeUnits))",
            "decoder_compute_units": "\(computeUnitsDescription(decoderComputeUnits))",
            "fast_load_encoder_compute_units": "\(computeUnitsDescription(fastLoadEncoderComputeUnits))",
            "fast_load_decoder_compute_units": "\(computeUnitsDescription(fastLoadDecoderComputeUnits))",
            "device_temperature": String(format: "%.1f", deviceInfo.temperature),
            "cpu_usage": String(format: "%.2f", deviceInfo.cpuUsage),
            "battery_level": String(format: "%.2f", deviceInfo.batteryLevel),
            "is_low_power_mode": "\(deviceInfo.isLowPowerMode)",
            "thermal_state": deviceInfo.thermalState.description,
            "system_uptime": String(format: "%.0f", deviceInfo.systemUptime),
            "app_uptime": String(format: "%.0f", deviceInfo.appUptime),
            "disk_total_space_gb": bytesToGB(deviceInfo.diskTotalSpace),
            "disk_free_space_gb": bytesToGB(deviceInfo.diskFreeSpace),
        ]
        return tags
    }

    /// Helper function to get additional device info
    struct AppDeviceInfo {
        let temperature: Double
        let cpuUsage: Double
        let batteryLevel: Float
        let isLowPowerMode: Bool
        let thermalState: ProcessInfo.ThermalState
        let systemUptime: TimeInterval
        let appUptime: TimeInterval
        let diskTotalSpace: UInt64
        let diskFreeSpace: UInt64
    }

    func getDeviceInfo() -> AppDeviceInfo {
        let processInfo = ProcessInfo.processInfo
        let thermalState = processInfo.thermalState

        var temperature = 0.0
        var cpuUsage = 0.0
        var batteryLevel: Float = -1.0
        var isLowPowerMode = false

        #if os(iOS)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        batteryLevel = device.batteryLevel
        isLowPowerMode = processInfo.isLowPowerModeEnabled
        #endif

        // Note: Getting accurate CPU temperature and usage might require private APIs, which are not recommended for App Store apps
        // These are placeholder values and should be replaced with actual implementations if available
        temperature = 0.0 // Placeholder
        cpuUsage = 0.0 // Placeholder

        let systemUptime = ProcessInfo.processInfo.systemUptime
        let appUptime = Date().timeIntervalSince(self.appStartTime)

        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).last!
        let systemAttributes = try? fileManager.attributesOfFileSystem(forPath: documentDirectory.path)
        let diskTotalSpace = (systemAttributes?[.systemSize] as? NSNumber)?.uint64Value ?? 0
        let diskFreeSpace = (systemAttributes?[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0

        return AppDeviceInfo(
            temperature: temperature,
            cpuUsage: cpuUsage,
            batteryLevel: batteryLevel,
            isLowPowerMode: isLowPowerMode,
            thermalState: thermalState,
            systemUptime: systemUptime,
            appUptime: appUptime,
            diskTotalSpace: diskTotalSpace,
            diskFreeSpace: diskFreeSpace
        )
    }

    func computeUnitsDescription(_ computeUnits: MLComputeUnits) -> String {
        switch computeUnits {
            case .cpuOnly:
                return "cpuOnly"
            case .cpuAndGPU:
                return "cpuAndGPU"
            case .all:
                return "all"
            case .cpuAndNeuralEngine:
                return "cpuAndNeuralEngine"
            @unknown default:
                return "unknown"
        }
    }

    func getMemoryInfo() -> (free_mem: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, totalUsed: UInt64, totalPhysical: UInt64, totalAvailable: UInt64, swapUsed: UInt64, appUsed: UInt64, appAvailable: UInt64) {
        let processInfo = ProcessInfo.processInfo
        let totalPhysicalMemory = processInfo.physicalMemory

        #if os(iOS) || os(macOS)
        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let hostPort: host_t = mach_host_self()
        let resultMac = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }

        var availableBytes: UInt64 = 0
        var swapUsed: UInt64 = 0
        if resultMac == KERN_SUCCESS {
            let freeBytes = UInt64(vmStat.free_count) * UInt64(vm_page_size)
            let inactiveBytes = UInt64(vmStat.inactive_count) * UInt64(vm_page_size)
            availableBytes = freeBytes + inactiveBytes

            // Calculate swap usage
            swapUsed = UInt64(vmStat.swapouts) * UInt64(vm_page_size)
        }
        #else
        let availableBytes: UInt64 = 0 // Placeholder for other platforms
        let swapUsed: UInt64 = 0 // Placeholder for other platforms
        #endif

        var host_size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.stride)
        var host_info = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &host_info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(host_size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &host_size)
            }
        }

        var appUsed: UInt64 = 0
        var appAvailable: UInt64 = 0
        if result == KERN_SUCCESS {
            let pageSize = vm_kernel_page_size

            // Calculate the basic memory statistics
            let free = UInt64(host_info.free_count) * UInt64(pageSize)
            let active = UInt64(host_info.active_count) * UInt64(pageSize)
            let inactive = UInt64(host_info.inactive_count) * UInt64(pageSize)
            let wired = UInt64(host_info.wire_count) * UInt64(pageSize)
            let compressed = UInt64(host_info.compressor_page_count) * UInt64(pageSize)

            // Correct totalUsed calculation
            let totalUsed = totalPhysicalMemory - (free + inactive)
            let totalFree = free + inactive

            // Get memory usage of the current app
            var taskInfo = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }

            if kerr == KERN_SUCCESS {
                appUsed = UInt64(taskInfo.resident_size)
                appAvailable = UInt64(taskInfo.resident_size_max)
            }

            return (totalFree, active, inactive, wired, compressed, totalUsed, totalPhysicalMemory, availableBytes, swapUsed, appUsed, appAvailable)
        } else {
            return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        }
    }

}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var set = Set<Element>()
        return filter { set.insert($0).inserted }
    }
}

extension ProcessInfo.ThermalState {
    var description: String {
        switch self {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
        }
    }
}

extension Color {
    init(hex: String) {
        let cleanHexString = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var hexValue: UInt64 = 0
        Scanner(string: cleanHexString).scanHexInt64(&hexValue)
        let a, r, g, b: UInt64
        switch cleanHexString.count {
            case 3: // RGB (12-bit)
                (a, r, g, b) = (255, (hexValue >> 8) * 17, (hexValue >> 4 & 0xF) * 17, (hexValue & 0xF) * 17)
            case 6: // RGB (24-bit)
                (a, r, g, b) = (255, hexValue >> 16, hexValue >> 8 & 0xFF, hexValue & 0xFF)
            case 8: // ARGB (32-bit)
                (a, r, g, b) = (hexValue >> 24, hexValue >> 16 & 0xFF, hexValue >> 8 & 0xFF, hexValue & 0xFF)
            default:
                (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

/// If preview doesn't work due to FirebaseAnalyticsLogger, disable the Legacy Previews Execution in Editor -> Canvas
/// See https://github.com/firebase/firebase-ios-sdk/issues/14134#issuecomment-2483108641
#Preview {
    #if os(macOS)
    let sdkCoordinator = ArgmaxSDKCoordinator(
        keyProvider: ObfuscatedKeyProvider(mask: 12)
    )
    let processDiscoverer = AudioProcessDiscoverer()
    let deviceDiscoverer = AudioDeviceDiscoverer()
    let streamViewModel = StreamViewModel(
        sdkCoordinator: sdkCoordinator,
        audioProcessDiscoverer: processDiscoverer,
        audioDeviceDiscoverer: deviceDiscoverer
    )
    let transcribeViewModel = TranscribeViewModel(
        sdkCoordinator: sdkCoordinator
    )
    ContentView()
        .frame(width: 800, height: 500)
        .environmentObject(streamViewModel)
        .environmentObject(transcribeViewModel)
        .environmentObject(processDiscoverer)
        .environmentObject(deviceDiscoverer)
        .environmentObject(sdkCoordinator)
    #else
    let sdkCoordinator = ArgmaxSDKCoordinator(
        keyProvider: ObfuscatedKeyProvider(mask: 12)
    )
    let deviceDiscoverer = AudioDeviceDiscoverer()
    let liveActivityManager = LiveActivityManager()
    let streamViewModel = StreamViewModel(
        sdkCoordinator: sdkCoordinator,
        audioDeviceDiscoverer: deviceDiscoverer,
        liveActivityManager: liveActivityManager
    )
    let transcribeViewModel = TranscribeViewModel(
        sdkCoordinator: sdkCoordinator
    )
    ContentView()
        .environmentObject(streamViewModel)
        .environmentObject(transcribeViewModel)
        .environmentObject(deviceDiscoverer)
        .environmentObject(sdkCoordinator)
    #endif
}
