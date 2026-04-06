import Foundation
import SwiftUI
import CoreML
import Argmax

/// Single source of truth for all user-facing settings, persisted via UserDefaults.
/// Replaces the duplicated @AppStorage declarations that were scattered across 5+ view files.
final class AppSettings: ObservableObject {

    private let store: UserDefaults

    // MARK: - Model Selection

    @Published var selectedModel: String {
        didSet { store.set(selectedModel, forKey: "selectedModel") }
    }
    @Published var selectedDiarizationModelRaw: String {
        didSet { store.set(selectedDiarizationModelRaw, forKey: "selectedDiarizationModel") }
    }
    @Published var sortformerModeRaw: String {
        didSet { store.set(sortformerModeRaw, forKey: "sortformerMode") }
    }
    @Published var enableCustomVocabulary: Bool {
        didSet { store.set(enableCustomVocabulary, forKey: "enableCustomVocabulary") }
    }
    @Published var customVocabularyWords: [String] {
        didSet { store.set(customVocabularyWords, forKey: "customVocabularyWords") }
    }

    // MARK: - Compute Units

    @Published var encoderComputeUnits: MLComputeUnits {
        didSet { store.set(encoderComputeUnits.rawValue, forKey: "encoderComputeUnits") }
    }
    @Published var decoderComputeUnits: MLComputeUnits {
        didSet { store.set(decoderComputeUnits.rawValue, forKey: "decoderComputeUnits") }
    }
    @Published var segmenterComputeUnits: MLComputeUnits {
        didSet { store.set(segmenterComputeUnits.rawValue, forKey: "segmenterComputeUnits") }
    }
    @Published var embedderComputeUnits: MLComputeUnits {
        didSet { store.set(embedderComputeUnits.rawValue, forKey: "embedderComputeUnits") }
    }

    // MARK: - Decoding Options

    @Published var selectedTask: String {
        didSet { store.set(selectedTask, forKey: "selectedTask") }
    }
    @Published var selectedLanguage: String {
        didSet { store.set(selectedLanguage, forKey: "selectedLanguage") }
    }
    @Published var enableTimestamps: Bool {
        didSet { store.set(enableTimestamps, forKey: "enableTimestamps") }
    }
    @Published var enableSpecialCharacters: Bool {
        didSet { store.set(enableSpecialCharacters, forKey: "enableSpecialCharacters") }
    }
    @Published var enableDecoderPreview: Bool {
        didSet { store.set(enableDecoderPreview, forKey: "enableDecoderPreview") }
    }
    @Published var showNerdStats: Bool {
        didSet { store.set(showNerdStats, forKey: "showNerdStats") }
    }
    @Published var enablePromptPrefill: Bool {
        didSet { store.set(enablePromptPrefill, forKey: "enablePromptPrefill") }
    }
    @Published var enableCachePrefill: Bool {
        didSet { store.set(enableCachePrefill, forKey: "enableCachePrefill") }
    }
    @Published var temperatureStart: Double {
        didSet { store.set(temperatureStart, forKey: "temperatureStart") }
    }
    @Published var fallbackCount: Double {
        didSet { store.set(fallbackCount, forKey: "fallbackCount") }
    }
    @Published var compressionCheckWindow: Double {
        didSet { store.set(compressionCheckWindow, forKey: "compressionCheckWindow") }
    }
    @Published var sampleLength: Double {
        didSet { store.set(sampleLength, forKey: "sampleLength") }
    }
    @Published var chunkingStrategy: ChunkingStrategy {
        didSet { store.set(chunkingStrategy.rawValue, forKey: "chunkingStrategy") }
    }
    @Published var concurrentWorkerCount: Double {
        didSet { store.set(concurrentWorkerCount, forKey: "concurrentWorkerCount") }
    }

    // MARK: - Stream Settings

    @Published var useVAD: Bool {
        didSet { store.set(useVAD, forKey: "useVAD") }
    }
    @Published var transcriptionModeRaw: String {
        didSet { store.set(transcriptionModeRaw, forKey: "transcriptionMode") }
    }
    @Published var silenceThreshold: Double {
        didSet { store.set(silenceThreshold, forKey: "silenceThreshold") }
    }
    @Published var maxSilenceBufferLength: Double {
        didSet { store.set(maxSilenceBufferLength, forKey: "maxSilenceBufferLength") }
    }
    @Published var minProcessInterval: Double {
        didSet { store.set(minProcessInterval, forKey: "minProcessInterval") }
    }
    @Published var transcribeInterval: Double {
        didSet { store.set(transcribeInterval, forKey: "transcribeInterval") }
    }
    @Published var tokenConfirmationsNeeded: Double {
        didSet { store.set(tokenConfirmationsNeeded, forKey: "tokenConfirmationsNeeded") }
    }
    @Published var saveAudioToFile: Bool {
        didSet { store.set(saveAudioToFile, forKey: "saveAudioToFile") }
    }

    // MARK: - Diarization

    @Published var speakerInfoStrategyRaw: String {
        didSet { store.set(speakerInfoStrategyRaw, forKey: "speakerInfoStrategyRaw") }
    }
    @Published var minSpeakerCountRaw: Int {
        didSet { store.set(minSpeakerCountRaw, forKey: "minNumOfSpeakers") }
    }
    @Published var minActiveOffsetRaw: Double {
        didSet { store.set(minActiveOffsetRaw, forKey: "minActiveOffset") }
    }
    @Published var useExclusiveReconciliation: Bool {
        didSet { store.set(useExclusiveReconciliation, forKey: "useExclusiveReconciliation") }
    }
    @Published var streamingDiarizationFilterUnknown: Bool {
        didSet { store.set(streamingDiarizationFilterUnknown, forKey: "streamingDiarizationFilterUnknown") }
    }
    @Published var diarizationModeRaw: String {
        didSet { store.set(diarizationModeRaw, forKey: "diarizationMode") }
    }
    @Published var sortformerMaxWordGap: Double {
        didSet { store.set(sortformerMaxWordGap, forKey: "sortformerMaxWordGap") }
    }
    @Published var sortformerTolerance: Double {
        didSet { store.set(sortformerTolerance, forKey: "sortformerTolerance") }
    }

    // MARK: - Derived Properties

    var selectedDiarizationModel: DiarizationModelSelection? {
        DiarizationModelSelection(rawValue: selectedDiarizationModelRaw)
    }

    var speakerInfoStrategy: SpeakerInfoStrategy {
        SpeakerInfoStrategy(from: speakerInfoStrategyRaw) ?? .subsegment
    }

    var transcriptionMode: TranscriptionModeSelection {
        TranscriptionModeSelection(rawValue: transcriptionModeRaw) ?? .voiceTriggered
    }

    var diarizationMode: DiarizationMode {
        DiarizationMode(rawValue: diarizationModeRaw) ?? .sequential
    }

    var minNumOfSpeakers: Int? {
        minSpeakerCountRaw == -1 ? nil : minSpeakerCountRaw
    }

    var supportsCustomVocabulary: Bool {
        selectedModel.lowercased().contains("parakeet")
    }

    // MARK: - SDK Option Builders

    func decodingOptions(clipTimestamps: [Float] = []) -> DecodingOptions {
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
            clipTimestamps: clipTimestamps,
            concurrentWorkerCount: Int(concurrentWorkerCount),
            chunkingStrategy: chunkingStrategy
        )
    }

    var pyannoteDiarizationOptions: PyannoteDiarizationOptions {
        PyannoteDiarizationOptions(
            numberOfSpeakers: minNumOfSpeakers,
            minActiveOffset: minActiveOffsetRaw == -1.0 ? nil : Float(minActiveOffsetRaw),
            useExclusiveReconciliation: useExclusiveReconciliation
        )
    }

    @available(macOS 15, iOS 18, *)
    func sortformerDiarizationOptions(sortformerMode: SortformerStreamingConfig) -> SortformerDiarizationOptions {
        SortformerDiarizationOptions(
            sortformerMode: sortformerMode,
            maxWordGapInterval: sortformerMaxWordGap,
            tolerance: Float(sortformerTolerance)
        )
    }

    /// Returns the appropriate diarization options based on the selected model.
    /// For Sortformer, resolves the mode using `isRealtimeMode` (true for streaming, false for batch).
    /// Returns `nil` for Sortformer on OS versions older than macOS 15 / iOS 18.
    func diarizationOptions(isRealtimeMode: Bool = false) -> (any DiarizationOptions)? {
        guard let model = selectedDiarizationModel else { return nil }
        if model.isSortformer {
            if #available(macOS 15, iOS 18, *) {
                let resolvedMode = (SortformerModeSelection(rawValue: sortformerModeRaw) ?? .automatic)
                    .config(isRealtimeMode: isRealtimeMode)
                return sortformerDiarizationOptions(sortformerMode: resolvedMode)
            }
            return nil
        }
        return pyannoteDiarizationOptions
    }

    /// Snapshot current settings for session history.
    /// - Parameter resolvedSortformerMode: When provided, overrides the raw setting with the actual resolved mode
    ///   (e.g. "Realtime (auto)" for streaming with automatic selection).
    func captureSettings(diarizationMode: String, resolvedSortformerMode: String? = nil, customVocabularyWords: [String] = []) -> SettingsSnapshot {
        SettingsSnapshot(
            whisperKitModel: selectedModel,
            diarizationModel: selectedDiarizationModelRaw,
            sortformerMode: resolvedSortformerMode ?? sortformerModeRaw,
            enableTimestamps: enableTimestamps,
            temperatureStart: temperatureStart,
            fallbackCount: fallbackCount,
            sampleLength: sampleLength,
            silenceThreshold: silenceThreshold,
            transcriptionMode: transcriptionModeRaw,
            chunkingStrategy: chunkingStrategy.rawValue,
            concurrentWorkerCount: concurrentWorkerCount,
            encoderComputeUnits: String(describing: encoderComputeUnits),
            decoderComputeUnits: String(describing: decoderComputeUnits),
            diarizationMode: diarizationMode,
            speakerInfoStrategy: speakerInfoStrategyRaw,
            minNumOfSpeakers: minSpeakerCountRaw,
            enableCustomVocabulary: enableCustomVocabulary,
            customVocabularyWords: customVocabularyWords
        )
    }

    // MARK: - Defaults

    private enum Defaults {
        static let selectedTask = "transcribe"
        static let selectedLanguage = "english"
        static let enableTimestamps = true
        static let enableSpecialCharacters = false
        static let enableDecoderPreview = true
        static let showNerdStats = false
        static let enablePromptPrefill = true
        static let enableCachePrefill = true
        static let temperatureStart = 0.0
        static let fallbackCount = 5.0
        static let compressionCheckWindow = 60.0
        static let sampleLength = 224.0
        static let chunkingStrategy = ChunkingStrategy.vad
        static let concurrentWorkerCount = 4.0
        static let useVAD = true
        static let transcriptionMode = TranscriptionModeSelection.voiceTriggered.rawValue
        static let silenceThreshold = 0.2
        static let maxSilenceBufferLength = 10.0
        static let minProcessInterval = 0.3
        static let transcribeInterval = 0.1
        static let tokenConfirmationsNeeded = 2.0
        static let saveAudioToFile = true
        static let speakerInfoStrategyRaw = "subsegment"
        static let minSpeakerCountRaw = -1
        static let minActiveOffsetRaw = -1.0
        static let useExclusiveReconciliation = true
        static let streamingDiarizationFilterUnknown = false
        static let sortformerModeRaw = SortformerModeSelection.automatic.rawValue
        static let diarizationModeRaw = DiarizationMode.sequential.rawValue
        static let sortformerMaxWordGap = 0.17
        static let sortformerTolerance = 0.1
    }

    /// True when any setting exposed in the Settings panel differs from its default value.
    var hasNonDefaultSettings: Bool {
        selectedTask != Defaults.selectedTask ||
        selectedLanguage != Defaults.selectedLanguage ||
        enableTimestamps != Defaults.enableTimestamps ||
        enableSpecialCharacters != Defaults.enableSpecialCharacters ||
        enableDecoderPreview != Defaults.enableDecoderPreview ||
        showNerdStats != Defaults.showNerdStats ||
        enablePromptPrefill != Defaults.enablePromptPrefill ||
        enableCachePrefill != Defaults.enableCachePrefill ||
        temperatureStart != Defaults.temperatureStart ||
        fallbackCount != Defaults.fallbackCount ||
        compressionCheckWindow != Defaults.compressionCheckWindow ||
        sampleLength != Defaults.sampleLength ||
        chunkingStrategy != Defaults.chunkingStrategy ||
        concurrentWorkerCount != Defaults.concurrentWorkerCount ||
        useVAD != Defaults.useVAD ||
        transcriptionModeRaw != Defaults.transcriptionMode ||
        silenceThreshold != Defaults.silenceThreshold ||
        maxSilenceBufferLength != Defaults.maxSilenceBufferLength ||
        minProcessInterval != Defaults.minProcessInterval ||
        transcribeInterval != Defaults.transcribeInterval ||
        tokenConfirmationsNeeded != Defaults.tokenConfirmationsNeeded ||
        saveAudioToFile != Defaults.saveAudioToFile ||
        speakerInfoStrategyRaw != Defaults.speakerInfoStrategyRaw ||
        minSpeakerCountRaw != Defaults.minSpeakerCountRaw ||
        minActiveOffsetRaw != Defaults.minActiveOffsetRaw ||
        useExclusiveReconciliation != Defaults.useExclusiveReconciliation ||
        streamingDiarizationFilterUnknown != Defaults.streamingDiarizationFilterUnknown ||
        sortformerModeRaw != Defaults.sortformerModeRaw ||
        diarizationModeRaw != Defaults.diarizationModeRaw ||
        sortformerMaxWordGap != Defaults.sortformerMaxWordGap ||
        sortformerTolerance != Defaults.sortformerTolerance
    }

    /// Resets all settings panel values to their defaults. Does not affect model selection or custom vocabulary.
    func restoreDefaults() {
        selectedTask = Defaults.selectedTask
        selectedLanguage = Defaults.selectedLanguage
        enableTimestamps = Defaults.enableTimestamps
        enableSpecialCharacters = Defaults.enableSpecialCharacters
        enableDecoderPreview = Defaults.enableDecoderPreview
        showNerdStats = Defaults.showNerdStats
        enablePromptPrefill = Defaults.enablePromptPrefill
        enableCachePrefill = Defaults.enableCachePrefill
        temperatureStart = Defaults.temperatureStart
        fallbackCount = Defaults.fallbackCount
        compressionCheckWindow = Defaults.compressionCheckWindow
        sampleLength = Defaults.sampleLength
        chunkingStrategy = Defaults.chunkingStrategy
        concurrentWorkerCount = Defaults.concurrentWorkerCount
        useVAD = Defaults.useVAD
        transcriptionModeRaw = Defaults.transcriptionMode
        silenceThreshold = Defaults.silenceThreshold
        maxSilenceBufferLength = Defaults.maxSilenceBufferLength
        minProcessInterval = Defaults.minProcessInterval
        transcribeInterval = Defaults.transcribeInterval
        tokenConfirmationsNeeded = Defaults.tokenConfirmationsNeeded
        saveAudioToFile = Defaults.saveAudioToFile
        speakerInfoStrategyRaw = Defaults.speakerInfoStrategyRaw
        minSpeakerCountRaw = Defaults.minSpeakerCountRaw
        minActiveOffsetRaw = Defaults.minActiveOffsetRaw
        useExclusiveReconciliation = Defaults.useExclusiveReconciliation
        streamingDiarizationFilterUnknown = Defaults.streamingDiarizationFilterUnknown
        sortformerModeRaw = Defaults.sortformerModeRaw
        diarizationModeRaw = Defaults.diarizationModeRaw
        sortformerMaxWordGap = Defaults.sortformerMaxWordGap
        sortformerTolerance = Defaults.sortformerTolerance
    }

    // MARK: - Init

    init(store: UserDefaults = .standard) {
        self.store = store
        store.register(defaults: [
            "selectedModel": "",
            "selectedDiarizationModel": "sortformer",
            "sortformerMode": SortformerModeSelection.automatic.rawValue,
            "enableCustomVocabulary": false,
            "customVocabularyWords": [String](),
            "encoderComputeUnits": MLComputeUnits.cpuAndNeuralEngine.rawValue,
            "decoderComputeUnits": MLComputeUnits.cpuAndNeuralEngine.rawValue,
            "segmenterComputeUnits": MLComputeUnits.cpuOnly.rawValue,
            "embedderComputeUnits": MLComputeUnits.cpuAndNeuralEngine.rawValue,
            "selectedTask": "transcribe",
            "selectedLanguage": "english",
            "enableTimestamps": true,
            "enableSpecialCharacters": false,
            "enableDecoderPreview": true,
            "showNerdStats": false,
            "enablePromptPrefill": true,
            "enableCachePrefill": true,
            "temperatureStart": 0.0,
            "fallbackCount": 5.0,
            "compressionCheckWindow": 60.0,
            "sampleLength": 224.0,
            "chunkingStrategy": ChunkingStrategy.vad.rawValue,
            "concurrentWorkerCount": 4.0,
            "useVAD": true,
            "transcriptionMode": TranscriptionModeSelection.voiceTriggered.rawValue,
            "silenceThreshold": 0.2,
            "maxSilenceBufferLength": 10.0,
            "minProcessInterval": 0.3,
            "transcribeInterval": 0.1,
            "tokenConfirmationsNeeded": 2.0,
            "saveAudioToFile": true,
            "speakerInfoStrategyRaw": "subsegment",
            "minNumOfSpeakers": -1,
            "minActiveOffset": -1.0,
            "useExclusiveReconciliation": true,
            "streamingDiarizationFilterUnknown": false,
            "diarizationMode": DiarizationMode.sequential.rawValue,
            "sortformerMaxWordGap": 0.17,
            "sortformerTolerance": 0.1,
        ])

        self.selectedModel = store.string(forKey: "selectedModel") ?? ""
        self.selectedDiarizationModelRaw = store.string(forKey: "selectedDiarizationModel") ?? "sortformer"
        self.sortformerModeRaw = store.string(forKey: "sortformerMode") ?? SortformerModeSelection.automatic.rawValue
        self.enableCustomVocabulary = store.bool(forKey: "enableCustomVocabulary")
        self.customVocabularyWords = store.stringArray(forKey: "customVocabularyWords") ?? []

        self.encoderComputeUnits = MLComputeUnits(rawValue: store.integer(forKey: "encoderComputeUnits")) ?? .cpuAndNeuralEngine
        self.decoderComputeUnits = MLComputeUnits(rawValue: store.integer(forKey: "decoderComputeUnits")) ?? .cpuAndNeuralEngine
        self.segmenterComputeUnits = MLComputeUnits(rawValue: store.integer(forKey: "segmenterComputeUnits")) ?? .cpuOnly
        self.embedderComputeUnits = MLComputeUnits(rawValue: store.integer(forKey: "embedderComputeUnits")) ?? .cpuAndNeuralEngine

        self.selectedTask = store.string(forKey: "selectedTask") ?? "transcribe"
        self.selectedLanguage = store.string(forKey: "selectedLanguage") ?? "english"
        self.enableTimestamps = store.bool(forKey: "enableTimestamps")
        self.enableSpecialCharacters = store.bool(forKey: "enableSpecialCharacters")
        self.enableDecoderPreview = store.bool(forKey: "enableDecoderPreview")
        self.showNerdStats = store.bool(forKey: "showNerdStats")
        self.enablePromptPrefill = store.bool(forKey: "enablePromptPrefill")
        self.enableCachePrefill = store.bool(forKey: "enableCachePrefill")
        self.temperatureStart = store.double(forKey: "temperatureStart")
        self.fallbackCount = store.double(forKey: "fallbackCount")
        self.compressionCheckWindow = store.double(forKey: "compressionCheckWindow")
        self.sampleLength = store.double(forKey: "sampleLength")
        self.chunkingStrategy = ChunkingStrategy(rawValue: store.string(forKey: "chunkingStrategy") ?? "vad") ?? .vad
        self.concurrentWorkerCount = store.double(forKey: "concurrentWorkerCount")

        self.useVAD = store.bool(forKey: "useVAD")
        self.transcriptionModeRaw = store.string(forKey: "transcriptionMode") ?? TranscriptionModeSelection.voiceTriggered.rawValue
        self.silenceThreshold = store.double(forKey: "silenceThreshold")
        self.maxSilenceBufferLength = store.double(forKey: "maxSilenceBufferLength")
        self.minProcessInterval = store.double(forKey: "minProcessInterval")
        self.transcribeInterval = store.double(forKey: "transcribeInterval")
        self.tokenConfirmationsNeeded = store.double(forKey: "tokenConfirmationsNeeded")
        self.saveAudioToFile = store.bool(forKey: "saveAudioToFile")

        self.speakerInfoStrategyRaw = store.string(forKey: "speakerInfoStrategyRaw") ?? "subsegment"
        self.minSpeakerCountRaw = store.integer(forKey: "minNumOfSpeakers")
        self.minActiveOffsetRaw = store.double(forKey: "minActiveOffset")
        self.useExclusiveReconciliation = store.bool(forKey: "useExclusiveReconciliation")
        self.streamingDiarizationFilterUnknown = store.bool(forKey: "streamingDiarizationFilterUnknown")
        self.diarizationModeRaw = store.string(forKey: "diarizationMode") ?? DiarizationMode.sequential.rawValue
        self.sortformerMaxWordGap = store.double(forKey: "sortformerMaxWordGap")
        self.sortformerTolerance = store.double(forKey: "sortformerTolerance")
    }
}
