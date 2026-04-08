import Argmax
import CoreML
import Foundation
import Combine
import SwiftUI

/// A central `ObservableObject` that manages all Argmax SDK components including model loading,
/// transcription, and speaker diarization.
///
/// `ArgmaxSDKCoordinator` acts as the main integration point for apps using WhisperKit, SpeakerKit,
/// LiveTranscriber, and ModelStore. It simplifies the orchestration of the Argmax transcription pipeline
/// and provides a unified interface for SwiftUI applications to observe and control model workflows.
///
/// ## Core Responsibilities
///
/// - **Model Management:** Coordinates loading, downloading, and updating transcription models using `ModelStore`
/// - **Component Lifecycle:** Instantiates and wires up `WhisperKitPro`, `SpeakerKitPro`, and `LiveTranscriber` with correct configuration and state tracking
/// - **API Key Handling:** Retrieves and validates obfuscated API keys required to access Argmax services
/// - **State Propagation:** Uses `@Published` properties to notify SwiftUI views about model loading state and service availability
///
/// ## Key Methods
///
/// - ``setupArgmax()``: Sets up the Argmax SDK with proper configuration and error handling
/// - ``prepare(modelName:repository:config:redownload:)``: Downloads and initializes models for WhisperKit and SpeakerKit
/// - ``updateModelList()``: Refreshes available models from configured repositories
/// - ``reset()``: Unloads all models and resets the coordinator state
///
/// ## Related SDK Objects
///
/// - **WhisperKit:** Core transcription engine that consumes raw audio and outputs segmented, timestamped text (used as `WhisperKitPro` for advanced streaming support)
/// - **SpeakerKit:** Diarization engine that distinguishes speakers in audio, loaded alongside WhisperKit when needed for multi-speaker transcripts
/// - **LiveTranscriber:** High-level component that wraps WhisperKit for real-time streaming transcription, automatically initialized when `whisperKit` is set
/// - **ModelStore:** Manages available model metadata, repositories, and downloads throughout the coordinator lifecycle
final class ArgmaxSDKCoordinator: ObservableObject {
    // MARK: - Published Properties
    @Published public private(set) var whisperKitModelState: ModelState = .unloaded
    @Published public private(set) var speakerKitModelState: ModelState = .unloaded
    @Published public var modelDownloadFailed: Bool = false
    @Published public var availableModelNames: [String] = []
    
    /// Tracks which diarization model is currently loaded (nil if none)
    @Published public private(set) var loadedDiarizationModel: DiarizationModelSelection?
    /// Tracks which diarization model was requested during the last prepare() call
    @Published public private(set) var requestedDiarizationModel: DiarizationModelSelection?

    // MARK: - Derived State

    var isWhisperKitLoading: Bool {
        whisperKitModelState != .loaded && whisperKitModelState != .unloaded
    }

    var isSpeakerKitLoading: Bool {
        speakerKitModelState != .loaded && speakerKitModelState != .unloaded
    }

    var isSortformerLoaded: Bool {
        loadedDiarizationModel == .sortformer && speakerKitModelState == .loaded
    }

    var isModelConfigurationLocked: Bool {
        whisperKitModelState != .unloaded
    }

    var areModelsReady: Bool {
        guard whisperKitModelState == .loaded else { return false }
        guard let requested = requestedDiarizationModel else { return true }
        return speakerKitModelState == .loaded && loadedDiarizationModel == requested
    }

    var isLoading: Bool {
        if isWhisperKitLoading { return true }
        guard requestedDiarizationModel != nil else { return false }
        if isSpeakerKitLoading { return true }
        if whisperKitModelState == .loaded &&
           speakerKitModelState == .unloaded &&
           loadedDiarizationModel != requestedDiarizationModel {
            return true
        }
        return false
    }

    // MARK: - Argmax API objects
    public private(set) var whisperKit: WhisperKitPro? {
        didSet {
            if let wk = whisperKit {
                liveTranscriber = LiveTranscriber(whisperKit: wk)
            } else {
                liveTranscriber = nil
            }
        }
    }
    
    /// The active diarization engine (either Pyannote or Sortformer)
    public private(set) var speakerKit: SpeakerKitPro?
    
    public private(set) var liveTranscriber: LiveTranscriber?
    public let modelStore: ModelStore
    private let keyProvider: APIKeyProvider
    
    // MARK: - properties
    private var apiKey: String? = nil
    private var cancellables = Set<AnyCancellable>()
    
    
    public init(
        whisperKitConfig: WhisperKitProConfig = WhisperKitProConfig(),
        keyProvider: APIKeyProvider
    ) {
        self.keyProvider = keyProvider
        self.modelStore = ModelStore(whisperKitConfig: whisperKitConfig)
        
        // Manually chain the objectWillChange publisher from the modelStore
        // to this coordinator. This ensures that any @Published property(.localModels and .availableModels) change
        // in modelStore will also trigger an update for any view observing this coordinator.
        // Otherwise directly use ModelStore as a @StateObject in your SwiftUI
        modelStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
    }
    
    /// Sets up the Argmax SDK with proper configuration and error handling
    public func setupArgmax() {
        if let apiKey = apiKey, !apiKey.isEmpty {
            return
        }
        Task {
            do {
                guard let apiKey = keyProvider.apiKey, !apiKey.isEmpty else {
                    await MainActor.run {
                        self.whisperKitModelState = .unloaded
                        self.speakerKitModelState = .unloaded
                    }
                    throw ArgmaxError.invalidLicense("Missing API Key")
                }
                
                self.apiKey = apiKey
                await ArgmaxSDK.with(ArgmaxConfig(apiKey: apiKey))
                Logging.debug("Setting up ArgmaxSDK")
                Logging.debug(await ArgmaxSDK.licenseInfo())
            } catch {
                await MainActor.run {
                    modelDownloadFailed = true
                }
                Logging.error("Failed to set up ArgmaxSDK: \(error)")
            }
        }
    }

    // MARK: - Model Management
    
    /// Updates the list of available models from configured repositories
    public func updateModelList() async {
        await modelStore.updateAvailableModels(from: targetRepositories, keyProvider: keyProvider)
        
        await MainActor.run {
            availableModelNames = modelStore.availableModels.flatMap(\.models).map(\.description)
        }

    }

    /// Downloads the CoreML bundle (if needed) and instantiates both WhisperKit and SpeakerKit.
    /// Call this once per model you want to use; subsequent calls replace the services.
    /// Pass `nil` for `diarizationModel` to load transcription-only (no SpeakerKit).
    ///
    /// Downloads for transcription and diarization models run concurrently.
    /// Diarization model loading waits until WhisperKit is fully loaded to avoid GPU/Metal contention.
    @MainActor
    public func prepare(modelName: String,
                        repository: String? = nil,
                        config: WhisperKitProConfig,
                        redownload: Bool = false,
                        diarizationModel: DiarizationModelSelection? = nil) async throws {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            self.whisperKitModelState = .unloaded
            self.speakerKitModelState = .unloaded
            throw ArgmaxError.invalidLicense("Missing API Key")
        }
        self.requestedDiarizationModel = diarizationModel
        var diarizationDownloadTask: Task<Void, Error>?

        typealias DiarizationLoader = () async throws -> SpeakerKitPro
        var diarizationLoader: DiarizationLoader?

        do {
            if let diarizationModel {
                self.speakerKitModelState = .downloading

                if diarizationModel.isSortformer {
                    if #available(macOS 15, iOS 18, *) {
                        let sortformerConfig = SortformerConfig(
                            modelRepo: "argmaxinc/speakerkit-pro",
                            streamingConfig: .realtime
                        )
                        let manager = SpeakerKitDiarizer.sortformer(config: sortformerConfig)
                        setupDiarizationManagerCallback(manager)

                        diarizationDownloadTask = Task {
                            try await manager.downloadModels()
                            try await manager.loadModels()
                        }

                        diarizationLoader = {
                            sortformerConfig.diarizer = manager
                            sortformerConfig.download = false
                            return try await SpeakerKitPro(sortformerConfig)
                        }
                    } else {
                        throw ArgmaxError.invalidConfiguration("Sortformer requires macOS 15 or iOS 18")
                    }
                } else {
                    let manager = SpeakerKitDiarizer.pyannote()
                    setupDiarizationManagerCallback(manager)

                    diarizationDownloadTask = Task { try await manager.downloadModels() }

                    diarizationLoader = {
                        try await manager.loadModels()
                        let config = PyannoteConfig(
                            modelDownloadConfig: ModelDownloadConfig(modelRepo: "argmaxinc/speakerkit-coreml"),
                            download: false,
                            load: false,
                            diarizer: manager
                        )
                        return try await SpeakerKitPro(config)
                    }
                }
            }

            let selectedRepository: String
            if let repository {
                selectedRepository = repository
            } else {
                selectedRepository = await findRepositoryForModel(modelName)
            }
            
            let needsDownload = redownload || !modelStore.modelExists(variant: modelName, from: selectedRepository)

            if needsDownload {
                self.whisperKitModelState = .downloading
            }

            let localURL = try await modelStore.downloadModel(
                name: modelName,
                repo: selectedRepository,
                token: keyProvider.huggingFaceToken,
                redownload: redownload
            )
            self.whisperKitModelState = .prewarming

            let whisperKitPro = try await initializeWhisperKitPro(config: config, modelFolder: localURL, modelName: modelName)
            self.whisperKit = whisperKitPro
            
            if let diarizationModel {
                do {
                    try await diarizationDownloadTask?.value
                    if let loader = diarizationLoader {
                        self.speakerKitModelState = .loading
                        let speakerKit = try await loader()
                        self.speakerKit = speakerKit
                        self.speakerKitModelState = .loaded
                        self.loadedDiarizationModel = diarizationModel
                        if diarizationModel.isSortformer {
                            self.currentSortformerMode = .realtime
                        }
                        Logging.debug("[ArgmaxSDKCoordinator] \(diarizationModel.displayName) diarization initialized successfully")
                    }
                } catch {
                    Logging.error("[ArgmaxSDKCoordinator] Diarization model failed, continuing transcription-only: \(error)")
                    self.speakerKit = nil
                    self.speakerKitModelState = .unloaded
                    self.loadedDiarizationModel = nil
                }
            } else {
                self.speakerKit = nil
                self.speakerKitModelState = .unloaded
                self.loadedDiarizationModel = nil
            }
            
        } catch {
            diarizationDownloadTask?.cancel()
            self.whisperKitModelState = .unloaded
            self.speakerKitModelState = .unloaded
            self.whisperKit = nil
            self.speakerKit = nil
            self.loadedDiarizationModel = nil
            Logging.debug("Failed to prepare models:", error)
            throw error
        }
    }
    
    /// High-level entry point that reads compute units, custom vocabulary,
    /// and diarization model from `AppSettings`, then calls `prepare(...)`.
    func loadModel(_ model: String, redownload: Bool = false, settings: AppSettings) {
        modelDownloadFailed = false

        let computeUnits = ModelComputeOptions(
            audioEncoderCompute: settings.encoderComputeUnits,
            textDecoderCompute: settings.decoderComputeUnits
        )

        let supportsCustomVocabulary = model.lowercased().contains("parakeet")
        let shouldEnableCustomVocabulary = supportsCustomVocabulary && settings.enableCustomVocabulary

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
                    customVocabularyConfig: customVocabularyConfig
                )
                try await self.prepare(
                    modelName: model,
                    config: proConfig,
                    redownload: redownload,
                    diarizationModel: settings.selectedDiarizationModel
                )
                await self.updateModelList()
                await MainActor.run {
                    self.modelDownloadFailed = false
                }

                // Read current settings after load completes — user may have edited vocabulary while loading.
                let currentWords = settings.customVocabularyWords
                let currentlyEnabled = supportsCustomVocabulary && settings.enableCustomVocabulary
                if currentlyEnabled && !currentWords.isEmpty {
                    do {
                        try await MainActor.run {
                            try self.updateCustomVocabulary(words: currentWords)
                        }
                    } catch {
                        Logging.error("Failed to update custom vocabulary: \(error)")
                    }
                }
            } catch {
                Logging.error("Error loading model: \(error)")
                await MainActor.run {
                    self.modelDownloadFailed = true
                }
            }
        }
    }

    @Published public var currentCustomVocabularyWords: [String] = []

    @MainActor
    public func updateCustomVocabulary(words: [String]) throws {
        guard let whisperKit else {
            throw ArgmaxError.modelUnavailable("WhisperKit model is not loaded")
        }

        do {
            try whisperKit.setCustomVocabulary(words)
            currentCustomVocabularyWords = words
        } catch {
            Logging.error("Failed to update custom vocabulary: \(error)")
            throw error
        }
    }

    public func delete(modelName: String,
                       repository: String? = nil,
                       config: WhisperKitConfig? = nil) async throws {
        do {
            let selectedRepository: String
            if let repository {
                selectedRepository = repository
            } else {
                selectedRepository = await findRepositoryForModel(modelName)
            }
            try await modelStore.deleteModel(variant: modelName, from: selectedRepository)
        } catch {
            throw ArgmaxError.generic("Failed to delete model")
        }
    }
    
    public func deleteCustomVocabularyModels() async throws {
        for model in ["canary-1b-v2", "parakeet-tdt_ctc-110m"] {
            try await modelStore.deleteModel(variant: model, from: "argmaxinc/ctckit-pro")
        }
    }

    public func reset() async {
        modelStore.cancelDownload()
        await whisperKit?.unloadModels()
        await speakerKit?.unloadModels()
        await MainActor.run {
            whisperKit = nil
            speakerKit = nil
            whisperKitModelState = .unloaded
            speakerKitModelState = .unloaded
            loadedDiarizationModel = nil
            requestedDiarizationModel = nil
        }
    }
    
    /// The currently configured Sortformer streaming mode.
    /// This is tracked by the coordinator and passed to sessions when they are created.
    @MainActor
    public var currentSortformerMode: SortformerModeSelection = .realtime

    /// Updates the Sortformer streaming mode configuration.
    /// Only affects new streaming sessions — active sessions keep their original configuration.
    /// - Parameter mode: The new Sortformer mode to use
    /// - Throws: Error if Sortformer is not loaded
    @MainActor
    public func configureSortformerMode(_ mode: SortformerModeSelection) throws {
        guard loadedDiarizationModel == .sortformer else {
            throw ArgmaxError.invalidConfiguration("Sortformer mode can only be configured when Sortformer is loaded")
        }
        currentSortformerMode = mode
        Logging.debug("[ArgmaxSDKCoordinator] Configured Sortformer mode to: \(mode.rawValue)")
    }
    
    /// Checks if a diarization model is downloaded locally using the canonical ModelInfo paths
    public func isDiarizationModelDownloaded(_ model: DiarizationModelSelection) -> Bool {
        let baseFolder = modelStore.transcriberFolder(repo: model.modelRepo)
        
        if model.isSortformer {
            if #available(macOS 15, iOS 18, *) {
                let modelInfo = ModelInfo.sortformerDefault()
                let modelPath = modelInfo.modelURL(baseURL: baseFolder)
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: modelPath.path) {
                    return contents.contains(where: { $0.contains("MelSpectrogram") || $0.contains("AudioConformer") || $0.contains("Sortformer") })
                }
            }
            return false
        } else {
            let segmenterInfo = ModelInfo.segmenter()
            let embedderInfo = ModelInfo.embedder()
            let segmenterPath = segmenterInfo.modelURL(baseURL: baseFolder)
            let embedderPath = embedderInfo.modelURL(baseURL: baseFolder)
            let hasBaseModels = FileManager.default.fileExists(atPath: segmenterPath.path) &&
                                FileManager.default.fileExists(atPath: embedderPath.path)
            // Pyannote v4 additionally requires PLDA model
            if model == .pyannote4 {
                let pldaInfo = ModelInfo.plda()
                let pldaPath = pldaInfo.modelURL(baseURL: baseFolder)
                return hasBaseModels && FileManager.default.fileExists(atPath: pldaPath.path)
            }
            
            return hasBaseModels
        }
    }
    
    /// Unloads the current speaker kit (either Pyannote or Sortformer)
    @MainActor
    public func unloadSpeakerKit() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
        speakerKitModelState = .unloaded
        loadedDiarizationModel = nil
    }
    
    // MARK: - Private Helper Methods

    private var targetRepositories: [RepoType] {
        if #available(macOS 15, iOS 18, watchOS 11, visionOS 2, *) {
            return [.parakeetRepo, .proRepo]
        } else {
            return [.parakeetRepo, .openSourceRepo]
        }
    }

    /// Finds the appropriate repository for a given model name
    private func findRepositoryForModel(_ modelName: String) async -> String {
        let targetRepositories = self.targetRepositories
        if let foundRepo = modelStore.findRepository(containing: modelName, in: targetRepositories) {
            return foundRepo
        }
        // TODO: use built-in method for parakeet
        if modelName.lowercased().contains("parakeet") {
            return RepoType.parakeetRepo.repoId
        } else {
            if #available(macOS 15, iOS 18, watchOS 11, visionOS 2, *) {
                return RepoType.proRepo.repoId
            } else {
                return RepoType.openSourceRepo.repoId
            }
        }
    }

    /// Creates a consistent model state callback for WhisperKit, mapping internal states to display states
    private func createWhisperKitModelStateCallback() -> ModelStateCallback {
        return { [weak self] oldState, newState in
            Task { @MainActor in
                let displayState: ModelState
                switch newState {
                case .prewarmed: displayState = .loading        // "Specialized" -> still loading into memory
                case .downloaded: displayState = .prewarming    // "Downloaded" -> "Specializing" (during transcriber init)
                case .unloading: displayState = .unloaded       // "Unloading" -> treat as unloaded for UI
                case .unloaded, .loading, .loaded, .prewarming, .downloading: displayState = newState
                }
                self?.whisperKitModelState = displayState
            }
        }
    }
    
    /// Sets up the model state callback for WhisperKitPro transcriber
    private func setupWhisperKitModelStateCallback(for transcriber: WhisperKitPro) {
        transcriber.modelStateCallback = createWhisperKitModelStateCallback()
    }
    
    /// Loads or prewarms models based on configuration
    private func prepareWhisperKitModels(for whisperKit: WhisperKit, config: WhisperKitProConfig) async throws {
        let shouldPrewarm = config.prewarm ?? false
        if shouldPrewarm {
            try await whisperKit.prewarmModels()
        }
        try await whisperKit.loadModels()
    }

    /// Initializes and loads a WhisperKitPro transcriber
    private func initializeWhisperKitPro(config: WhisperKitProConfig, modelFolder: URL, modelName: String) async throws -> WhisperKitPro {

        config.modelFolder = modelFolder.path
        config.load = false
        let whisperKitPro = try await WhisperKitPro(config)
        // Set up model state callback and initial state
        setupWhisperKitModelStateCallback(for: whisperKitPro)
        // Load or prewarms models
        try await prepareWhisperKitModels(for: whisperKitPro, config: config)
        return whisperKitPro
    }

    private func setupDiarizationManagerCallback(_ manager: SpeakerKitDiarizer) {
        manager.modelStateCallback = { [weak self] oldState, newState in
            Task { @MainActor in
                if newState != .loaded {
                    self?.speakerKitModelState = newState
                }
            }
        }
    }

}

// MARK: - Sortformer Configuration Types

/// Selection for Sortformer streaming mode
enum SortformerModeSelection: String, Sendable {
    case automatic = "automatic"
    case realtime = "real-time"
    case prerecorded = "pre-recorded"

    /// Resolves the effective SDK config. `automatic` is resolved by the caller based on context.
    @available(macOS 15, iOS 18, *)
    public func config(isRealtimeMode: Bool) -> SortformerStreamingConfig {
        switch self {
        case .automatic:
            return isRealtimeMode ? .realtime : .prerecorded
        case .realtime: return .realtime
        case .prerecorded: return .prerecorded
        }
    }

    /// Human-readable label with "(auto)" suffix when the mode is automatically resolved.
    public func displayLabel(isStream: Bool) -> String {
        switch self {
        case .automatic: return isStream ? "Real-time (auto)" : "Pre-recorded (auto)"
        case .realtime: return "Real-time"
        case .prerecorded: return "Pre-recorded"
        }
    }
}

/// Selection for diarization model type
enum DiarizationModelSelection: String, CaseIterable, Sendable {
    case pyannote4 = "pyannote4"
    case sortformer = "sortformer"

    public var displayName: String {
        switch self {
        case .pyannote4: return "Pyannote v4"
        case .sortformer: return "Sortformer"
        }
    }

    public var isSortformer: Bool {
        self == .sortformer
    }

    public var isPyannote: Bool {
        self == .pyannote4
    }

    /// The HuggingFace repository for this model
    public var modelRepo: String {
        switch self {
        case .pyannote4: return "argmaxinc/speakerkit-coreml"
        case .sortformer: return "argmaxinc/speakerkit-pro"
        }
    }
}
