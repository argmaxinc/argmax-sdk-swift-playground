import Argmax
import CoreML
import Foundation
import Combine
import Network
import SwiftUI
import UserNotifications

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
/// - **WhisperKit:** Core transcriber that consumes raw audio and outputs segmented, timestamped text (used as `WhisperKitPro` for advanced streaming support)
/// - **SpeakerKit:** Diarizer that distinguishes speakers in audio, loaded alongside WhisperKit when needed for multi-speaker transcripts
/// - **LiveTranscriber:** High-level component that wraps WhisperKit for real-time streaming transcription, automatically initialized when `whisperKit` is set
/// - **ModelStore:** Manages available model metadata, repositories, and downloads throughout the coordinator lifecycle
/// Marked `@MainActor` so every member (and the extensions in `ModelLoader.swift`,
/// `PipelineRowManager.swift`, `BackgroundDownloadTestHarness.swift`) is main-actor isolated by
/// default. Genuine background work (filesystem walks, hash verification, model loading)
/// dispatches via explicit `Task.detached { ... }.value` or actor-isolated SDK helpers; the
/// previous mix of `Task { @MainActor in ... }`, `DispatchQueue.main.async`, and
/// `await MainActor.run` is collapsed where the compiler now enforces the threading model.
@MainActor
final class ArgmaxSDKCoordinator: ObservableObject {
    // MARK: - Published Properties
    /// Internal setter so the `ModelLoader` extension can drive state transitions during a load.
    /// External callers still see it as read-only.
    @Published public internal(set) var whisperKitModelState: ModelState = .unloaded {
        didSet { syncModelState(.transcription, whisperKitModelState) }
    }
    @Published public internal(set) var speakerKitModelState: ModelState = .unloaded {
        didSet { syncModelState(.diarization, speakerKitModelState) }
    }
    @Published public var modelDownloadFailed: Bool = false
    @Published public var availableModelNames: [String] = []

    /// Per-role list of files that failed SHA-256 verification in the most recent prepare attempt.
    /// Drives the "Repair" affordance on `.failed` rows -- distinct from "Retry", which wipes
    /// the whole model. Cleared on successful repair or explicit delete.
    @Published public internal(set) var contentMismatchFiles: [DownloadRole: [String]] = [:]

    /// Tracks which diarization model is currently loaded (nil if none)
    @Published public internal(set) var loadedDiarizationModel: DiarizationModelSelection?
    /// Tracks which diarization model was requested during the last prepare() call
    @Published public internal(set) var requestedDiarizationModel: DiarizationModelSelection?

    /// Whether the currently loaded transcription model was initialized with Inverse Text Normalization
    /// enabled. Nil when no model is loaded. Used to detect setting/loaded-state mismatches.
    @Published public internal(set) var loadedITNEnabled: Bool? = nil

    // MARK: - Per-pipeline status tracking

    /// One row per model pipeline the current configuration uses (transcription always; diarization
    /// when a diarization model is selected; custom vocabulary when enabled). Drives the sidebar
    /// "Models" panel. Rebuilt by `syncPipelineRows(...)` whenever the selection changes and updated
    /// in place by the active-download sink and the `ModelState` callbacks during a load.
    @Published public internal(set) var pipelineRows: [ModelPipelineRow] = []

    /// `true` between the "Load Models" tap and the load finishing (or parking on Wi-Fi).
    @Published var modelLoadInProgress = false

    /// The model selection the panel rows were last built for. Lets the coordinator re-derive the
    /// rows after a load/delete without the caller having to re-pass `AppSettings`.
    var pipelineSelection: (transcriptionModel: String, diarizationModel: DiarizationModelSelection?, customVocabularyModel: CustomVocabularyModelSelection?) = ("", nil, nil)

    /// Set when the user taps "Load Models" while Wi-Fi-only is on and the active path is
    /// cellular-only (or otherwise unsatisfied). The UI presents a "wait vs use cellular" prompt;
    /// resolving it (or cancelling) clears this back to `nil`.
    @Published public var pendingCellularDecision: PendingCellularDecision?

    /// Late-binding handle for `PlaygroundAppDelegate` to reach the coordinator during a
    /// background URL-session relaunch. Assigned by the `Playground` App owner during
    /// initialization -- not as a side effect of this type's `init`. The OS may wake the app
    /// in the background before any SwiftUI scene runs, and `@UIApplicationDelegateAdaptor`
    /// constructs the delegate via a no-arg init, so we can't inject through the constructor;
    /// this single, documented escape hatch is the trade-off.
    public static weak var shared: ArgmaxSDKCoordinator?

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

    /// Language support of the currently loaded transcription model, or `nil` when none is loaded.
    /// Read from SDK types on the loaded model (Parakeet tokenizer subclass -> `ParakeetVariant`;
    /// otherwise Whisper via `modelVariant.isMultilingual`) rather than parsed from the model name,
    /// so the language picker reflects what the model actually supports.
    var loadedModelLanguageInfo: LoadedModelLanguageInfo? {
        guard whisperKitModelState == .loaded else { return nil }
        // Qwen runs as its own transcriber (no `whisperKit`); when it's loaded, report the Qwen family.
        // Qwen3-ASR is multilingual and supports language hinting. Its supported set only partially
        // overlaps Whisper's code map, so expose the names explicitly rather than via codes.
        if qwen != nil {
            return LoadedModelLanguageInfo(
                family: .qwen,
                supportedLanguageCodes: [],
                supportedLanguageNames: AppSettings.qwenSupportedLanguageNames
            )
        }
        guard let whisperKit else { return nil }
        // All Parakeet tokenizers subclass `Parakeetv2Tokenizer`; JA and V3 are further subclasses.
        if let tokenizer = whisperKit.tokenizer, tokenizer is Parakeetv2Tokenizer {
            let variant: ParakeetVariant = tokenizer is ParakeetJATokenizer ? .ja
                : tokenizer is Parakeetv3Tokenizer ? .v3
                : .v2
            return LoadedModelLanguageInfo(family: .parakeet, supportedLanguageCodes: variant.supportedLanguageCodes)
        }
        let codes = whisperKit.modelVariant.isMultilingual ? Array(Constants.languageCodes) : ["en"]
        return LoadedModelLanguageInfo(family: .whisper, supportedLanguageCodes: codes)
    }

    var areModelsReady: Bool {
        guard whisperKitModelState == .loaded else { return false }
        guard let requested = requestedDiarizationModel else { return true }
        return speakerKitModelState == .loaded && loadedDiarizationModel == requested
    }

    /// `true` only when every enabled pipeline row is `.loaded` -- drives the "Unload Models" button.
    /// Disabled rows (e.g. diarization = None) don't participate. A custom-vocabulary row in
    /// `.failed` state counts as resolved too: it represents a config incompatibility (transcription
    /// model isn't Parakeet) that the user can only fix by unloading and picking a different model,
    /// so we need "Unload Models" to remain reachable.
    var allPipelinesLoaded: Bool {
        let enabled = pipelineRows.filter { $0.isEnabled }
        guard !enabled.isEmpty else { return false }
        return enabled.allSatisfy { row in
            if row.state == .loaded { return true }
            if row.role == .customVocabulary, case .failed = row.state { return true }
            return false
        }
    }

    /// `true` if any enabled row needs the user to act (resume, retry, download, load) -- shows the
    /// global "Load Models" button. In-flight and `.loaded` rows are never actionable. While a load
    /// runs, `.notDownloaded`/`.downloaded` rows are queued work, not user work (the Qwen flow
    /// loads its diarization companion sequentially); `.paused` stays actionable because the button
    /// tap resumes it. A custom-vocabulary `.failed` only recovers via model reselection.
    var hasActionableRow: Bool {
        pipelineRows.contains { row in
            guard row.isEnabled else { return false }
            switch row.state {
            case .paused, .incomplete, .unverified: return true
            case .notDownloaded, .downloaded: return !modelLoadInProgress
            case .failed: return row.role != .customVocabulary
            case .downloading, .specializing, .loading, .waitingForWifi, .loaded, .verifying: return false
            }
        }
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
    public internal(set) var whisperKit: WhisperKitPro? {
        didSet {
            if let wk = whisperKit {
                liveTranscriber = LiveTranscriber(whisperKit: wk)
            } else {
                liveTranscriber = nil
            }
        }
    }
    
    /// The active diarizer (either Pyannote or Sortformer)
    public internal(set) var speakerKit: SpeakerKitPro?
    
    public private(set) var liveTranscriber: LiveTranscriber?

    /// The Qwen3-ASR transcriber, loaded *instead of* ``whisperKit`` when the user selects a Qwen
    /// model. Created with `WhisperKitPro(.qwen3ASR(...))`. Only one of ``whisperKit`` / ``qwen``
    /// is ever non-nil at a time.
    public internal(set) var qwen: WhisperKitPro?
    /// `ModelStore` is the SDK's download/cache surface. Kept internal (not public) to keep
    /// view code consuming the coordinator's published state where possible; the few external
    /// reads that remain (AppDelegate's background URL session forwarding, the model-list
    /// picker in `SidebarView`) are intentional escape hatches for now.
    let modelStore: ModelStore
    let keyProvider: APIKeyProvider
    
    // MARK: - properties
    /// Internal so `ModelLoader.prepare` can validate before kicking off a download. Not exposed
    /// publicly -- no consumer needs to read the credential after `setupArgmax()` succeeds.
    var apiKey: String? = nil
    private var cancellables = Set<AnyCancellable>()
    
    
    public init(
        whisperKitConfig: WhisperKitProConfig = WhisperKitProConfig(),
        keyProvider: APIKeyProvider,
        logLevel: Logging.LogLevel? = nil
    ) {
        // Default to `.info` in Release and `.debug` in Debug. Host apps that need verbose
        // SDK output can pass an explicit `logLevel`; production builds stay quiet.
        let resolvedLogLevel: Logging.LogLevel = {
            if let logLevel { return logLevel }
            #if DEBUG
            return .debug
            #else
            return .info
            #endif
        }()
        Logging.shared.logLevel = resolvedLogLevel

        self.keyProvider = keyProvider
        self.modelStore = ModelStore(whisperKitConfig: whisperKitConfig)

        // `Self.shared` is no longer assigned here as a side effect of init -- the `Playground`
        // App owner sets it explicitly after constructing the coordinator. Keeping the
        // late-binding handle out of `init` removes the "side effect in init" anti-pattern from
        // the example code while preserving the AppDelegate-reach-back capability that
        // background URL-session relaunches require.

        // Manually chain the objectWillChange publisher from the modelStore
        // to this coordinator. This ensures that any @Published property(.localModels and .availableModels) change
        // in modelStore will also trigger an update for any view observing this coordinator.
        // Otherwise directly use ModelStore as a @StateObject in your SwiftUI
        modelStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Snapshot the active path immediately so the UI doesn't sit at "Active: --" until
        // the first NWPathMonitor event fires (the monitor only emits on changes).
        let monitor = modelStore.backgroundDownloadNetworkMonitor
        let initialPath = monitor.currentPath
        self.activeNetworkInterfaces = monitor.activeInterfaceTypes
        self.isNetworkSatisfied = initialPath.status == .satisfied

        // Subscribe via the SDK's existing monitor -- no second NWPathMonitor needed.
        // The callback fires on a background queue; hop to the main actor to mutate
        // `@Published` state.
        networkPathHandlerId = monitor.addPathUpdateHandler { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let candidates: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
                self.activeNetworkInterfaces = candidates.filter { path.usesInterfaceType($0) }
                self.isNetworkSatisfied = path.status == .satisfied
            }
        }

        // Drive the per-model download panel from the SDK's active-downloads list.
        modelStore.backgroundDownloadsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] states in self?.applyActiveDownloads(states) }
            .store(in: &cancellables)

        // Reconstruct download-panel items for any download still in progress from a prior run
        // (e.g. the app was quit mid-download). The SDK auto-resumes `.downloading` and
        // `.pausedByNetwork` ones itself; `.paused` (user-paused) ones surface with a Resume button.
        reconstructPipelineRowsFromPersistedState()
    }

    deinit {
        if let id = networkPathHandlerId {
            modelStore.backgroundDownloadNetworkMonitor.removePathUpdateHandler(id)
        }
    }
    
    /// Sets up the Argmax SDK with proper configuration and error handling. Idempotent -- a
    /// subsequent call returns immediately if the key has already been wired in. Runs detached:
    /// this is called from `onAppear` before the first frame, and the SDK setup (keychain
    /// reads, license validation, telemetry) must not contend with the launch render on the
    /// main actor. Only the coordinator state writes hop back.
    public func setupArgmax() {
        if let apiKey, !apiKey.isEmpty { return }
        let keyProvider = keyProvider
        Task.detached(priority: .userInitiated) {
            guard let apiKey = keyProvider.apiKey, !apiKey.isEmpty else {
                await MainActor.run { [weak self] in
                    self?.whisperKitModelState = .unloaded
                    self?.speakerKitModelState = .unloaded
                    self?.modelDownloadFailed = true
                }
                Logging.error("Failed to set up ArgmaxSDK: \(ArgmaxError.invalidLicense("Missing API Key"))")
                return
            }
            await MainActor.run { [weak self] in self?.apiKey = apiKey }
            await ArgmaxSDK.with(ArgmaxConfig(apiKey: apiKey))
            Logging.debug("Setting up ArgmaxSDK")
            Logging.debug(await ArgmaxSDK.licenseInfo())
        }
    }

    /// Re-authenticates the SDK license with a different `ax_` API key, replacing this device's
    /// current license with one created from the key's account. The key itself is used for this
    /// process only and never persisted by the app; the license tokens the SDK creates with it
    /// are stored in the keychain by the SDK and stay active across launches (where the bundled
    /// key takes over again) until they expire or another re-authentication replaces them.
    ///
    /// The caller must have validated the `ax_` prefix -- `ArgmaxConfig.init` traps on other
    /// prefixes.
    public func reauthenticate(apiKey newKey: String) async -> LicenseInfo {
        // Order matters. `reset(includingLicense: true)` clears the keychain license tokens but
        // is a no-op once the SDK is closed -- and it must run, because `with()` short-circuits
        // on still-valid keychain tokens and would never exercise the new key. `close()` then
        // drops `enabled` so `with()` performs a full setup instead of returning early.
        await ArgmaxSDK.reset(includingLicense: true)
        await ArgmaxSDK.close()
        apiKey = newKey
        await ArgmaxSDK.with(ArgmaxConfig(apiKey: newKey))
        let info = await ArgmaxSDK.licenseInfo()
        Logging.debug("Re-authenticated ArgmaxSDK with user-provided key")
        Logging.debug(info)
        return info
    }

    // MARK: - Model Management
    
    /// Updates the list of available models from configured repositories.
    public func updateModelList() async {
        await modelStore.updateAvailableModels(from: targetRepositories, keyProvider: keyProvider)
        var names = modelStore.availableModels.flatMap(\.models).map(\.description)
        // Qwen3-ASR isn't a WhisperKit-store model, so inject it manually on platforms that can
        // run it (8 GB-and-up iOS 18 devices / Apple Silicon macOS 15). Availability at load time
        // is validated by the SDK, which throws `ArgmaxError.invalidConfiguration`.
        if !names.contains(AppSettings.qwenModelName) {
            names.append(AppSettings.qwenModelName)
        }
        availableModelNames = names
    }


    @Published public var currentCustomVocabularyWords: [String] = []

    /// The currently configured Sortformer streaming mode.
    /// This is tracked by the coordinator and passed to sessions when they are created.
    @MainActor
    public var currentSortformerMode: SortformerModeSelection = .realtime

    /// Checks if a diarization model is downloaded locally using the canonical ModelInfo paths
    /// Whether the given CTC custom-vocabulary variant has files on disk in `argmaxinc/ctckit-pro`.
    /// Drives the "✓" checkmark in the custom-vocabulary picker; same idea as
    /// `isDiarizationModelDownloaded(_:)`.
    /// Whether a transcription model has files on disk. Drives the "✓" in the model picker.
    /// Qwen lives in its own HF repo that `localModels` doesn't scan, so it gets a direct
    /// folder check.
    public func isTranscriptionModelDownloaded(_ model: String) -> Bool {
        if TranscriptionModelFamily(modelName: model) == .qwen {
            let folder = modelStore.transcriberFolder(repo: AppSettings.qwenModelRepo)
                .appendingPathComponent(model, isDirectory: true)
            let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            return !(contents ?? []).isEmpty
        }
        return modelStore.localModels.flatMap { $0.models }.contains { $0.description == model }
    }

    public func isCustomVocabularyModelDownloaded(_ model: CustomVocabularyModelSelection) -> Bool {
        let folder = modelStore.transcriberFolder(repo: model.modelRepo)
            .appendingPathComponent(model.variant, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return false
        }
        return !contents.isEmpty
    }

    public func isDiarizationModelDownloaded(_ model: DiarizationModelSelection) -> Bool {
        let baseFolder = modelStore.transcriberFolder(repo: model.modelRepo)
        
        if model.isSortformer {
            let modelInfo = ModelInfo.sortformerDefault()
            let modelPath = modelInfo.modelURL(baseURL: baseFolder)
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: modelPath.path) {
                return contents.contains(where: { $0.contains("MelSpectrogram") || $0.contains("AudioConformer") || $0.contains("Sortformer") })
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


    // MARK: - Per-model download panel (shared helpers)

    /// CTC repo + variant for the currently selected custom-vocabulary model. The variant is
    /// chosen by the user via the picker; the repo is the same for both options. Falls back to
    /// the canary variant when no selection is active -- purely a string fallback so file-path
    /// callers don't crash when custom vocab is off (those callers gate on `isEnabled` first).
    var customVocabularyVariant: String {
        (pipelineSelection.customVocabularyModel ?? .canary).variant
    }
    var customVocabularyRepoId: String {
        (pipelineSelection.customVocabularyModel ?? .canary).modelRepo
    }

    // MARK: - Background Download Test (developer tools state)

    /// Stored state for the background download test harness behind Settings > Developer.
    /// Methods live in `Services/DevTools/BackgroundDownloadTestHarness.swift`; only state
    /// remains here because Swift extensions can't have stored properties.
    @Published public var backgroundDownloadTestActive: Bool = false
    @Published public var backgroundDownloadTestStatus: String = ""
    /// Determinate progress of the active download (0...1). Driven by `BackgroundDownloader.overallProgress`.
    @Published public var backgroundDownloadProgress: Double = 0

    var backgroundDownloadCancellable: AnyCancellable?
    /// `@Published` so SwiftUI re-renders affordances that depend on whether we have a
    /// download to act on (e.g. enabling/disabling the Verify button).
    @Published var currentBackgroundDownloadId: String?

    /// Public, read-only mirror of `currentBackgroundDownloadId != nil` for SwiftUI bindings.
    public var hasCurrentBackgroundDownloadId: Bool { currentBackgroundDownloadId != nil }
    var notifiedMilestones: Set<String> = []
    /// Tracks last-emitted status per download so we only log status transitions.
    var lastLoggedStatus: [String: BackgroundDownloadStatus] = [:]

    /// Whether there's a paused download that can be resumed
    @Published public var hasPausedDownload: Bool = false
    /// The model name of the paused download (if any)
    @Published public var pausedDownloadModel: String?

    /// Persisted log of background download events. Survives app relaunches via UserDefaults so
    /// the user can review what happened while the app was in the background.
    @Published public var backgroundEvents: [BackgroundEvent] = BackgroundEvent.load()

    /// Interface types the active network path is currently using. Updated from the SDK's
    /// `NetworkMonitor` via `addPathUpdateHandler` so the UI can show "Active: Wi-Fi" /
    /// "Cellular" without standing up a parallel `NWPathMonitor`.
    @Published public var activeNetworkInterfaces: [NWInterface.InterfaceType] = []
    /// `true` while the system reports any satisfied path. Drives the connection indicator.
    @Published public var isNetworkSatisfied: Bool = false
    private var networkPathHandlerId: NetworkMonitor.PathUpdateHandlerId?

}

