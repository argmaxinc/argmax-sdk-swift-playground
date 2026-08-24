import Argmax
import Foundation
import Network

/// Carries a freshly constructed (uniquely referenced) SDK model out of a detached task.
/// The SDK's async APIs inherit the caller's actor (SE-0461), so heavy loads must run
/// detached; the model types aren't `Sendable`, but handing over the only reference is safe.
private struct ModelHandoff<T>: @unchecked Sendable {
    let model: T
}

/// Model lifecycle for `ArgmaxSDKCoordinator`: download -> verify -> init -> prewarm -> load,
/// with concurrent diarization + custom-vocabulary pipelines, Wi-Fi-only gating, and
/// content-hash verification. The "happy path" through `prepare(...)` is the canonical SDK
/// integration flow this OSS example exists to demonstrate.
///
/// Lives as an extension so it can mutate coordinator-owned state (`whisperKit`,
/// `speakerKit`, `whisperKitModelState`, `pipelineSelection`, `pipelineRows`, etc.). State
/// stays in `ArgmaxSDKCoordinator`; behavior lives here.
extension ArgmaxSDKCoordinator {

    // MARK: - Wi-Fi / cellular gating

    /// `true` when the active network path satisfies a Wi-Fi-only restriction (i.e. there's a
    /// usable Wi-Fi or wired interface). `false` when there's no path or only cellular.
    /// Cellular being present alongside Wi-Fi is fine -- `disabledNetworkTypes: [.cellular]`
    /// keeps the download off cellular regardless.
    ///
    /// Reads the LIVE path from the monitor rather than the cached `activeNetworkInterfaces`
    /// snapshot. The SDK monitor's update handler only fires on path *changes* (no replay on
    /// subscribe), so on a stable Wi-Fi connection the cached snapshot can stay empty from a
    /// launch-time race between the init snapshot and the monitor's first delivery -- which
    /// produced a spurious "Wait for Wi-Fi" prompt even on strong Wi-Fi. `currentPath` is
    /// authoritative once the monitor has been running (always true by the time the user taps
    /// Load), and we refresh the published snapshot here so the Settings badge matches.
    func pathSatisfiesWifiOnly() -> Bool {
        let path = refreshNetworkSnapshot()
        guard path.status == .satisfied else { return false }
        return path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
    }

    /// Re-reads the live path from the SDK monitor and updates the published
    /// `activeNetworkInterfaces` / `isNetworkSatisfied` snapshot. The monitor's update handler
    /// only fires on path *changes* (no replay on subscribe), so views that show network state
    /// (e.g. the Settings "Active network" badge) call this on appear to avoid a stale snapshot.
    @discardableResult
    func refreshNetworkSnapshot() -> NWPath {
        let path = modelStore.backgroundDownloadNetworkMonitor.currentPath
        let candidates: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
        activeNetworkInterfaces = candidates.filter { path.usesInterfaceType($0) }
        isNetworkSatisfied = path.status == .satisfied
        return path
    }

    /// Resolves the `disabledNetworkTypes` to use for a load, given the Wi-Fi-only setting and
    /// an optional one-time cellular override (from the prompt).
    func resolveDisabledNetworkTypes(settings: AppSettings, allowCellularOnce: Bool) -> [NWInterface.InterfaceType]? {
        if allowCellularOnce { return nil }
        return settings.backgroundDownloadWifiOnly ? [.cellular] : nil
    }

    // MARK: - Load entry points

    /// Entry point for the "Load Models" button. Skips the Wi-Fi-only / cellular prompt when
    /// every required model is already verified-on-disk -- there's nothing to download, so the
    /// network gate is irrelevant and the user should be able to load offline (airplane mode,
    /// no signal, etc.). Otherwise applies the usual Wi-Fi-only gate.
    func requestLoadModels(modelName: String, redownload: Bool = false, settings: AppSettings) {
        if !redownload, allRequiredModelsValidatedOnDisk(modelName: modelName, settings: settings) {
            loadModel(modelName, redownload: redownload, settings: settings, allowCellularOnce: false)
            return
        }
        if settings.backgroundDownloadWifiOnly && !pathSatisfiesWifiOnly() {
            pendingCellularDecision = PendingCellularDecision(modelName: modelName, redownload: redownload)
        } else {
            loadModel(modelName, redownload: redownload, settings: settings, allowCellularOnce: false)
        }
    }

    /// `true` when every model the current selection needs is on disk with a passing
    /// `verifyModelSync` (size-based). The content-hash gate runs later in `prepare` for the
    /// stricter check. This precondition lets the load skip the network prompt when no
    /// download is needed.
    private func allRequiredModelsValidatedOnDisk(modelName: String, settings: AppSettings) -> Bool {
        // Transcription is always required.
        // Qwen lives in a dedicated repo that isn't in availableModelRepos() (and therefore
        // doesn't go through the normal WhisperKit transcriptionModelRepo lookup). Without this
        // branch it always returned false for Qwen, surfacing a spurious "Use cellular?" prompt
        // even when the model was fully on disk.
        if TranscriptionModelFamily(modelName: modelName) == .qwen {
            guard modelStore.verifyModelSync(modelVariant: modelName, repoId: AppSettings.qwenModelRepo).outcome == .verified else {
                return false
            }
        } else {
            guard let transcriptionRepo = transcriptionModelRepo(modelName) else { return false }
            guard modelStore.verifyModelSync(modelVariant: modelName, repoId: transcriptionRepo).outcome == .verified else {
                return false
            }
        }
        // Diarization, only when selected.
        if let model = settings.selectedDiarizationModel {
            if model.isSortformer {
                let info = ModelInfo.sortformerDefault()
                let variant = info.variant ?? info.name
                guard modelStore.verifyModelSync(modelVariant: variant, repoId: model.modelRepo).outcome == .verified else {
                    return false
                }
            } else if !isDiarizationModelDownloaded(model) {
                // Pyannote: no cache entry to verify against, fall back to the existing
                // file-layout check.
                return false
            }
        }
        // Custom vocab, only when the user has selected a CTC variant and the family uses it.
        if TranscriptionModelFamily(modelName: modelName).supportsCustomVocabulary,
           let cvModel = settings.selectedCustomVocabularyModel {
            guard modelStore.verifyModelSync(modelVariant: cvModel.variant, repoId: cvModel.modelRepo).outcome == .verified else {
                return false
            }
        }
        return true
    }

    /// Resolves a pending cellular prompt. `useCellular == true` lifts the Wi-Fi-only restriction
    /// for this load only; `false` proceeds with the restriction (downloads park until Wi-Fi).
    func resolveCellularDecision(useCellular: Bool, settings: AppSettings) {
        guard let decision = pendingCellularDecision else { return }
        pendingCellularDecision = nil
        loadModel(decision.modelName, redownload: decision.redownload, settings: settings, allowCellularOnce: useCellular)
    }

    /// Reads compute units / custom vocabulary / diarization model from `AppSettings`, sets up the
    /// download panel, and calls `prepare(...)`. `allowCellularOnce` lifts the Wi-Fi-only restriction
    /// for this one load.
    func loadModel(_ model: String, redownload: Bool = false, settings: AppSettings, allowCellularOnce: Bool = false) {
        if modelLoadInProgress {
            // A load is already running. Spawning another `prepare` would race the first on
            // `self.whisperKit`. Instead, nudge any user-paused rows so their downloads keep
            // moving -- the in-flight load already handles the rest (and `prepare` is the
            // per-role orchestrator on the *next* tap once this load finishes).
            for row in pipelineRows where row.isEnabled {
                if case .paused = row.state { resumeModelDownload(row.role) }
            }
            return
        }
        modelDownloadFailed = false

        // Qwen is a standalone pipeline with its own download/load lifecycle. Route it away from
        // the WhisperKitPro `prepare(...)` flow; diarization and vocabulary companions are applied
        // directly in `loadQwenModel` after the transcriber loads.
        if TranscriptionModelFamily(modelName: model) == .qwen {
            loadQwenModel(model, redownload: redownload, settings: settings, allowCellularOnce: allowCellularOnce)
            return
        }

        let computeUnits = ModelComputeOptions(
            audioEncoderCompute: settings.encoderComputeUnits,
            textDecoderCompute: settings.decoderComputeUnits
        )

        // Custom vocabulary is only meaningful for model families that support the CTC pairing
        // (Parakeet). Whisper and other families silently ignore it in the SDK, but passing a
        // non-nil config still triggers a download of the CTC model. Guard here so that users who
        // have the default "canary" persisted but are loading a Whisper model don't inadvertently
        // kick off a canary download they never asked for.
        let supportsCustomVocab = TranscriptionModelFamily(modelName: model).supportsCustomVocabulary
        let customVocabularyModel = supportsCustomVocab ? settings.selectedCustomVocabularyModel : nil
        let diarizationModel = settings.selectedDiarizationModel
        let disabledNetworkTypes = resolveDisabledNetworkTypes(settings: settings, allowCellularOnce: allowCellularOnce)

        syncPipelineRows(transcriptionModel: model, diarizationModel: diarizationModel, customVocabularyModel: customVocabularyModel)
        modelLoadInProgress = true

        Task {
            do {
                let customVocabularyConfig: CustomVocabularyConfig? = customVocabularyModel != nil ? .init(words: nil) : nil
                let proConfig = WhisperKitProConfig(
                    computeOptions: computeUnits,
                    verbose: true,
                    logLevel: Logging.shared.logLevel,
                    prewarm: true,
                    load: false,
                    useBackgroundDownloadSession: false,
                    customVocabularyConfig: customVocabularyConfig,
                    inverseTextNormalization: settings.inverseTextNormalization
                )
                try await self.prepare(
                    modelName: model,
                    config: proConfig,
                    redownload: redownload,
                    diarizationModel: diarizationModel,
                    disabledNetworkTypes: disabledNetworkTypes
                )
                await self.updateModelList()
                await MainActor.run {
                    self.modelLoadInProgress = false
                    self.modelDownloadFailed = false
                    self.loadedITNEnabled = settings.inverseTextNormalization
                    // Successful load clears any content-mismatch tracking -- the repair worked
                    // (or no mismatch was detected this time around).
                    self.contentMismatchFiles.removeAll()
                    // Re-derive every row from disk + the loaded transcriber and diarizer (rows the load finished
                    // show `.loaded`; rows it didn't touch fall back to `.downloaded`/`.notDownloaded`).
                    self.syncPipelineRows(transcriptionModel: self.pipelineSelection.transcriptionModel,
                                          diarizationModel: self.pipelineSelection.diarizationModel,
                                          customVocabularyModel: self.pipelineSelection.customVocabularyModel)
                }

                // Read current settings after load completes -- user may have edited vocabulary while loading.
                // Only apply the update when the CTC graph is paired with the loaded transcription
                // model (`customVocabularyModelState == .loaded`); the sidebar row reflects pairing
                // status for the user.
                let currentWords = settings.customVocabularyWords
                let currentlyEnabled = settings.selectedCustomVocabularyModel != nil
                let customVocabReady = await MainActor.run { self.whisperKit?.customVocabularyModelState == .loaded }
                if currentlyEnabled && customVocabReady && !currentWords.isEmpty {
                    do {
                        try await MainActor.run {
                            try self.updateCustomVocabulary(words: currentWords)
                        }
                    } catch {
                        Logging.error("[Custom Vocabulary] Failed to apply words: \(error)")
                    }
                }
            } catch {
                Logging.error("Error loading model: \(error)")
                await MainActor.run {
                    self.modelLoadInProgress = false
                    self.modelDownloadFailed = true
                    // Re-derive: rows whose model is on disk go back to `.downloaded`; mark the rest
                    // `.failed` so the panel shows which pipeline didn't make it.
                    self.syncPipelineRows(transcriptionModel: self.pipelineSelection.transcriptionModel,
                                          diarizationModel: self.pipelineSelection.diarizationModel,
                                          customVocabularyModel: self.pipelineSelection.customVocabularyModel)
                    for row in self.pipelineRows where row.isEnabled && row.state == .notDownloaded {
                        self.updatePipelineRow(row.role) { $0.state = .failed("Load failed") }
                    }
                    // Content-mismatch rows would otherwise re-derive to `.downloaded` via the
                    // size-only `verifyModelSync` -- the SHA-256 gate caught them, but
                    // `staticState` doesn't know about that. Override here so the row shows
                    // `.failed` with the Repair affordance instead of falsely claiming
                    // `.downloaded`. `.failed` is sticky in `syncPipelineRows`, so this survives
                    // subsequent re-derives until the user explicitly repairs or deletes.
                    for (role, files) in self.contentMismatchFiles where !files.isEmpty {
                        let label = files.count == 1 ? "Content corrupt · 1 file" : "Content corrupt · \(files.count) files"
                        self.updatePipelineRow(role) { $0.state = .failed(label) }
                    }
                }
            }
        }
    }

    // MARK: - Qwen load path

    /// Loads the Qwen3-ASR transcriber (`WhisperKitPro` with `.qwen3ASR()` config). Unlike `prepare(...)`, Qwen manages its own
    /// model download/load, so this flow handles the transcription side first, then wires up the
    /// selected diarization companion and applies any persisted custom vocabulary words. It drives
    /// the shared pipeline row and `whisperKitModelState`, while leaving `whisperKit` nil -- `qwen`
    /// is the active transcriber.
    func loadQwenModel(_ model: String, redownload: Bool = false, settings: AppSettings, allowCellularOnce: Bool = false) {
        guard apiKey?.isEmpty == false else {
            self.whisperKitModelState = .unloaded
            self.modelDownloadFailed = true
            Logging.error("Cannot load Qwen model: missing API key")
            return
        }

        // Gate before the 1.8 GB download. `validationError()` reports the first unmet
        // requirement, so the row can say which one instead of a flat "Device not supported".
        // The same error is thrown by the load below, so both paths share `rowReason`.
        if let validationError = Qwen3ASRPlatform.validationError() {
            self.whisperKitModelState = .unloaded
            self.modelLoadInProgress = false
            self.modelDownloadFailed = true
            self.updatePipelineRow(.transcription) { $0.state = .failed(validationError.rowReason) }
            Logging.error("[ArgmaxSDKCoordinator] Qwen3-ASR device validation failed: \(validationError.localizedDescription)")
            return
        }

        // Qwen ships in its own HF repo; variant matches the picker id so the background-download
        // sink attributes byte progress to the transcription row.
        let qwenRepo = AppSettings.qwenModelRepo
        let disabledNetworkTypes = resolveDisabledNetworkTypes(settings: settings, allowCellularOnce: allowCellularOnce)

        syncPipelineRows(transcriptionModel: model, diarizationModel: settings.selectedDiarizationModel, customVocabularyModel: nil)
        modelLoadInProgress = true
        speakerKit = nil
        speakerKitModelState = .unloaded
        loadedDiarizationModel = nil
        requestedDiarizationModel = nil
        whisperKitModelState = .downloading

        Task {
            do {
                // 1. Download assets through the shared ModelStore background downloader -- the
                // same path Whisper/Parakeet use: resumable, persisted across launches, byte-level
                // progress in the Models panel, Wi-Fi-only gating, SHA-256 verification. Qwen is
                // then initialized against the downloaded folder (`download: false`) so the SDK's
                // own foreground `WhisperKit.download` fallback never runs.
                let expectedFolder = modelStore.transcriberFolder(repo: qwenRepo)
                    .appendingPathComponent(model, isDirectory: true)
                // Redownload = wipe the variant folder first so the downloader re-fetches
                // everything instead of trusting what is on disk.
                if redownload { try? FileManager.default.removeItem(at: expectedFolder) }
                let result = try await modelStore.downloadModelInBackground(
                    name: model,
                    repo: qwenRepo,
                    token: keyProvider.huggingFaceToken,
                    disabledNetworkTypes: disabledNetworkTypes
                )
                guard let localURL = try await waitForBackgroundDownload(result, expectedFolder: expectedFolder) else {
                    // Parked waiting for Wi-Fi (or user-paused); leave the panel showing its state.
                    self.whisperKitModelState = .unloaded
                    self.modelLoadInProgress = false
                    Logging.debug("[ArgmaxSDKCoordinator] Qwen download parked (waiting for network); load deferred")
                    return
                }

                // 2. Verify before loading (size gate; `.incomplete` is the only hard block, same
                // rationale as the WhisperKitPro transcription gate in `prepare`).
                let verification = modelStore.verifyModelSync(modelVariant: model, repoId: qwenRepo)
                if case .incomplete = verification.outcome {
                    self.whisperKit = nil
                    self.qwen = nil
                    self.whisperKitModelState = .unloaded
                    self.modelLoadInProgress = false
                    self.modelDownloadFailed = true
                    self.updatePipelineRow(.transcription) { $0.state = .failed("Model not usable") }
                    Logging.error("Qwen model not usable: \(verification.summary)")
                    return
                }

                // 3. Load from the downloaded folder.
                self.updatePipelineRow(.transcription) { $0.state = .specializing }
                self.whisperKitModelState = .prewarming
                let config = try WhisperKitProConfig.qwen3ASR(
                    variant: .qwen3ASR_1_7B,
                    // Speculative decoding and optimization are load-time flags; honor the user's
                    // settings so the Stream tab's SpecDec toggle and the Optimization picker take
                    // effect on the next model load.
                    specDecode: settings.qwenSpecDecode,
                    optimization: settings.qwenOptimization,
                    modelToken: keyProvider.huggingFaceToken,
                    modelFolder: localURL.path,
                    download: false,
                    inverseTextNormalization: settings.inverseTextNormalization
                )
                // The SDK is built with NonisolatedNonsendingByDefault (SE-0461), so its async
                // load path runs on the caller's actor. Detach so the synchronous CoreML/ANE
                // specialization inside `QwenASR` doesn't block the main thread ("Specializing"
                // UI freeze).
                let transcriber = try await Task.detached(priority: .userInitiated) {
                    ModelHandoff(model: try await WhisperKitPro(config))
                }.value.model
                self.whisperKit = nil
                self.qwen = transcriber
                self.whisperKitModelState = .loaded
                self.loadedITNEnabled = settings.inverseTextNormalization
                self.updatePipelineRow(.transcription) { $0.state = .loaded; $0.sizeOnDisk = nil }
                self.modelDownloadFailed = false
                self.recomputeSizesIfNeeded()
                Logging.debug("[ArgmaxSDKCoordinator] Qwen3-ASR initialized successfully")
                // Apply any persisted custom vocabulary words to the newly loaded transcriber.
                let vocabWords = settings.customVocabularyWords
                if !vocabWords.isEmpty {
                    do {
                        try transcriber.setCustomVocabulary(vocabWords)
                        self.currentCustomVocabularyWords = vocabWords
                        Logging.debug("[ArgmaxSDKCoordinator] Applied \(vocabWords.count) custom vocabulary word(s) to Qwen")
                    } catch {
                        Logging.error("[ArgmaxSDKCoordinator] Failed to apply custom vocabulary to Qwen: \(error)")
                    }
                }
                // Load the selected diarization companion (Sortformer or Pyannote) if configured.
                // The companion is part of the load: `modelLoadInProgress` holds until it resolves,
                // keeping the global Load button hidden and repeat taps no-ops.
                if let diarizationModel = settings.selectedDiarizationModel {
                    await self.loadDiarizationCompanion(diarizationModel, disabledNetworkTypes: disabledNetworkTypes)
                }
                self.modelLoadInProgress = false
            } catch {
                Logging.error("Error loading Qwen model: \(error)")
                self.whisperKit = nil
                self.qwen = nil
                self.whisperKitModelState = .unloaded
                self.modelLoadInProgress = false
                self.modelDownloadFailed = true
                // Surface the actual reason on the row instead of a generic "Load failed" -- the
                // most common cause is a license that doesn't include Qwen3-ASR, which is not
                // recoverable by retrying the download.
                let reason: String
                switch error {
                case let validationError as Qwen3ASRValidationError:
                    // The SDK gates the device again at load, so this fires when free storage
                    // dropped between the pre-flight check above and the load.
                    reason = validationError.rowReason
                case let argmaxError as ArgmaxError:
                    switch argmaxError {
                    case .invalidLicense: reason = "Not in your SDK license"
                    case .invalidConfiguration: reason = "Device not supported"
                    case .modelUnavailable: reason = "Model unavailable"
                    default: reason = "Load failed"
                    }
                default:
                    reason = "Load failed"
                }
                self.updatePipelineRow(.transcription) { $0.state = .failed(reason) }
            }
        }
    }

    /// Downloads, verifies, and loads the diarization companion (Sortformer or Pyannote) after
    /// the Qwen transcriber finishes initializing. Mirrors the download -> verify -> load lifecycle from
    /// `prepare(...)` without the transcription entanglement. Errors are non-fatal: Qwen stays
    /// active for transcription only and the diarization row is marked failed.
    private func loadDiarizationCompanion(
        _ model: DiarizationModelSelection,
        disabledNetworkTypes: [NWInterface.InterfaceType]?
    ) async {
        speakerKitModelState = .downloading

        do {
            if model.isSortformer {
                let sortformerRepo = DiarizationModelSelection.sortformer.modelRepo
                let sortformerInfo = ModelInfo.sortformerDefault()
                let sortformerVariant = sortformerInfo.variant ?? sortformerInfo.name
                let sortformerFolder = modelStore.transcriberFolder(repo: sortformerRepo)
                let sortformerConfig = SortformerConfig(
                    modelFolder: sortformerFolder.path,
                    download: false,
                    load: false,
                    streamingConfig: .realtime,
                    modelInfo: sortformerInfo
                )
                let manager = SpeakerKitDiarizer.sortformer(config: sortformerConfig)
                setupDiarizationManagerCallback(manager)

                let result = try await modelStore.downloadFilesInBackground(
                    repoId: sortformerRepo,
                    matching: ["*\(sortformerVariant)/*"],
                    destinationRoot: sortformerFolder,
                    variantName: sortformerVariant,
                    token: keyProvider.huggingFaceToken,
                    disabledNetworkTypes: disabledNetworkTypes
                )
                guard try await waitForBackgroundDownload(
                    result, expectedFolder: sortformerInfo.modelURL(baseURL: sortformerFolder)
                ) != nil else {
                    speakerKitModelState = .unloaded
                    Logging.debug("[ArgmaxSDKCoordinator] Sortformer download parked (waiting for network); diarization deferred")
                    return
                }
                let verification = modelStore.verifyModelSync(modelVariant: sortformerVariant, repoId: sortformerRepo)
                if case .incomplete = verification.outcome {
                    throw ArgmaxError.generic("Diarization model not usable: \(verification.summary)")
                }
                if let hashResult = await modelStore.verifyContentHashes(modelVariant: sortformerVariant, repoId: sortformerRepo),
                   hashResult.mismatchedFiles > 0
                {
                    let bad = hashResult.files.filter { $0.outcome == .mismatch }.map { $0.relativePath }
                    contentMismatchFiles[.diarization] = bad
                    throw ArgmaxError.generic("Diarization model content corrupt: \(bad.joined(separator: ", "))")
                }
                try await manager.loadModels()
                sortformerConfig.diarizer = manager
                let speakerKit = try await SpeakerKitPro(sortformerConfig)
                self.speakerKit = speakerKit
                self.speakerKitModelState = .loaded
                self.loadedDiarizationModel = model
                self.currentSortformerMode = .realtime
                Logging.debug("[ArgmaxSDKCoordinator] Sortformer diarization initialized alongside Qwen")
            } else {
                // Pyannote uses its own foreground downloader (no resumable background path).
                let manager = SpeakerKitDiarizer.pyannote()
                setupDiarizationManagerCallback(manager)
                try await manager.downloadModels()
                try await manager.loadModels()
                let pyannoteConfig = PyannoteConfig(
                    modelDownloadConfig: ModelDownloadConfig(modelRepo: DiarizationModelSelection.pyannote4.modelRepo),
                    download: false,
                    load: false,
                    diarizer: manager
                )
                let speakerKit = try await SpeakerKitPro(pyannoteConfig)
                self.speakerKit = speakerKit
                self.speakerKitModelState = .loaded
                self.loadedDiarizationModel = model
                Logging.debug("[ArgmaxSDKCoordinator] Pyannote diarization initialized alongside Qwen")
            }
        } catch {
            Logging.error("[ArgmaxSDKCoordinator] Diarization companion failed: \(error)")
            speakerKit = nil
            speakerKitModelState = .unloaded
            loadedDiarizationModel = nil
            updatePipelineRow(.diarization) { $0.state = .failed("Diarization failed to load") }
        }
    }

    // MARK: - Prepare (the canonical SDK integration flow)

    /// Orchestrates the model lifecycle for a single transcription + optional diarization +
    /// optional custom-vocabulary load.
    ///
    /// Sequence (happy path):
    /// 1. Concurrently start the diarization download (if requested) and the custom-vocabulary
    ///    CTC download (if requested).
    /// 2. Download the transcription model and wait for it.
    /// 3. Verify the transcription model (size-based, then SHA-256 content-hash if a cache
    ///    entry exists).
    /// 4. Finish the custom-vocabulary download, verify, and point `customVocabularyConfig` at
    ///    the local folder.
    /// 5. Initialize `WhisperKitPro` (this prewarms + loads the transcription + CTC models).
    /// 6. Finish the diarization download, load `SpeakerKitPro` if it's selected.
    ///
    /// On a Wi-Fi-only restriction with no satisfying path, the SDK parks the download and
    /// this method returns early; the caller can re-invoke `prepare` (or "Load Models") to
    /// finish loading.
    @MainActor
    public func prepare(modelName: String,
                        repository: String? = nil,
                        config: WhisperKitProConfig,
                        redownload: Bool = false,
                        diarizationModel: DiarizationModelSelection? = nil,
                        disabledNetworkTypes: [NWInterface.InterfaceType]? = nil) async throws {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            self.whisperKitModelState = .unloaded
            self.speakerKitModelState = .unloaded
            throw ArgmaxError.invalidLicense("Missing API Key")
        }
        self.requestedDiarizationModel = diarizationModel
        var diarizationDownloadTask: Task<Void, Error>?
        var customVocabularyDownloadTask: Task<URL?, Error>?

        typealias DiarizationLoader = () async throws -> SpeakerKitPro
        var diarizationLoader: DiarizationLoader?

        let wantsCustomVocabulary = config.customVocabularyConfig != nil

        do {
            if let diarizationModel {
                self.speakerKitModelState = .downloading

                if diarizationModel.isSortformer {
                    let sortformerRepo = DiarizationModelSelection.sortformer.modelRepo
                    let sortformerInfo = ModelInfo.sortformerDefault()
                    let sortformerVariant = sortformerInfo.variant ?? sortformerInfo.name
                    let sortformerFolder = modelStore.transcriberFolder(repo: sortformerRepo)
                    // Download the Sortformer model through the background downloader (resumable,
                    // persisted, byte progress in the panel, gets a verifiable cache entry on
                    // completion) rather than SpeakerKitDiarizer's foreground path. The generic
                    // API mirrors repo paths under `sortformerFolder`, landing files at
                    // `<folder>/sortformer/v2-1/384_94MB/...` -- exactly where SortformerModels.load looks.
                    let sortformerConfig = SortformerConfig(
                        modelFolder: sortformerFolder.path,
                        download: false,
                        load: false,
                        streamingConfig: .realtime,
                        modelInfo: sortformerInfo
                    )
                    let manager = SpeakerKitDiarizer.sortformer(config: sortformerConfig)
                    setupDiarizationManagerCallback(manager)

                    diarizationDownloadTask = Task { [weak self] in
                        guard let self else { return }
                        let result = try await self.modelStore.downloadFilesInBackground(
                            repoId: sortformerRepo,
                            matching: ["*\(sortformerVariant)/*"],
                            destinationRoot: sortformerFolder,
                            variantName: sortformerVariant,
                            token: self.keyProvider.huggingFaceToken,
                            disabledNetworkTypes: disabledNetworkTypes
                        )
                        guard try await self.waitForBackgroundDownload(result, expectedFolder: sortformerInfo.modelURL(baseURL: sortformerFolder)) != nil else {
                            throw ArgmaxError.generic("Diarization download deferred (waiting for network)")
                        }
                        // Verify the downloaded model before loading. Only `.incomplete` is a
                        // hard block -- that's the case where a recorded reference says we
                        // should have N bytes and disk has fewer. `.unknown` (no cache entry,
                        // no live state -- typical for an offline launch on files placed by a
                        // prior SDK build) is "we don't know"; let CoreML try to load and
                        // surface any corruption.
                        let verification = self.modelStore.verifyModelSync(modelVariant: sortformerVariant, repoId: sortformerRepo)
                        if case .incomplete = verification.outcome {
                            throw ArgmaxError.generic("Diarization model not usable: \(verification.summary)")
                        }
                        // Content-hash check (same rationale as the transcription gate).
                        if let hashResult = await self.modelStore.verifyContentHashes(modelVariant: sortformerVariant, repoId: sortformerRepo),
                           hashResult.mismatchedFiles > 0
                        {
                            let bad = hashResult.files.filter { $0.outcome == .mismatch }.map { $0.relativePath }
                            await MainActor.run { self.contentMismatchFiles[.diarization] = bad }
                            throw ArgmaxError.generic("Diarization model content corrupt (\(hashResult.mismatchedFiles) of \(hashResult.totalFiles) files mismatched): \(bad.joined(separator: ", "))")
                        }
                        try await manager.loadModels()
                    }

                    diarizationLoader = {
                        sortformerConfig.diarizer = manager
                        return try await SpeakerKitPro(sortformerConfig)
                    }
                } else {
                    let manager = SpeakerKitDiarizer.pyannote()
                    setupDiarizationManagerCallback(manager)

                    diarizationDownloadTask = Task { try await manager.downloadModels() }

                    diarizationLoader = {
                        try await manager.loadModels()
                        let config = PyannoteConfig(
                            modelDownloadConfig: ModelDownloadConfig(modelRepo: DiarizationModelSelection.pyannote4.modelRepo),
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

            // Kick off the custom-vocabulary CTC model download concurrently with the transcription download.
            if wantsCustomVocabulary {
                let ctcFolder = modelStore.transcriberFolder(repo: customVocabularyRepoId)
                    .appendingPathComponent(customVocabularyVariant, isDirectory: true)
                customVocabularyDownloadTask = Task { [weak self] in
                    guard let self = self else { return nil }
                    let result = try await self.modelStore.downloadModelInBackground(
                        name: customVocabularyVariant,
                        repo: customVocabularyRepoId,
                        token: self.keyProvider.huggingFaceToken,
                        disabledNetworkTypes: disabledNetworkTypes
                    )
                    return try await self.waitForBackgroundDownload(result, expectedFolder: ctcFolder)
                }
            }

            self.whisperKitModelState = .downloading
            let transcriptionResult = try await modelStore.downloadModelInBackground(
                name: modelName,
                repo: selectedRepository,
                token: keyProvider.huggingFaceToken,
                disabledNetworkTypes: disabledNetworkTypes
            )
            guard let localURL = try await waitForBackgroundDownload(transcriptionResult, expectedFolder: modelStore.transcriberFolder(repo: selectedRepository).appendingPathComponent(modelName, isDirectory: true)) else {
                // Parked waiting for Wi-Fi (or user-paused). The download keeps running / will
                // auto-resume; leave the panel showing its state and bail out of the load.
                diarizationDownloadTask?.cancel()
                customVocabularyDownloadTask?.cancel()
                self.whisperKitModelState = .unloaded
                self.speakerKitModelState = .unloaded
                Logging.debug("[ArgmaxSDKCoordinator] Transcription download parked (waiting for network); load deferred")
                return
            }

            // Verify the transcription model before initializing. Only `.incomplete` (cache
            // entry says we should have N bytes and disk has fewer) is a hard block; `.unknown`
            // (no cache entry -- typical for an offline launch with files placed by a prior SDK
            // build) lets CoreML attempt the load and surface real corruption.
            let transcriptionVerification = modelStore.verifyModelSync(modelVariant: modelName, repoId: selectedRepository)
            if case .incomplete = transcriptionVerification.outcome {
                self.whisperKitModelState = .unloaded
                self.speakerKitModelState = .unloaded
                diarizationDownloadTask?.cancel()
                customVocabularyDownloadTask?.cancel()
                throw ArgmaxError.modelUnavailable("Transcription model not usable: \(transcriptionVerification.summary)")
            }
            // Content-hash check catches size-correct-but-content-corrupt files that pass the
            // size verifier but blow up later inside CoreML's MIL compile (`Invalid sentinel
            // in blob_metadata`). Every comparison is logged via `[TRACE-HASH]`. Runs only
            // when we have a cache entry to compare against -- skipped on cold upgrade paths.
            if let hashResult = await modelStore.verifyContentHashes(modelVariant: modelName, repoId: selectedRepository),
               hashResult.mismatchedFiles > 0
            {
                let bad = hashResult.files.filter { $0.outcome == .mismatch }.map { $0.relativePath }
                self.contentMismatchFiles[.transcription] = bad
                self.whisperKitModelState = .unloaded
                self.speakerKitModelState = .unloaded
                diarizationDownloadTask?.cancel()
                customVocabularyDownloadTask?.cancel()
                throw ArgmaxError.modelUnavailable("Transcription model content corrupt (\(hashResult.mismatchedFiles) of \(hashResult.totalFiles) files mismatched): \(bad.joined(separator: ", "))")
            }

            // If custom vocab is enabled, finish its download before initializing WhisperKitPro,
            // and point the config at the downloaded folder so WhisperKitPro skips its own download.
            if wantsCustomVocabulary {
                if let ctcFolder = try await customVocabularyDownloadTask?.value {
                    let ctcVerification = modelStore.verifyModelSync(modelVariant: customVocabularyVariant, repoId: customVocabularyRepoId)
                    if case .incomplete = ctcVerification.outcome {
                        self.whisperKitModelState = .unloaded
                        self.speakerKitModelState = .unloaded
                        diarizationDownloadTask?.cancel()
                        throw ArgmaxError.modelUnavailable("Custom vocabulary model not usable: \(ctcVerification.summary)")
                    }
                    if let hashResult = await modelStore.verifyContentHashes(modelVariant: customVocabularyVariant, repoId: customVocabularyRepoId),
                       hashResult.mismatchedFiles > 0
                    {
                        let bad = hashResult.files.filter { $0.outcome == .mismatch }.map { $0.relativePath }
                        self.contentMismatchFiles[.customVocabulary] = bad
                        self.whisperKitModelState = .unloaded
                        self.speakerKitModelState = .unloaded
                        diarizationDownloadTask?.cancel()
                        throw ArgmaxError.modelUnavailable("Custom vocabulary model content corrupt (\(hashResult.mismatchedFiles) of \(hashResult.totalFiles) files mismatched): \(bad.joined(separator: ", "))")
                    }
                    config.customVocabularyConfig = CustomVocabularyConfig(words: nil, modelFolder: ctcFolder.path)
                } else {
                    // Parked; can't proceed with custom vocab loaded -- defer the whole load.
                    diarizationDownloadTask?.cancel()
                    self.whisperKitModelState = .unloaded
                    self.speakerKitModelState = .unloaded
                    Logging.debug("[ArgmaxSDKCoordinator] Custom-vocab download parked (waiting for network); load deferred")
                    return
                }
            }

            self.whisperKitModelState = .prewarming
            if wantsCustomVocabulary {
                // The custom-vocab CTC model is specialized/loaded inside `WhisperKitPro.loadModels`
                // (before the transcription model), but the SDK doesn't expose a per-pipeline
                // callback we can hook into. Setting `.specializing` here makes the row visibly
                // track the prewarm+load window instead of jumping from `.downloaded` -> `.loaded`.
                updatePipelineRow(.customVocabulary) { $0.state = .specializing }
            }
            let whisperKitPro = try await initializeWhisperKitPro(config: config, modelFolder: localURL, modelName: modelName)
            self.whisperKit = whisperKitPro
            if wantsCustomVocabulary {
                let cvState = whisperKitPro.customVocabularyModelState
                Logging.info("[Custom Vocabulary] Loaded -- variant=\(customVocabularyVariant), modelState=\(cvState.map { String(describing: $0) } ?? "nil")")
                if cvState == .loaded {
                    updatePipelineRow(.customVocabulary) { $0.state = .loaded; $0.sizeOnDisk = nil }
                } else {
                    // Custom vocabulary pairs with Parakeet transcription models; when paired
                    // with another family the CTC graph stays unloaded. Reflect that on the
                    // sidebar row and let `allPipelinesLoaded` ignore this row so the user can
                    // tap "Unload Models" to swap models.
                    updatePipelineRow(.customVocabulary) {
                        $0.state = .failed("Requires a Parakeet model")
                        $0.sizeOnDisk = nil
                    }
                }
                recomputeSizesIfNeeded()
            }

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
                    updatePipelineRow(.diarization) { $0.state = .failed("Diarization model failed to load") }
                }
            } else {
                self.speakerKit = nil
                self.speakerKitModelState = .unloaded
                self.loadedDiarizationModel = nil
            }

        } catch {
            diarizationDownloadTask?.cancel()
            customVocabularyDownloadTask?.cancel()
            self.whisperKitModelState = .unloaded
            self.speakerKitModelState = .unloaded
            self.whisperKit = nil
            self.speakerKit = nil
            self.loadedDiarizationModel = nil
            Logging.error("Failed to prepare models: \(error)")
            throw error
        }
    }

    // MARK: - Reset / unload

    public func reset() async {
        modelStore.cancelDownload()
        await whisperKit?.unloadModels()
        await speakerKit?.unloadModels()
        await MainActor.run {
            whisperKit = nil
            speakerKit = nil
            // `WhisperKitPro` (Qwen config) exposes no explicit unload; releasing the reference frees it.
            qwen = nil
            whisperKitModelState = .unloaded
            speakerKitModelState = .unloaded
            loadedDiarizationModel = nil
            requestedDiarizationModel = nil
            loadedITNEnabled = nil
            modelLoadInProgress = false
            pendingCellularDecision = nil
            // Keep the panel rows but re-derive them: the models are on disk, not loaded.
            syncPipelineRows(transcriptionModel: pipelineSelection.transcriptionModel,
                             diarizationModel: pipelineSelection.diarizationModel,
                             customVocabularyModel: pipelineSelection.customVocabularyModel)
        }
    }

    /// Unloads the current speaker kit (either Pyannote or Sortformer).
    @MainActor
    public func unloadSpeakerKit() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
        speakerKitModelState = .unloaded
        loadedDiarizationModel = nil
    }

    // MARK: - Custom vocabulary words

    /// Pushes a new custom-vocabulary list into the loaded `WhisperKitPro` instance. Builds the
    /// context graph immediately. Per the SDK guidance: multi-word phrases tokenize as separate
    /// items inside the spotter, and entries containing `<unk>` tokens are excluded by the
    /// SDK's keyword tokenizer.
    @MainActor
    public func updateCustomVocabulary(words: [String]) throws {
        if let qwen {
            let preview = words.prefix(5).joined(separator: ", ") + (words.count > 5 ? ", ..." : "")
            Logging.info("[Custom Vocabulary] Applying \(words.count) word(s) to Qwen: \(preview)")
            // Record only once the transcriber accepts them, as the WhisperKit branch below
            // does. Assigning up front left the UI claiming a vocabulary that failed to apply.
            try qwen.setCustomVocabulary(words)
            currentCustomVocabularyWords = words
            return
        }
        guard let whisperKit else {
            throw ArgmaxError.modelUnavailable("WhisperKit model is not loaded")
        }
        let preview = words.prefix(5).joined(separator: ", ") + (words.count > 5 ? ", ..." : "")
        Logging.info("[Custom Vocabulary] Applying \(words.count) word(s): \(preview)")

        do {
            try whisperKit.setCustomVocabulary(words)
            currentCustomVocabularyWords = words
        } catch {
            Logging.error("Failed to update custom vocabulary: \(error)")
            throw error
        }
    }

    // MARK: - Sortformer streaming mode

    /// Updates the Sortformer streaming mode configuration.
    /// Only affects new streaming sessions -- active sessions keep their original configuration.
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

    // MARK: - WhisperKitPro init & SDK callbacks

    /// Walks the configured repository list to find which repo holds `modelName`. Falls back to
    /// a substring match on `parakeet` until the SDK exposes a public `RepoType.repo(forVariant:)`
    /// lookup. Internal so other extensions (e.g. the debug harness) can call it.
    func findRepositoryForModel(_ modelName: String) async -> String {
        let targets = targetRepositories
        if let foundRepo = modelStore.findRepository(containing: modelName, in: targets) {
            return foundRepo
        }
        // Substring match on "parakeet" is a stopgap until the SDK exposes a public
        // `RepoType.repo(forVariant:)` lookup. Removable once that ships.
        if modelName.lowercased().contains("parakeet") {
            return RepoType.parakeetRepo.repoId
        } else {
            return RepoType.proRepo.repoId
        }
    }

    /// The repositories the coordinator searches when resolving a transcription variant.
    /// Internal so `updateModelList` on the main coordinator file can read it.
    var targetRepositories: [RepoType] {
        [.parakeetRepo, .proRepo]
    }

    /// Creates a consistent model state callback for WhisperKit, mapping SDK-internal states to
    /// the playground's display states. Two non-obvious mappings:
    /// - `.prewarmed` -> `.loading` (the model is specialized but still being read into memory).
    /// - `.downloaded` -> `.prewarming` (during the transcriber init the SDK emits `.downloaded`
    ///   before kicking off the prewarm; treat it as the start of "specializing" for UX).
    private func createWhisperKitModelStateCallback() -> ModelStateCallback {
        return { [weak self] _, newState in
            Task { @MainActor in
                let displayState: ModelState
                switch newState {
                case .prewarmed: displayState = .loading
                case .downloaded: displayState = .prewarming
                case .unloading: displayState = .unloaded
                case .unloaded, .loading, .loaded, .prewarming, .downloading: displayState = newState
                }
                self?.whisperKitModelState = displayState
            }
        }
    }

    private func setupWhisperKitModelStateCallback(for transcriber: WhisperKitPro) {
        transcriber.modelStateCallback = createWhisperKitModelStateCallback()
    }

    /// Prewarms (if configured) then loads the WhisperKitPro models. Both phases dispatch
    /// through `WhisperKitPro.loadModels(prewarmMode:)` -- prewarm specializes the Core ML
    /// models for the device, the second pass loads them into memory for use.
    private func prepareWhisperKitModels(for whisperKit: WhisperKit, config: WhisperKitProConfig) async throws {
        let shouldPrewarm = config.prewarm ?? false
        // Detached so the Core ML specialization/load runs off the main actor -- the SDK's
        // nonisolated async methods inherit the caller's actor (SE-0461) and would otherwise
        // freeze the UI for the whole prewarm+load window.
        try await Task.detached(priority: .userInitiated) {
            if shouldPrewarm {
                try await whisperKit.prewarmModels()
            }
            try await whisperKit.loadModels()
        }.value
    }

    /// Constructs the `WhisperKitPro` instance with `load: false` so we can prewarm + load
    /// explicitly under our `prepareWhisperKitModels` orchestration, hook the model-state
    /// callback before any load begins, and surface state transitions in the UI as they happen.
    private func initializeWhisperKitPro(config: WhisperKitProConfig, modelFolder: URL, modelName: String) async throws -> WhisperKitPro {
        config.modelFolder = modelFolder.path
        config.load = false
        let whisperKitPro = try await Task.detached(priority: .userInitiated) {
            ModelHandoff(model: try await WhisperKitPro(config))
        }.value.model
        setupWhisperKitModelStateCallback(for: whisperKitPro)
        try await prepareWhisperKitModels(for: whisperKitPro, config: config)
        return whisperKitPro
    }

    private func setupDiarizationManagerCallback(_ manager: SpeakerKitDiarizer) {
        manager.modelStateCallback = { [weak self] _, newState in
            Task { @MainActor in
                // Propagate every state, including `.loaded`. Without this the row would sit in
                // `.specializing` (the diarizer's "loading" maps there for visual consistency)
                // until `prepare`'s `diarizationLoader()` runs and explicitly sets `.loaded` --
                // which never happens if a sibling pipeline (e.g. transcription) is still
                // downloading or fails, leaving diarization stuck.
                self?.speakerKitModelState = newState
            }
        }
    }

    // MARK: - Diagnostics

    /// Logs a snapshot of on-disk model state, the SDK download cache, and the panel rows.
    /// Useful for debugging "why does the panel say X" / "why won't the model load". Tagged
    /// `[ModelDiag]` so it's easy to filter in Console.app. Debug builds only: the recursive
    /// size walks over model folders are too expensive for output Release would filter anyway.
    public func logModelDiagnostics(_ reason: String) {
        #if DEBUG
        let fileManager = FileManager.default
        func describeFolder(_ url: URL, label: String, maxDepth: Int = 3) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                Logging.debug("[ModelDiag] \(label): (does not exist) \(url.path)")
                return
            }
            guard isDirectory.boolValue else {
                let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
                Logging.debug("[ModelDiag] \(label): (file, \(size) bytes) \(url.path)")
                return
            }
            let total = Self.directorySize(at: url) ?? -1
            Logging.debug("[ModelDiag] \(label): \(url.path)  [total \(total) bytes]")
            func walk(_ dir: URL, depth: Int, indent: String) {
                guard depth <= maxDepth, let children = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return }
                for child in children {
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if values?.isDirectory == true {
                        let subtotal = Self.directorySize(at: child) ?? -1
                        Logging.debug("[ModelDiag]   \(indent)\(child.lastPathComponent)/  [\(subtotal) bytes]")
                        walk(child, depth: depth + 1, indent: indent + "  ")
                    } else {
                        Logging.debug("[ModelDiag]   \(indent)\(child.lastPathComponent)  (\(values?.fileSize ?? 0) bytes)")
                    }
                }
            }
            walk(url, depth: 1, indent: "")
        }

        Logging.debug("[ModelDiag] ===== model diagnostics (\(reason)) =====")
        describeFolder(modelStore.baseModelFolder(), label: "baseModelFolder")

        let diarizationRepos = DiarizationModelSelection.allCases.map { $0.modelRepo }
        for repo in diarizationRepos + [customVocabularyRepoId] {
            describeFolder(modelStore.transcriberFolder(repo: repo), label: "repo \(repo)")
        }
            let sortformerPath = ModelInfo.sortformerDefault().modelURL(
                baseURL: modelStore.transcriberFolder(repo: DiarizationModelSelection.sortformer.modelRepo)
            )
            describeFolder(sortformerPath, label: "ModelInfo.sortformerDefault().modelURL")

        let cacheEntries = modelStore.downloadCacheEntries()
        Logging.debug("[ModelDiag] downloadCacheEntries: \(cacheEntries.count)")
        for entry in cacheEntries {
            Logging.debug("[ModelDiag]   cache: variant=\(entry.modelVariant) repo=\(entry.repoId) files=\(entry.files.count) totalBytes=\(entry.totalBytes) at=\(entry.destinationFolder.path) completedAt=\(entry.completedAt)")
        }
        let downloadStates = modelStore.activeBackgroundDownloads
        Logging.debug("[ModelDiag] backgroundDownloader records: \(downloadStates.count)")
        for state in downloadStates {
            Logging.debug("[ModelDiag]   dl: id=\(state.downloadId) variant=\(state.modelVariant) repo=\(state.repoId) status=\(state.status) progress=\(state.overallProgress) files=\(state.files.count) at=\(state.destinationFolder.path)")
        }

        Logging.debug("[ModelDiag] pipelineRows: \(pipelineRows.count)")
        for row in pipelineRows {
            Logging.debug("[ModelDiag]   row: role=\(row.role.rawValue) state=\(row.state) model=\(row.modelName) size=\(row.sizeOnDisk.map(String.init) ?? "nil") folder=\(row.folderURL?.path ?? "nil") downloadId=\(row.downloadId ?? "nil")")
        }
        if let model = pipelineSelection.diarizationModel {
            Logging.debug("[ModelDiag] isDiarizationModelDownloaded(\(model.rawValue)) = \(isDiarizationModelDownloaded(model))")
        }
        Logging.debug("[ModelDiag] ===== end model diagnostics =====")
        #endif
    }
}

// MARK: - Qwen3-ASR validation wording

extension Qwen3ASRValidationError {
    /// Short label for the pipeline row, which has room for a few words. Use
    /// `localizedDescription` (the SDK's own sentence) wherever the full explanation fits.
    ///
    /// `@unknown default` is required, not optional: the SDK ships as a resilient library, so
    /// its public enums are non-frozen and Swift 6 rejects exhaustive switches over them. A
    /// case added in a later SDK release lands in the fallback (generic label) until this
    /// wording extension catches up.
    var rowReason: String {
        switch self {
        case .unsupportedPlatform: "Device not supported"
        case .insufficientMemory: "Not enough memory"
        case .insufficientDiskSpace: "Not enough free storage"
        @unknown default: "Cannot run on this device"
        }
    }

    /// Whether the user can do something about it. Only storage can be freed -- chip, OS, and
    /// installed memory are fixed properties of the device. Unknown future reasons default to
    /// not recoverable rather than promising the user a fix that may not exist.
    var isRecoverable: Bool {
        switch self {
        case .insufficientDiskSpace: true
        case .unsupportedPlatform, .insufficientMemory: false
        @unknown default: false
        }
    }
}

