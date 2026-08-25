import Foundation
import SwiftUI
import CoreML
import Argmax

/// Speech-to-text model families the app distinguishes. Add cases as new families are supported.
enum TranscriptionModelFamily {
    case whisper
    case parakeet
    case qwen

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        case .qwen: return "Qwen3-ASR"
        }
    }

    /// Whether the family lets the caller hint/force a source language. Families that can't be
    /// hinted only auto-detect among their supported languages.
    var supportsLanguageHinting: Bool {
        switch self {
        case .whisper: return true
        case .parakeet: return false
        // Qwen3-ASR accepts an optional language name (nil = auto-detect), so it can be hinted.
        case .qwen: return true
        }
    }

    /// Whether the family can pair with a custom-vocabulary (CTC keyword-boosting) model. Only
    /// Parakeet is supported by the SDK; pairing custom vocab with Whisper or Qwen is a config
    /// incompatibility that fails at load, so the UI disables the selector for those families.
    var supportsCustomVocabulary: Bool {
        switch self {
        case .parakeet: return true
        case .whisper, .qwen: return false
        }
    }

    /// Best-effort family inference from a model identifier string, used *before* a transcriber is
    /// loaded (e.g. to route the load path). Qwen variants contain "qwen"; Parakeet contain
    /// "parakeet"; everything else is treated as Whisper. Once a model is loaded, prefer the
    /// SDK-derived `ArgmaxSDKCoordinator.loadedModelLanguageInfo` instead.
    init(modelName: String) {
        let lower = modelName.lowercased()
        if lower.contains("qwen") {
            self = .qwen
        } else if lower.contains("parakeet") {
            self = .parakeet
        } else {
            self = .whisper
        }
    }
}

/// Language support of a loaded transcription model, resolved from the SDK (not the model name).
struct LoadedModelLanguageInfo {
    let family: TranscriptionModelFamily
    /// SDK language codes the model supports (e.g. `["en"]`, the Parakeet V3 set, or the full
    /// Whisper set). Mapped to display names via `AppSettings.languageNames(forCodes:)`.
    let supportedLanguageCodes: [String]
    /// Explicit display names for families whose supported set isn't representable through
    /// `Constants.languages` codes (e.g. Qwen supports Cantonese/Filipino/Macedonian/Malay, which
    /// aren't in Whisper's code map). When non-nil, the language UI uses these verbatim instead of
    /// mapping `supportedLanguageCodes`. Stored lowercase to match the picker's `.capitalized` render.
    var supportedLanguageNames: [String]? = nil
}

/// Single source of truth for all user-facing settings, persisted via UserDefaults.
///
/// Each setting has three things in lockstep:
/// - a `Keys` entry (the persisted key string),
/// - a `Defaults` entry (the registered default value),
/// - an `@Published` property whose `didSet` writes back to `store`.
///
/// Routing every read/write through `Keys.*` and seeding `register(defaults:)` from
/// `Defaults.*` means a default-value change in one place propagates everywhere.
final class AppSettings: ObservableObject {

    /// Sentinel value for `selectedLanguage` that turns on automatic language detection
    /// (`detectLanguage: true`, `language: nil`) instead of forcing a specific source language.
    /// Presented as the first entry in the Source Language picker.
    static let detectLanguageOption = "Detect language"

    /// Model identifier for Qwen3-ASR 1.7B. Must match the HF folder name inside
    /// `argmaxinc/qwenasrkit-pro` so the ModelStore background download (keyed by
    /// `(modelVariant, repo)`) attributes byte progress to the transcription row correctly.
    /// Display name "Qwen3-ASR 1.7B" is applied separately in `pickerTranscriptionModelName`.
    static let qwenModelName = "qwen3-asr"

    /// HF repo holding the Qwen3-ASR assets. Single source for the download, verification, and
    /// pipeline-row lookups, which key on `(modelVariant, repo)` and silently disagree if the
    /// string drifts in one of them.
    static let qwenModelRepo = "argmaxinc/qwenasrkit-pro"

    /// Languages Qwen3-ASR accepts as a hint, lowercase to match the picker's `.capitalized` render
    /// and the `.capitalized` mapping done before handing the name to the SDK. This mirrors the
    /// SDK's own supported set (surfaced verbatim in `ArgmaxError` when an unknown language
    /// is passed); it only partially overlaps Whisper/Parakeet -- e.g. Cantonese, Filipino,
    /// Macedonian, and Malay are Qwen-only here. Auto-detect ("None" in the SDK) is offered
    /// separately via the pinned `detectLanguageOption`, so it's intentionally excluded from this list.
    static let qwenSupportedLanguageNames: [String] = [
        "arabic", "cantonese", "chinese", "czech", "danish", "dutch", "english", "filipino",
        "finnish", "french", "german", "greek", "hindi", "hungarian", "indonesian", "italian",
        "japanese", "korean", "macedonian", "malay", "persian", "polish", "portuguese", "romanian",
        "russian", "spanish", "swedish", "thai", "turkish", "vietnamese",
    ]

    private let store: UserDefaults

    /// `-1` is the persisted sentinel for "unset" on numeric settings whose UI offers an "Auto"
    /// / "None" option (e.g. minimum speaker count). Encoding `Optional` as `-1` keeps the
    /// UserDefaults type stable across versions; the typed `minNumOfSpeakers` accessor exposes
    /// it as `Int?` to callers.
    private static let optionalNumericSentinel: Int = -1
    private static let optionalDoubleSentinel: Double = -1.0

    // MARK: - Persistence keys

    private enum Keys {
        static let selectedModel = "selectedModel"
        static let selectedDiarizationModel = "selectedDiarizationModel"
        static let sortformerMode = "sortformerMode"
        static let selectedCustomVocabularyModel = "selectedCustomVocabularyModel"
        static let customVocabularyWords = "customVocabularyWords"
        static let backgroundDownloadWifiOnly = "bgDownloadWifiOnly"
        static let encoderComputeUnits = "encoderComputeUnits"
        static let decoderComputeUnits = "decoderComputeUnits"
        static let segmenterComputeUnits = "segmenterComputeUnits"
        static let embedderComputeUnits = "embedderComputeUnits"
        static let selectedTask = "selectedTask"
        static let selectedLanguage = "selectedLanguage"
        static let languageByModel = "languageByModel"
        static let enableTimestamps = "enableTimestamps"
        static let enableSpecialCharacters = "enableSpecialCharacters"
        static let enableDecoderPreview = "enableDecoderPreview"
        static let showNerdStats = "showNerdStats"
        static let enablePromptPrefill = "enablePromptPrefill"
        static let temperatureStart = "temperatureStart"
        static let fallbackCount = "fallbackCount"
        static let compressionCheckWindow = "compressionCheckWindow"
        static let sampleLength = "sampleLength"
        static let chunkingStrategy = "chunkingStrategy"
        static let concurrentWorkerCount = "concurrentWorkerCount"
        static let useVAD = "useVAD"
        static let transcriptionMode = "transcriptionMode"
        static let silenceThreshold = "silenceThreshold"
        static let maxSilenceBufferLength = "maxSilenceBufferLength"
        static let minProcessInterval = "minProcessInterval"
        static let transcribeInterval = "transcribeInterval"
        static let saveAudioToFile = "saveAudioToFile"
        static let speakerInfoStrategy = "speakerInfoStrategyRaw"
        static let minSpeakerCount = "minNumOfSpeakers"
        static let minActiveOffset = "minActiveOffset"
        static let useExclusiveReconciliation = "useExclusiveReconciliation"
        static let streamingDiarizationFilterUnknown = "streamingDiarizationFilterUnknown"
        static let diarizationMode = "diarizationMode"
        static let sortformerMaxWordGap = "sortformerMaxWordGap"
        static let sortformerTolerance = "sortformerTolerance"
        static let qwenSpecDecode = "qwenSpecDecode"
        static let qwenOptimization = "qwenOptimization"
        static let dictationSilenceThreshold = "dictationSilenceThreshold"
        static let inverseTextNormalization = "inverseTextNormalization"
        static let groupSpeakerBubbles = "groupSpeakerBubbles"
        static let warmWhileClosed = "warmWhileClosed"
        static let captureReplayTraces = "captureReplayTraces"
    }

    // MARK: - Defaults

    private enum Defaults {
        static let selectedModel = ""
        static let selectedDiarizationModelRaw = DiarizationModelSelection.sortformer.rawValue
        static let sortformerModeRaw = SortformerModeSelection.automatic.rawValue
        static let selectedCustomVocabularyModelRaw = CustomVocabularyModelSelection.canary.rawValue
        static let customVocabularyWords: [String] = []
        static let backgroundDownloadWifiOnly = true
        static let encoderComputeUnits = MLComputeUnits.cpuAndNeuralEngine
        static let decoderComputeUnits = MLComputeUnits.cpuAndNeuralEngine
        static let segmenterComputeUnits = MLComputeUnits.cpuOnly
        static let embedderComputeUnits = MLComputeUnits.cpuAndNeuralEngine
        static let selectedTask = "transcribe"
        static let selectedLanguage = "english"
        static let languageByModel: [String: String] = [:]
        static let enableTimestamps = true
        static let enableSpecialCharacters = false
        static let enableDecoderPreview = true
        static let showNerdStats = false
        static let enablePromptPrefill = true
        static let temperatureStart = 0.0
        static let fallbackCount = 5.0
        static let compressionCheckWindow = 60.0
        static let sampleLength = 448.0
        static let chunkingStrategy = ChunkingStrategy.vad
        static let concurrentWorkerCount = 4.0
        static let useVAD = true
        static let transcriptionModeRaw = TranscriptionModeSelection.voiceTriggered.rawValue
        static let silenceThreshold = 0.2
        static let maxSilenceBufferLength = 10.0
        static let minProcessInterval = 2.0
        static let transcribeInterval = 1.0
        static let saveAudioToFile = true
        static let speakerInfoStrategyRaw = "subsegment"
        static let minSpeakerCountRaw = AppSettings.optionalNumericSentinel
        static let minActiveOffsetRaw = AppSettings.optionalDoubleSentinel
        static let useExclusiveReconciliation = true
        static let streamingDiarizationFilterUnknown = false
        static let sortformerMaxWordGap = 0.17
        static let sortformerTolerance = 0.1
        static let diarizationModeRaw = DiarizationMode.sequential.rawValue
        // Speculative decoding on by default (matches `WhisperKitProConfig.qwen3ASR(specDecode: true)`).
        static let qwenSpecDecode = true
        // Matches `WhisperKitProConfig.qwen3ASR(optimization: .auto)`.
        static let qwenOptimizationRaw = ModelOptimizationMode.auto.rawValue
        // Matches `StreamTranscriptionMode.defaultSilenceThreshold` in the SDK.
        static let dictationSilenceThreshold = 0.2
        static let inverseTextNormalization = false
        static let groupSpeakerBubbles = false
        /// Off until the user asks for it: the Mac App Store expects a background login item
        /// to follow an explicit, visible user action, not to appear on first launch.
        static let warmWhileClosed = false
        /// Developer diagnostic: per-session replay traces cost memory during a session and a
        /// JSON write at save, so they are opt-in from Settings > Advanced.
        static let captureReplayTraces = false
    }

    // MARK: - Model Selection

    @Published var selectedModel: String {
        didSet { store.set(selectedModel, forKey: Keys.selectedModel) }
    }
    @Published var selectedDiarizationModelRaw: String {
        didSet { store.set(selectedDiarizationModelRaw, forKey: Keys.selectedDiarizationModel) }
    }
    @Published var sortformerModeRaw: String {
        didSet { store.set(sortformerModeRaw, forKey: Keys.sortformerMode) }
    }
    /// Custom-vocabulary CTC variant selection. `"none"` disables; `"canary"` (default) or
    /// `"parakeet"` selects a CTC model that boosts keywords during transcription. The variant
    /// must match the transcription model's mel count (canary 128, parakeet 80) at load time --
    /// the SDK surfaces a mismatch as a load error.
    @Published var selectedCustomVocabularyModelRaw: String {
        didSet { store.set(selectedCustomVocabularyModelRaw, forKey: Keys.selectedCustomVocabularyModel) }
    }
    @Published var customVocabularyWords: [String] {
        didSet { store.set(customVocabularyWords, forKey: Keys.customVocabularyWords) }
    }

    // MARK: - Downloads

    /// When `true` (default), model downloads avoid cellular. Shared with the test section's
    /// `@AppStorage("bgDownloadWifiOnly")` so both surfaces read/write the same value.
    @Published var backgroundDownloadWifiOnly: Bool {
        didSet { store.set(backgroundDownloadWifiOnly, forKey: Keys.backgroundDownloadWifiOnly) }
    }

    // MARK: - Compute Units

    @Published var encoderComputeUnits: MLComputeUnits {
        didSet { store.set(encoderComputeUnits.rawValue, forKey: Keys.encoderComputeUnits) }
    }
    @Published var decoderComputeUnits: MLComputeUnits {
        didSet { store.set(decoderComputeUnits.rawValue, forKey: Keys.decoderComputeUnits) }
    }
    @Published var segmenterComputeUnits: MLComputeUnits {
        didSet { store.set(segmenterComputeUnits.rawValue, forKey: Keys.segmenterComputeUnits) }
    }
    @Published var embedderComputeUnits: MLComputeUnits {
        didSet { store.set(embedderComputeUnits.rawValue, forKey: Keys.embedderComputeUnits) }
    }

    // MARK: - Decoding Options

    @Published var selectedTask: String {
        didSet { store.set(selectedTask, forKey: Keys.selectedTask) }
    }
    @Published var selectedLanguage: String {
        didSet {
            store.set(selectedLanguage, forKey: Keys.selectedLanguage)
            // Remember the choice per model so it's restored when that model is loaded again.
            if !selectedModel.isEmpty {
                languageByModel[selectedModel] = selectedLanguage
            }
        }
    }

    /// Per-model language memory: maps a transcription model name to its last-chosen language
    /// (name or the detect sentinel). Restored in `normalizeSelectedLanguage` when a model loads.
    @Published var languageByModel: [String: String] {
        didSet { store.set(languageByModel, forKey: Keys.languageByModel) }
    }
    @Published var enableTimestamps: Bool {
        didSet { store.set(enableTimestamps, forKey: Keys.enableTimestamps) }
    }
    @Published var enableSpecialCharacters: Bool {
        didSet { store.set(enableSpecialCharacters, forKey: Keys.enableSpecialCharacters) }
    }
    @Published var enableDecoderPreview: Bool {
        didSet { store.set(enableDecoderPreview, forKey: Keys.enableDecoderPreview) }
    }
    @Published var showNerdStats: Bool {
        didSet { store.set(showNerdStats, forKey: Keys.showNerdStats) }
    }
    @Published var enablePromptPrefill: Bool {
        didSet { store.set(enablePromptPrefill, forKey: Keys.enablePromptPrefill) }
    }
    @Published var temperatureStart: Double {
        didSet { store.set(temperatureStart, forKey: Keys.temperatureStart) }
    }
    @Published var fallbackCount: Double {
        didSet { store.set(fallbackCount, forKey: Keys.fallbackCount) }
    }
    @Published var compressionCheckWindow: Double {
        didSet { store.set(compressionCheckWindow, forKey: Keys.compressionCheckWindow) }
    }
    @Published var sampleLength: Double {
        didSet { store.set(sampleLength, forKey: Keys.sampleLength) }
    }
    @Published var chunkingStrategy: ChunkingStrategy {
        didSet { store.set(chunkingStrategy.rawValue, forKey: Keys.chunkingStrategy) }
    }
    @Published var concurrentWorkerCount: Double {
        didSet { store.set(concurrentWorkerCount, forKey: Keys.concurrentWorkerCount) }
    }

    // MARK: - Stream Settings

    @Published var useVAD: Bool {
        didSet { store.set(useVAD, forKey: Keys.useVAD) }
    }
    @Published var transcriptionModeRaw: String {
        didSet { store.set(transcriptionModeRaw, forKey: Keys.transcriptionMode) }
    }
    @Published var silenceThreshold: Double {
        didSet { store.set(silenceThreshold, forKey: Keys.silenceThreshold) }
    }
    @Published var maxSilenceBufferLength: Double {
        didSet { store.set(maxSilenceBufferLength, forKey: Keys.maxSilenceBufferLength) }
    }
    @Published var minProcessInterval: Double {
        didSet { store.set(minProcessInterval, forKey: Keys.minProcessInterval) }
    }
    @Published var transcribeInterval: Double {
        didSet { store.set(transcribeInterval, forKey: Keys.transcribeInterval) }
    }
    @Published var saveAudioToFile: Bool {
        didSet { store.set(saveAudioToFile, forKey: Keys.saveAudioToFile) }
    }

    // MARK: - Qwen3-ASR Options

    /// Speculative decoding for Qwen. Maps to `WhisperKitProConfig.qwen3ASR(specDecode:)`, which is a
    /// *load-time* flag -- changing it only takes effect the next time the Qwen model is loaded.
    @Published var qwenSpecDecode: Bool {
        didSet { store.set(qwenSpecDecode, forKey: Keys.qwenSpecDecode) }
    }

    /// Memory/latency trade-off for the Qwen text decoder. Maps to
    /// `WhisperKitProConfig.qwen3ASR(optimization:)`, a *load-time* flag -- changing it only takes
    /// effect the next time the Qwen model is loaded. Stored as the enum's raw string.
    @Published var qwenOptimizationRaw: String {
        didSet { store.set(qwenOptimizationRaw, forKey: Keys.qwenOptimization) }
    }

    var qwenOptimization: ModelOptimizationMode {
        ModelOptimizationMode(rawValue: qwenOptimizationRaw) ?? .auto
    }

    /// Silence threshold passed to `WhisperKitPro.makeDictationSession(silenceThreshold:)`.
    /// Controls how long the dictation session waits for speech before auto-finishing.
    /// SDK default (`StreamTranscriptionMode.defaultSilenceThreshold`) is 0.2.
    @Published var dictationSilenceThreshold: Double {
        didSet { store.set(dictationSilenceThreshold, forKey: Keys.dictationSilenceThreshold) }
    }

    // MARK: - Text Processing

    /// Applies inverse text normalization (spoken-form -> written-form, e.g. "twenty twenty" -> "2020")
    /// to final output text when the output language is supported. Off by default (backward compatible).
    @Published var inverseTextNormalization: Bool {
        didSet { store.set(inverseTextNormalization, forKey: Keys.inverseTextNormalization) }
    }

    /// macOS only: whether the user has asked the app to keep models warm while it is closed,
    /// which runs the app headless on a `launchd` heartbeat (System Settings -> General ->
    /// Login Items & Extensions).
    ///
    /// This preference, not the presence of the bundled agent plist, is what registers the
    /// login item. The SDK would otherwise auto-enable the agent at `ModelWarmup.register()`
    /// simply because the app ships the plist -- fine for a direct-download app, but the Mac
    /// App Store expects background items to follow an explicit user action. `Playground.swift`
    /// reads this at launch and calls `disableBackgroundAgent()` while it is off.
    @Published var warmWhileClosed: Bool {
        didSet { store.set(warmWhileClosed, forKey: Keys.warmWhileClosed) }
    }

    /// Records a JSON replay trace per session (Settings > Advanced). Developer diagnostic.
    @Published var captureReplayTraces: Bool {
        didSet { store.set(captureReplayTraces, forKey: Keys.captureReplayTraces) }
    }

    // MARK: - ITN Status

    /// Language names (lowercase) for which Inverse Text Normalization is not supported.
    /// These are Qwen-only languages outside the ITN model's training set.
    static let itnUnsupportedLanguageNames: Set<String> = [
        "cantonese", "macedonian", "filipino", "malay",
    ]

    enum ITNStatus: Equatable {
        case active
        case inactive
        case unsupportedLanguage
        /// Setting is on but the loaded model was initialized with ITN off -- reload required.
        case reloadRequired
    }

    /// Returns the effective ITN status given the current toggle state, detected language, and the
    /// ITN value the model was actually loaded with.
    /// - `inactive`: toggle is off
    /// - `reloadRequired`: toggle is on but loaded model has ITN off (setting changed after load)
    /// - `unsupportedLanguage`: toggle on, loaded with ITN, but detected language has no ITN support
    /// - `active`: toggle on, loaded with ITN, language supported (or not yet detected)
    func itnStatus(detectedLanguage: String?, loadedITNEnabled: Bool?) -> ITNStatus {
        guard inverseTextNormalization else { return .inactive }
        if let loaded = loadedITNEnabled, !loaded { return .reloadRequired }
        if let lang = detectedLanguage,
           !lang.isEmpty, lang != "auto",
           Self.itnUnsupportedLanguageNames.contains(lang.lowercased()) {
            return .unsupportedLanguage
        }
        return .active
    }

    // MARK: - Diarization

    @Published var speakerInfoStrategyRaw: String {
        didSet { store.set(speakerInfoStrategyRaw, forKey: Keys.speakerInfoStrategy) }
    }
    @Published var minSpeakerCountRaw: Int {
        didSet { store.set(minSpeakerCountRaw, forKey: Keys.minSpeakerCount) }
    }
    @Published var minActiveOffsetRaw: Double {
        didSet { store.set(minActiveOffsetRaw, forKey: Keys.minActiveOffset) }
    }
    @Published var useExclusiveReconciliation: Bool {
        didSet { store.set(useExclusiveReconciliation, forKey: Keys.useExclusiveReconciliation) }
    }
    @Published var streamingDiarizationFilterUnknown: Bool {
        didSet { store.set(streamingDiarizationFilterUnknown, forKey: Keys.streamingDiarizationFilterUnknown) }
    }
    @Published var diarizationModeRaw: String {
        didSet { store.set(diarizationModeRaw, forKey: Keys.diarizationMode) }
    }
    @Published var sortformerMaxWordGap: Double {
        didSet { store.set(sortformerMaxWordGap, forKey: Keys.sortformerMaxWordGap) }
    }
    @Published var sortformerTolerance: Double {
        didSet { store.set(sortformerTolerance, forKey: Keys.sortformerTolerance) }
    }
    @Published var groupSpeakerBubbles: Bool {
        didSet { store.set(groupSpeakerBubbles, forKey: Keys.groupSpeakerBubbles) }
    }

    // MARK: - Derived Properties

    var selectedDiarizationModel: DiarizationModelSelection? {
        DiarizationModelSelection(rawValue: selectedDiarizationModelRaw)
    }

    var selectedCustomVocabularyModel: CustomVocabularyModelSelection? {
        CustomVocabularyModelSelection(rawValue: selectedCustomVocabularyModelRaw)
    }

    /// Convenience boolean for callers that need to know whether custom vocabulary is active.
    /// Derived from the picker selection rather than a separate toggle.
    var enableCustomVocabulary: Bool { selectedCustomVocabularyModel != nil }

    var speakerInfoStrategy: SpeakerInfoStrategy {
        if speakerInfoStrategyRaw == "word" { return .subsegment(betweenWordThreshold: 0.0) }
        return SpeakerInfoStrategy(from: speakerInfoStrategyRaw) ?? .subsegment
    }

    var transcriptionMode: TranscriptionModeSelection {
        TranscriptionModeSelection(rawValue: transcriptionModeRaw) ?? .voiceTriggered
    }

    var diarizationMode: DiarizationMode {
        DiarizationMode(rawValue: diarizationModeRaw) ?? .sequential
    }

    var minNumOfSpeakers: Int? {
        minSpeakerCountRaw == Self.optionalNumericSentinel ? nil : minSpeakerCountRaw
    }

    var minActiveOffset: Float? {
        minActiveOffsetRaw == Self.optionalDoubleSentinel ? nil : Float(minActiveOffsetRaw)
    }

    // MARK: - Language Options
    //
    // The supported-language set and model family are read from the *loaded* model via the SDK
    // (see `ArgmaxSDKCoordinator.loadedModelLanguageInfo`) rather than parsed from the model name.
    // The helpers below map the SDK's language codes to the picker's display names.

    /// Display names for the given SDK language codes, sorted (mapped via `Constants.languages`).
    func languageNames(forCodes codes: [String]) -> [String] {
        let codeSet = Set(codes)
        return Constants.languages.filter { codeSet.contains($0.value) }.map { $0.key }.sorted()
    }

    /// Resolved, sorted display names of the languages a loaded model supports: the family's
    /// explicit name list when it provides one (Qwen), otherwise the names mapped from SDK codes
    /// (Whisper/Parakeet). This is the single source the language picker should read.
    func supportedLanguageNames(for info: LoadedModelLanguageInfo) -> [String] {
        if let names = info.supportedLanguageNames { return names.sorted() }
        return languageNames(forCodes: info.supportedLanguageCodes)
    }

    /// Whether "Detect language" is offered as a selectable/pinned option for a loaded model.
    /// Non-hinting families (e.g. Parakeet) always auto-detect, so it's pinned+selected there;
    /// hinting families (Whisper) offer it only when the model is multilingual (>1 language).
    func offersDetectLanguage(family: TranscriptionModelFamily, supportedNames: [String]) -> Bool {
        family.supportsLanguageHinting ? supportedNames.count > 1 : true
    }

    /// Coerces `selectedLanguage` to a valid value for the loaded model. Non-hinting families
    /// (Parakeet) pin auto-detect, so the selection is forced to the detect sentinel. Hinting
    /// families restore this model's remembered choice if still valid, else keep the current
    /// selection if valid, else fall back to English or the first option.
    func normalizeSelectedLanguage(family: TranscriptionModelFamily, supportedNames: [String]) {
        guard family.supportsLanguageHinting else {
            selectedLanguage = Self.detectLanguageOption
            return
        }
        let options = (supportedNames.count > 1 ? [Self.detectLanguageOption] : []) + supportedNames
        guard !options.isEmpty else { return }
        // Restore the per-model remembered language when it's still supported.
        if let remembered = languageByModel[selectedModel], options.contains(remembered) {
            selectedLanguage = remembered
            return
        }
        guard !options.contains(selectedLanguage) else { return }
        selectedLanguage = options.contains(Defaults.selectedLanguage)
            ? Defaults.selectedLanguage
            : (options.first ?? Defaults.selectedLanguage)
    }

    // MARK: - SDK Option Builders

    func decodingOptions(clipTimestamps: [Float] = []) -> DecodingOptions {
        // The detect sentinel is only offered for models that support it (see `availableLanguages`),
        // so honoring it here is safe; Parakeet auto-detects regardless of the passed language.
        let detectLanguage = selectedLanguage == Self.detectLanguageOption
        // When detecting, leave `language` unset so the SDK infers it from the audio.
        let languageCode: String? = detectLanguage
            ? nil
            : Constants.languages[selectedLanguage, default: Constants.defaultLanguageCode]
        let task: DecodingTask = selectedTask == "transcribe" ? .transcribe : .translate
        return DecodingOptions(
            verbose: true,
            task: task,
            language: languageCode,
            temperature: Float(temperatureStart),
            temperatureFallbackCount: Int(fallbackCount),
            sampleLength: Int(sampleLength),
            usePrefillPrompt: enablePromptPrefill,
            detectLanguage: detectLanguage,
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
            minActiveOffset: minActiveOffset,
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
            let resolvedMode = (SortformerModeSelection(rawValue: sortformerModeRaw) ?? .automatic)
                .config(isRealtimeMode: isRealtimeMode)
            return sortformerDiarizationOptions(sortformerMode: resolvedMode)
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
            minNumOfSpeakers: minNumOfSpeakers,
            enableCustomVocabulary: enableCustomVocabulary,
            customVocabularyWords: customVocabularyWords
        )
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
        temperatureStart != Defaults.temperatureStart ||
        fallbackCount != Defaults.fallbackCount ||
        compressionCheckWindow != Defaults.compressionCheckWindow ||
        sampleLength != Defaults.sampleLength ||
        chunkingStrategy != Defaults.chunkingStrategy ||
        concurrentWorkerCount != Defaults.concurrentWorkerCount ||
        useVAD != Defaults.useVAD ||
        transcriptionModeRaw != Defaults.transcriptionModeRaw ||
        silenceThreshold != Defaults.silenceThreshold ||
        maxSilenceBufferLength != Defaults.maxSilenceBufferLength ||
        minProcessInterval != Defaults.minProcessInterval ||
        transcribeInterval != Defaults.transcribeInterval ||
        saveAudioToFile != Defaults.saveAudioToFile ||
        speakerInfoStrategyRaw != Defaults.speakerInfoStrategyRaw ||
        minSpeakerCountRaw != Defaults.minSpeakerCountRaw ||
        minActiveOffsetRaw != Defaults.minActiveOffsetRaw ||
        useExclusiveReconciliation != Defaults.useExclusiveReconciliation ||
        streamingDiarizationFilterUnknown != Defaults.streamingDiarizationFilterUnknown ||
        sortformerModeRaw != Defaults.sortformerModeRaw ||
        diarizationModeRaw != Defaults.diarizationModeRaw ||
        sortformerMaxWordGap != Defaults.sortformerMaxWordGap ||
        sortformerTolerance != Defaults.sortformerTolerance ||
        qwenSpecDecode != Defaults.qwenSpecDecode ||
        qwenOptimizationRaw != Defaults.qwenOptimizationRaw ||
        dictationSilenceThreshold != Defaults.dictationSilenceThreshold ||
        inverseTextNormalization != Defaults.inverseTextNormalization ||
        groupSpeakerBubbles != Defaults.groupSpeakerBubbles ||
        captureReplayTraces != Defaults.captureReplayTraces
        // `warmWhileClosed` is deliberately absent: it registers a system login item, so it is
        // owned by an explicit user action rather than the settings panel's restore-defaults.
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
        temperatureStart = Defaults.temperatureStart
        fallbackCount = Defaults.fallbackCount
        compressionCheckWindow = Defaults.compressionCheckWindow
        sampleLength = Defaults.sampleLength
        chunkingStrategy = Defaults.chunkingStrategy
        concurrentWorkerCount = Defaults.concurrentWorkerCount
        useVAD = Defaults.useVAD
        transcriptionModeRaw = Defaults.transcriptionModeRaw
        silenceThreshold = Defaults.silenceThreshold
        maxSilenceBufferLength = Defaults.maxSilenceBufferLength
        minProcessInterval = Defaults.minProcessInterval
        transcribeInterval = Defaults.transcribeInterval
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
        qwenSpecDecode = Defaults.qwenSpecDecode
        qwenOptimizationRaw = Defaults.qwenOptimizationRaw
        dictationSilenceThreshold = Defaults.dictationSilenceThreshold
        inverseTextNormalization = Defaults.inverseTextNormalization
        groupSpeakerBubbles = Defaults.groupSpeakerBubbles
        captureReplayTraces = Defaults.captureReplayTraces
        // `warmWhileClosed` intentionally not reset here -- see `hasNonDefaultSettings`.
    }

    // MARK: - Init

    init(store: UserDefaults = .standard) {
        self.store = store
        store.register(defaults: [
            Keys.selectedModel: Defaults.selectedModel,
            Keys.selectedDiarizationModel: Defaults.selectedDiarizationModelRaw,
            Keys.sortformerMode: Defaults.sortformerModeRaw,
            Keys.selectedCustomVocabularyModel: Defaults.selectedCustomVocabularyModelRaw,
            Keys.customVocabularyWords: Defaults.customVocabularyWords,
            Keys.backgroundDownloadWifiOnly: Defaults.backgroundDownloadWifiOnly,
            Keys.encoderComputeUnits: Defaults.encoderComputeUnits.rawValue,
            Keys.decoderComputeUnits: Defaults.decoderComputeUnits.rawValue,
            Keys.segmenterComputeUnits: Defaults.segmenterComputeUnits.rawValue,
            Keys.embedderComputeUnits: Defaults.embedderComputeUnits.rawValue,
            Keys.selectedTask: Defaults.selectedTask,
            Keys.selectedLanguage: Defaults.selectedLanguage,
            Keys.languageByModel: Defaults.languageByModel,
            Keys.enableTimestamps: Defaults.enableTimestamps,
            Keys.enableSpecialCharacters: Defaults.enableSpecialCharacters,
            Keys.enableDecoderPreview: Defaults.enableDecoderPreview,
            Keys.showNerdStats: Defaults.showNerdStats,
            Keys.enablePromptPrefill: Defaults.enablePromptPrefill,
            Keys.temperatureStart: Defaults.temperatureStart,
            Keys.fallbackCount: Defaults.fallbackCount,
            Keys.compressionCheckWindow: Defaults.compressionCheckWindow,
            Keys.sampleLength: Defaults.sampleLength,
            Keys.chunkingStrategy: Defaults.chunkingStrategy.rawValue,
            Keys.concurrentWorkerCount: Defaults.concurrentWorkerCount,
            Keys.useVAD: Defaults.useVAD,
            Keys.transcriptionMode: Defaults.transcriptionModeRaw,
            Keys.silenceThreshold: Defaults.silenceThreshold,
            Keys.maxSilenceBufferLength: Defaults.maxSilenceBufferLength,
            Keys.minProcessInterval: Defaults.minProcessInterval,
            Keys.transcribeInterval: Defaults.transcribeInterval,
            Keys.saveAudioToFile: Defaults.saveAudioToFile,
            Keys.speakerInfoStrategy: Defaults.speakerInfoStrategyRaw,
            Keys.minSpeakerCount: Defaults.minSpeakerCountRaw,
            Keys.minActiveOffset: Defaults.minActiveOffsetRaw,
            Keys.useExclusiveReconciliation: Defaults.useExclusiveReconciliation,
            Keys.streamingDiarizationFilterUnknown: Defaults.streamingDiarizationFilterUnknown,
            Keys.diarizationMode: Defaults.diarizationModeRaw,
            Keys.sortformerMaxWordGap: Defaults.sortformerMaxWordGap,
            Keys.sortformerTolerance: Defaults.sortformerTolerance,
            Keys.qwenSpecDecode: Defaults.qwenSpecDecode,
            Keys.qwenOptimization: Defaults.qwenOptimizationRaw,
            Keys.dictationSilenceThreshold: Defaults.dictationSilenceThreshold,
            Keys.inverseTextNormalization: Defaults.inverseTextNormalization,
            Keys.groupSpeakerBubbles: Defaults.groupSpeakerBubbles,
            Keys.warmWhileClosed: Defaults.warmWhileClosed,
            Keys.captureReplayTraces: Defaults.captureReplayTraces,
        ])

        self.selectedModel = store.string(forKey: Keys.selectedModel) ?? Defaults.selectedModel
        self.selectedDiarizationModelRaw = store.string(forKey: Keys.selectedDiarizationModel) ?? Defaults.selectedDiarizationModelRaw
        self.sortformerModeRaw = store.string(forKey: Keys.sortformerMode) ?? Defaults.sortformerModeRaw
        self.selectedCustomVocabularyModelRaw = store.string(forKey: Keys.selectedCustomVocabularyModel) ?? Defaults.selectedCustomVocabularyModelRaw
        self.customVocabularyWords = store.stringArray(forKey: Keys.customVocabularyWords) ?? Defaults.customVocabularyWords
        self.backgroundDownloadWifiOnly = store.bool(forKey: Keys.backgroundDownloadWifiOnly)

        self.encoderComputeUnits = MLComputeUnits(rawValue: store.integer(forKey: Keys.encoderComputeUnits)) ?? Defaults.encoderComputeUnits
        self.decoderComputeUnits = MLComputeUnits(rawValue: store.integer(forKey: Keys.decoderComputeUnits)) ?? Defaults.decoderComputeUnits
        self.segmenterComputeUnits = MLComputeUnits(rawValue: store.integer(forKey: Keys.segmenterComputeUnits)) ?? Defaults.segmenterComputeUnits
        self.embedderComputeUnits = MLComputeUnits(rawValue: store.integer(forKey: Keys.embedderComputeUnits)) ?? Defaults.embedderComputeUnits

        self.selectedTask = store.string(forKey: Keys.selectedTask) ?? Defaults.selectedTask
        self.selectedLanguage = store.string(forKey: Keys.selectedLanguage) ?? Defaults.selectedLanguage
        self.languageByModel = (store.dictionary(forKey: Keys.languageByModel) as? [String: String]) ?? Defaults.languageByModel
        self.enableTimestamps = store.bool(forKey: Keys.enableTimestamps)
        self.enableSpecialCharacters = store.bool(forKey: Keys.enableSpecialCharacters)
        self.enableDecoderPreview = store.bool(forKey: Keys.enableDecoderPreview)
        self.showNerdStats = store.bool(forKey: Keys.showNerdStats)
        self.enablePromptPrefill = store.bool(forKey: Keys.enablePromptPrefill)
        self.temperatureStart = store.double(forKey: Keys.temperatureStart)
        self.fallbackCount = store.double(forKey: Keys.fallbackCount)
        self.compressionCheckWindow = store.double(forKey: Keys.compressionCheckWindow)
        self.sampleLength = store.double(forKey: Keys.sampleLength)
        self.chunkingStrategy = ChunkingStrategy(rawValue: store.string(forKey: Keys.chunkingStrategy) ?? "") ?? Defaults.chunkingStrategy
        self.concurrentWorkerCount = store.double(forKey: Keys.concurrentWorkerCount)

        self.useVAD = store.bool(forKey: Keys.useVAD)
        self.transcriptionModeRaw = store.string(forKey: Keys.transcriptionMode) ?? Defaults.transcriptionModeRaw
        self.silenceThreshold = store.double(forKey: Keys.silenceThreshold)
        self.maxSilenceBufferLength = store.double(forKey: Keys.maxSilenceBufferLength)
        self.minProcessInterval = store.double(forKey: Keys.minProcessInterval)
        self.transcribeInterval = store.double(forKey: Keys.transcribeInterval)
        self.saveAudioToFile = store.bool(forKey: Keys.saveAudioToFile)

        self.speakerInfoStrategyRaw = store.string(forKey: Keys.speakerInfoStrategy) ?? Defaults.speakerInfoStrategyRaw
        self.minSpeakerCountRaw = store.integer(forKey: Keys.minSpeakerCount)
        self.minActiveOffsetRaw = store.double(forKey: Keys.minActiveOffset)
        self.useExclusiveReconciliation = store.bool(forKey: Keys.useExclusiveReconciliation)
        self.streamingDiarizationFilterUnknown = store.bool(forKey: Keys.streamingDiarizationFilterUnknown)
        self.diarizationModeRaw = store.string(forKey: Keys.diarizationMode) ?? Defaults.diarizationModeRaw
        self.sortformerMaxWordGap = store.double(forKey: Keys.sortformerMaxWordGap)
        self.sortformerTolerance = store.double(forKey: Keys.sortformerTolerance)
        self.qwenSpecDecode = store.bool(forKey: Keys.qwenSpecDecode)
        self.qwenOptimizationRaw = store.string(forKey: Keys.qwenOptimization) ?? Defaults.qwenOptimizationRaw
        self.dictationSilenceThreshold = store.double(forKey: Keys.dictationSilenceThreshold)
        self.inverseTextNormalization = store.bool(forKey: Keys.inverseTextNormalization)
        self.groupSpeakerBubbles = store.bool(forKey: Keys.groupSpeakerBubbles)
        self.warmWhileClosed = store.bool(forKey: Keys.warmWhileClosed)
        self.captureReplayTraces = store.bool(forKey: Keys.captureReplayTraces)
    }
}
