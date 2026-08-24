import Argmax
import Combine
import Foundation
import Network

/// Pipeline-row state machine for `ArgmaxSDKCoordinator`. Drives the sidebar "Models" panel:
/// builds rows from the current selection, derives per-row lifecycle state from disk + active
/// background downloads + loaded transcriber and diarizer, and forwards user-initiated row actions
/// (delete / retry / repair / pause / resume / cancel) back to the SDK.
///
/// **Why it's an extension** rather than a free-standing manager: every method here needs
/// access to coordinator-owned state (`pipelineSelection`, `pipelineRows`, `whisperKit`,
/// `speakerKit`, `modelStore`, model-state callbacks). Swift extensions can't hold stored
/// properties; the state lives on `ArgmaxSDKCoordinator` and the behavior lives here so the
/// main coordinator file reads as the SDK integration flow, not as a 2,000-line state machine.
extension ArgmaxSDKCoordinator {

    // MARK: - Descriptor helpers

    func pipelineName(for role: DownloadRole) -> String {
        switch role {
        case .transcription: return "Transcription"
        case .diarization: return "Diarization"
        case .customVocabulary: return "Custom Vocabulary"
        }
    }

    func iconName(for role: DownloadRole) -> String {
        switch role {
        case .transcription: return "waveform"
        case .diarization: return "person.2.wave.2"
        case .customVocabulary: return "character.book.closed"
        }
    }

    /// Returns true when a variant has a recognised pretty name and should appear in the picker.
    /// Anything not matched here -- distil-whisper, large-v2, bare unquantised large-v3, extra
    /// quantisation tiers, etc. -- is silently excluded. This is an allowlist: new variants must
    /// be explicitly added to surface in the UI.
    func isRecognizedTranscriptionModel(_ name: String) -> Bool {
        if name == AppSettings.qwenModelName { return true }
        if name.contains("parakeet") {
            // The parakeet-pro repo config lists both a sizeless and a sized id for v2 and v3
            // (aggregated across per-device support blocks), and the picker label strips the org
            // prefix + size suffix -- so each family collapses to a single identical
            // "Parakeet vN" row. Pin those families to their one canonical sized variant so the
            // picker shows each once; other parakeet families (ja) are unaffected.
            if name.contains("parakeet-v2") { return name == "nvidia_parakeet-v2_476MB" }
            if name.contains("parakeet-v3") { return name == "nvidia_parakeet-v3_494MB" }
            return true
        }
        if name.contains("whisper-tiny") || name.contains("whisper-base") { return true }
        if name.contains("whisper-small") {
            return name.contains("_216MB") || name.contains("_217MB")
        }
        // Large v3 Turbo: accept only the specific 626 MB variant.
        if name.contains("large-v3") { return name.contains("_626MB") }
        return false
    }

    /// Human-readable label used in the transcription model picker dropdown.
    /// The raw variant id (e.g. "parakeet-v3_494MB") is shown separately in the small gray
    /// state line beneath the picker -- this function is NOT used for that.
    func pickerTranscriptionModelName(_ variant: String) -> String {
        if variant == AppSettings.qwenModelName { return "Qwen3-ASR 1.7B" }
        // Whisper Large v3 Turbo: the date+size suffix makes the generic rules unreliable.
        if variant.contains("large-v3") { return "Whisper Large v3 Turbo" }

        // Strip org prefix when the first "_"-delimited token is an org id (starts with a
        // letter) rather than a size suffix (starts with a digit). e.g. "openai_whisper-tiny".
        var base = variant
        if let idx = base.firstIndex(of: "_") {
            let after = String(base[base.index(after: idx)...])
            if after.first?.isNumber == false { base = after }
        }
        // Strip trailing size suffix "_NNNmb" if still present.
        if let idx = base.lastIndex(of: "_"), base[base.index(after: idx)...].first?.isNumber == true {
            base = String(base[..<idx])
        }
        // ".en" suffix -> "(English-only)" qualifier.
        let isEnOnly = base.hasSuffix(".en")
        if isEnOnly { base = String(base.dropLast(3)) }

        // Title-case each dash-separated token; keep version tags (v2, v3, …) lowercase.
        let words = base.split(separator: "-").map { token -> String in
            let s = String(token)
            if s.hasPrefix("v"), s.dropFirst().first?.isNumber == true { return s }
            return s.prefix(1).uppercased() + s.dropFirst()
        }.joined(separator: " ")

        return isEnOnly ? "\(words) (English-only)" : words
    }

    /// Replaces the underscore that HuggingFace variant ids put before the size suffix
    /// (e.g. `parakeet-v2_476MB`, `canary-1b-v2_474MB`) with a space. Used for diarization
    /// (Sortformer) and custom-vocabulary rows, which don't have a leading repo prefix to
    /// drop the way transcription variants do.
    func prettyVariantName(_ variant: String) -> String {
        variant.replacingOccurrences(of: "_", with: " ")
    }

    func modelDisplayName(for role: DownloadRole, transcriptionModel: String, diarizationModel: DiarizationModelSelection?, customVocabularyModel: CustomVocabularyModelSelection?) -> String {
        switch role {
        case .transcription:
            return transcriptionModel
        case .diarization:
            // Sortformer's variant id from the SDK ("384") doesn't read well, so we keep the
            // enum's user-facing displayName here ("Sortformer" / "Pyannote v4").
            return diarizationModel?.displayName ?? "Speaker"
        case .customVocabulary:
            guard let variant = customVocabularyModel?.variant else { return "" }
            return prettyVariantName(variant)
        }
    }

    // MARK: - On-disk lookups

    func transcriptionModelFolder(_ variant: String) -> URL? {
        for repo in modelStore.availableModelRepos() where modelStore.modelExists(variant: variant, from: repo) {
            return modelStore.transcriberFolder(repo: repo).appendingPathComponent(variant, isDirectory: true)
        }
        // Qwen ships in a dedicated repo that isn't in availableModelRepos(); check its folder directly.
        if TranscriptionModelFamily(modelName: variant) == .qwen {
            let folder = modelStore.transcriberFolder(repo: AppSettings.qwenModelRepo)
                .appendingPathComponent(variant, isDirectory: true)
            if folderHasContents(folder) { return folder }
        }
        return nil
    }

    func diarizationModelFolder(_ model: DiarizationModelSelection) -> URL {
        modelStore.transcriberFolder(repo: model.modelRepo)
    }

    func customVocabularyModelFolder() -> URL {
        modelStore.transcriberFolder(repo: customVocabularyRepoId)
            .appendingPathComponent(customVocabularyVariant, isDirectory: true)
    }

    func folderHasContents(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return !contents.isEmpty
    }

    func folderURL(for role: DownloadRole, transcriptionModel: String, diarizationModel: DiarizationModelSelection?) -> URL? {
        switch role {
        case .transcription:
            return transcriptionModelFolder(transcriptionModel)
        case .diarization:
            guard let model = diarizationModel else { return nil }
            let folder = diarizationModelFolder(model)
            return folderHasContents(folder) ? folder : nil
        case .customVocabulary:
            let folder = customVocabularyModelFolder()
            return folderHasContents(folder) ? folder : nil
        }
    }

    nonisolated private static let directorySizeKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]

    /// Recursively sums file sizes under `url`. Returns `nil` if the directory can't be read.
    /// `nonisolated` so callers running off the main actor (the detached size-recompute task,
    /// the diagnostic logger walking folders) can invoke it without an actor hop.
    nonisolated static func directorySize(at url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: directorySizeKeys,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(directorySizeKeys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Lifecycle-state derivation

    func isTransientState(_ state: PipelineState) -> Bool {
        switch state {
        case .downloading, .waitingForWifi, .paused, .specializing, .loading, .verifying: return true
        case .notDownloaded, .downloaded, .incomplete, .unverified, .loaded, .failed: return false
        }
    }

    func isActiveDownloadState(_ state: PipelineState) -> Bool {
        switch state {
        case .downloading, .waitingForWifi, .paused: return true
        default: return false
        }
    }

    /// The lifecycle state of a pipeline for the currently-selected variant. Order of precedence:
    /// (1) an active (non-terminal) background download for `(currentVariant, currentRepo)` -- its
    /// status drives the row; (2) the loaded transcriber/diarizer state (`whisperKit` / `speakerKit`); (3) the
    /// SDK's `verifyModelSync` against the recorded download-cache entry.
    ///
    /// A model is **only** classified `.downloaded` when verification confirms it. No
    /// folder-content heuristics are used to claim `.downloaded` -- the row never lies about
    /// readiness. When verification has no reference (`.unknown`), a non-empty folder reads as
    /// `.incomplete` (something there, can't confirm it's valid) and an empty/missing folder as
    /// `.notDownloaded`.
    func staticState(for role: DownloadRole) -> PipelineState {
        if let active = activeDownload(for: role) {
            return downloadState(for: active)
        }
        let (transcriptionModel, diarizationModel, customVocabularyModel) = pipelineSelection
        switch role {
        case .transcription:
            if whisperKitModelState == .loaded {
                // Qwen loads as `qwen` (no `whisperKit`); Whisper/Parakeet load as `whisperKit`.
                if qwen != nil { return .loaded }
                if whisperKit != nil { return .loaded }
            }
            // Qwen uses a dedicated HF repo not in availableModelRepos(); check it directly so a
            // downloaded-but-not-loaded Qwen model isn't misreported as .notDownloaded.
            if TranscriptionModelFamily(modelName: transcriptionModel) == .qwen {
                let qwenRepo = AppSettings.qwenModelRepo
                return pipelineState(
                    from: modelStore.verifyModelSync(modelVariant: transcriptionModel, repoId: qwenRepo),
                    fallbackFolder: transcriptionModelFolder(transcriptionModel))
            }
            guard let repo = transcriptionModelRepo(transcriptionModel) else {
                // `transcriptionModelRepo` only returns a repo if `modelExists` says so; nil means
                // no folder for this variant in any configured repo -> nothing on disk.
                return .notDownloaded
            }
            return pipelineState(from: modelStore.verifyModelSync(modelVariant: transcriptionModel, repoId: repo),
                                 fallbackFolder: transcriptionModelFolder(transcriptionModel))
        case .diarization:
            guard let model = diarizationModel else { return .notDownloaded }
            if speakerKitModelState == .loaded, loadedDiarizationModel == model { return .loaded }
            if model.isSortformer {
                let info = ModelInfo.sortformerDefault()
                let variant = info.variant ?? info.name
                return pipelineState(from: modelStore.verifyModelSync(modelVariant: variant, repoId: model.modelRepo),
                                     fallbackFolder: diarizationModelFolder(model))
            }
            // Pyannote isn't on the background-download path yet (no cache entry to verify
            // against). Fall back to its per-component file check; a non-empty folder that fails
            // the component check reads as `.incomplete`.
            if isDiarizationModelDownloaded(model) { return .downloaded }
            return folderHasContents(diarizationModelFolder(model)) ? .incomplete : .notDownloaded
        case .customVocabulary:
            guard let cvModel = customVocabularyModel else { return .notDownloaded }
            // Reflect the SDK's actual CTC-audio-encoder state -- `whisperKit != nil` alone said
            // "loaded" the instant `WhisperKitPro` was constructed, before specialization or load
            // had run.
            if whisperKit?.customVocabularyModelState == .loaded {
                return .loaded
            }
            return pipelineState(from: modelStore.verifyModelSync(modelVariant: cvModel.variant, repoId: cvModel.modelRepo),
                                 fallbackFolder: customVocabularyModelFolder())
        }
    }

    /// Maps a `ModelVerification` outcome to a `PipelineState`. `verified` -> `.downloaded`.
    /// `incomplete` -> `.incomplete` (files present but mismatch the recorded reference).
    /// `unknown` -> `.unverified` if there's content on disk (something's there but we have no
    /// cache entry / live record to compare against -- e.g. an upgrade from an older SDK build),
    /// else `.notDownloaded`. This preserves the **no-lie** rule (never `.downloaded` without a
    /// passing verifier) while not falsely accusing the user's files of being incomplete.
    func pipelineState(from verification: ModelVerification, fallbackFolder: URL?) -> PipelineState {
        switch verification.outcome {
        case .verified: return .downloaded
        case .incomplete: return .incomplete
        case .unknown:
            guard let folder = fallbackFolder else { return .notDownloaded }
            return folderHasContents(folder) ? .unverified : .notDownloaded
        }
    }

    /// The repo id of the configured repo that contains `variant` on disk, if any.
    func transcriptionModelRepo(_ variant: String) -> String? {
        for repo in modelStore.availableModelRepos() where modelStore.modelExists(variant: variant, from: repo) {
            return repo.repoId
        }
        return nil
    }

    // MARK: - Row maintenance

    func updatePipelineRow(_ role: DownloadRole, _ mutate: (inout ModelPipelineRow) -> Void) {
        guard let index = pipelineRows.firstIndex(where: { $0.role == role }) else { return }
        var row = pipelineRows[index]
        mutate(&row)
        if row != pipelineRows[index] { pipelineRows[index] = row }
    }

    /// Computes (off the main actor) `sizeOnDisk` for any `.downloaded`/`.loaded`/`.incomplete`
    /// row missing it. `directorySize` is `nonisolated`, so the filesystem walk runs on the
    /// Task's executor without re-entering the main actor; only the row write hops back.
    func recomputeSizesIfNeeded() {
        for row in pipelineRows {
            guard row.sizeOnDisk == nil,
                  row.state == .downloaded || row.state == .loaded || row.state == .incomplete,
                  let folder = row.folderURL else { continue }
            let role = row.role
            Task(priority: .utility) { [weak self] in
                let size = await Task.detached { Self.directorySize(at: folder) }.value
                guard let self else { return }
                self.updatePipelineRow(role) { if $0.sizeOnDisk == nil { $0.sizeOnDisk = size } }
            }
        }
    }

    /// Rebuilds `pipelineRows` to match the current model selection. Rows mid-download/specialization
    /// keep their transient state; everything else is re-derived from disk and the loaded transcriber and diarizer.
    /// Call this from the view when the selection changes (and on appear); the coordinator also calls
    /// it after a load, delete, or reset.
    func syncPipelineRows(transcriptionModel: String, diarizationModel: DiarizationModelSelection?, customVocabularyModel: CustomVocabularyModelSelection?) {
        pipelineSelection = (transcriptionModel, diarizationModel, customVocabularyModel)

        // All three roles are always present -- disabled ones still render so their selector picker
        // stays reachable. `isEnabled` tracks whether the user has the pipeline selected. Custom
        // vocabulary sits above diarization so the user reads the sidebar top-to-bottom in
        // selection order: transcription -> optional CTC boost -> optional speaker labeling.
        let desiredRoles: [DownloadRole] = [.transcription, .customVocabulary, .diarization]
        let enabledByRole: [DownloadRole: Bool] = [
            .transcription: true,
            .diarization: diarizationModel != nil,
            .customVocabulary: customVocabularyModel != nil,
        ]

        var rebuilt: [ModelPipelineRow] = []
        for role in desiredRoles {
            let previousRow = pipelineRows.first { $0.role == role }
            let newModelName = modelDisplayName(for: role, transcriptionModel: transcriptionModel, diarizationModel: diarizationModel, customVocabularyModel: customVocabularyModel)
            // A different `modelName` for the same role means the user switched variants (e.g. a
            // different transcription model, or Sortformer vs. Pyannote). The previous variant's
            // download stays in the SDK as-is -- paused/in-progress records aren't ours to wipe
            // because the user clicked the picker, and keeping them lets a switch-back resume
            // where the user left off. The row reflects the new variant.
            let modelChanged = previousRow.map { $0.modelName != newModelName && !$0.modelName.isEmpty } ?? false
            var row = previousRow
                ?? ModelPipelineRow(role: role, pipelineName: pipelineName(for: role), modelName: "",
                                    iconName: iconName(for: role),
                                    isEnabled: enabledByRole[role] ?? false,
                                    state: .notDownloaded, sizeOnDisk: nil, folderURL: nil, downloadId: nil)
            row.pipelineName = pipelineName(for: role)
            row.iconName = iconName(for: role)
            row.isEnabled = enabledByRole[role] ?? false
            row.modelName = newModelName
            row.folderURL = folderURL(for: role, transcriptionModel: transcriptionModel, diarizationModel: diarizationModel)
            if modelChanged {
                // Re-derive from scratch for the new variant. `staticState` consults
                // `activeDownload(for:)`, so if the user switched *back* to a previously-paused
                // model it picks up that download's `.paused(fraction)` automatically.
                row.state = staticState(for: role)
                row.downloadId = activeDownload(for: role)?.downloadId
                row.sizeOnDisk = nil
            } else if case .failed = row.state {
                // `.failed` is sticky. A load failure (e.g. CoreML refused to compile a
                // content-corrupt `.mlmodelc` whose size happens to match) is *more*
                // authoritative than a sync verifier that can only check sizes -- never overwrite
                // it back to `.downloaded`. Cleared only by an explicit user action (Retry, delete)
                // or by changing variants (the `modelChanged` branch above).
            } else if row.state == .verifying {
                // `.verifying` is driven exclusively by `kickOffUnverifiedHeadChecks()`. If we
                // re-derived it here (it's transient and `modelLoadInProgress` is false during
                // background verification), it would reset to `.unverified` on every view appear,
                // spawning a new concurrent HEAD call each time.
            } else if !isTransientState(row.state) || !modelLoadInProgress {
                // Two cases land here:
                //   1) Not in a transient state -- normal re-derive.
                //   2) In a transient state (`.specializing`, `.loading`, ...) but `modelLoadInProgress`
                //      is false, meaning the load already finished. The transient skip exists to
                //      protect in-flight loads from being clobbered; once the load is done, the
                //      row should resolve to a terminal state. Re-deriving picks up `.loaded` from
                //      `staticState` (which checks `whisperKitModelState == .loaded`).
                let derived = staticState(for: role)
                if derived != row.state { row.state = derived; row.sizeOnDisk = nil }
                if row.downloadId == nil, isActiveDownloadState(row.state) {
                    row.downloadId = activeDownload(for: role)?.downloadId
                }
            }
            rebuilt.append(row)
        }
        if rebuilt != pipelineRows { pipelineRows = rebuilt }
        recomputeSizesIfNeeded()
        // Kick off async upstream HEAD verification for any row in `.unverified` (files on disk
        // but no cache entry -- typically an upgrade from an older SDK build). The SDK persists
        // a cache entry on success, so this self-heals on first launch and never repeats.
        kickOffUnverifiedHeadChecks()
    }

    /// Runs `verifyModel` (online HEAD) for every `.unverified` row and updates the row state
    /// when the result arrives. The SDK writes a cache entry on `.verified`, so subsequent
    /// launches use the sync cache path immediately. While the HEAD round-trip is in flight
    /// the row shows `.verifying` so the UI doesn't keep saying "verifying..." forever if the
    /// network drops (in that case the row reverts to `.unverified` and the user can retry).
    private func kickOffUnverifiedHeadChecks() {
        for row in pipelineRows where row.state == .unverified {
            guard let request = unverifiedVerifyRequest(for: row.role) else { continue }
            updatePipelineRow(row.role) { $0.state = .verifying }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let verification = await self.modelStore.verifyModel(
                    modelVariant: request.variant,
                    repoId: request.repo,
                    destinationFolder: request.folder
                )
                guard let currentRow = self.pipelineRows.first(where: { $0.role == row.role }),
                      currentRow.state == .verifying else { return }
                let newState = self.pipelineState(from: verification, fallbackFolder: request.folder)
                self.updatePipelineRow(row.role) { $0.state = newState }
            }
        }
    }

    /// Resolves `(variant, repo, folder)` for a role using the current `pipelineSelection`.
    /// Returns nil when there's nothing to verify (e.g. an empty selection).
    private func unverifiedVerifyRequest(for role: DownloadRole) -> (variant: String, repo: String, folder: URL?)? {
        let (transcriptionModel, diarizationModel, customVocabularyModel) = pipelineSelection
        switch role {
        case .transcription:
            guard !transcriptionModel.isEmpty else { return nil }
            if TranscriptionModelFamily(modelName: transcriptionModel) == .qwen {
                return (transcriptionModel, AppSettings.qwenModelRepo, transcriptionModelFolder(transcriptionModel))
            }
            guard let repo = transcriptionModelRepo(transcriptionModel) else { return nil }
            return (transcriptionModel, repo, transcriptionModelFolder(transcriptionModel))
        case .diarization:
            guard let model = diarizationModel, model.isSortformer else { return nil }
            let info = ModelInfo.sortformerDefault()
            let variant = info.variant ?? info.name
            return (variant, model.modelRepo, diarizationModelFolder(model))
        case .customVocabulary:
            guard let cvModel = customVocabularyModel else { return nil }
            return (cvModel.variant, cvModel.modelRepo, customVocabularyModelFolder())
        }
    }

    /// Maps a `BackgroundDownloadStatus` + progress into a `PipelineState`.
    func downloadState(for state: BackgroundDownloadState) -> PipelineState {
        let bytesDone = state.files.reduce(Int64(0)) { $0 + $1.bytesDownloaded }
        let bytesTotal = state.files.reduce(Int64(0)) { $0 + max($1.totalBytes, 0) }
        switch state.status {
        case .pending, .downloading:
            return .downloading(fraction: state.overallProgress, bytesDone: bytesDone, bytesTotal: bytesTotal)
        case .pausedByNetwork:
            return .waitingForWifi
        case .paused:
            return .paused(fraction: state.overallProgress)
        case .completed:
            return .specializing
        case .failed:
            return .failed(state.files.first(where: { $0.status == .failed })?.errorMessage ?? "Download failed")
        case .cancelled:
            return .notDownloaded
        }
    }

    /// Infers which pipeline a persisted background download belongs to from its `repoId`. The
    /// playground's three pipelines map to disjoint repos: `ctckit-pro` is custom vocabulary,
    /// anything `speakerkit*` is diarization, everything else is transcription.
    func role(for state: BackgroundDownloadState) -> DownloadRole? {
        if state.repoId == customVocabularyRepoId { return .customVocabulary }
        if state.repoId.contains("speakerkit") { return .diarization }
        return .transcription
    }

    /// Called whenever the SDK's active-downloads list changes. Updates (and, on a cold launch,
    /// re-creates) the row for any in-progress download; a row whose download has dropped out of the
    /// active list has finished -- during a load it advances to `.specializing`, otherwise `.downloaded`.
    func applyActiveDownloads(_ states: [BackgroundDownloadState]) {
        var handledRoles = Set<DownloadRole>()
        for state in states {
            guard let role = role(for: state) else { continue }
            // Only let downloads for the currently-selected variant drive the row. Leftover
            // paused records for previously-selected variants stay in the SDK (so the user can
            // switch back and resume) but they don't clobber the row for whatever's selected now.
            guard matchesCurrentSelection(state, for: role) else { continue }
            handledRoles.insert(role)
            switch state.status {
            case .downloading, .pending, .paused, .pausedByNetwork:
                if pipelineRows.contains(where: { $0.role == role }) {
                    updatePipelineRow(role) { $0.downloadId = state.downloadId; $0.state = downloadState(for: state) }
                } else {
                    pipelineRows.append(ModelPipelineRow(
                        role: role, pipelineName: pipelineName(for: role),
                        modelName: role == .transcription ? state.modelVariant : modelDisplayName(for: role, transcriptionModel: "", diarizationModel: requestedDiarizationModel, customVocabularyModel: pipelineSelection.customVocabularyModel),
                        iconName: iconName(for: role),
                        isEnabled: true,
                        state: downloadState(for: state), sizeOnDisk: nil, folderURL: nil, downloadId: state.downloadId))
                }
            case .failed:
                if pipelineRows.contains(where: { $0.role == role }) {
                    updatePipelineRow(role) { $0.state = downloadState(for: state); $0.downloadId = nil }
                }
            case .cancelled:
                if pipelineRows.contains(where: { $0.role == role }) {
                    updatePipelineRow(role) { $0.state = staticState(for: role); $0.downloadId = nil }
                }
            case .completed:
                advanceCompletedDownloadRow(role)
            }
        }
        // Rows that were downloading and no longer appear in the active list (filtered out or
        // finished): the download is done. Only advance if no active download remains for this
        // row's variant -- `handledRoles` only counts ones that matched the current selection.
        for row in pipelineRows where !handledRoles.contains(row.role) && row.downloadId != nil && isActiveDownloadState(row.state) {
            if activeDownload(for: row.role) == nil {
                advanceCompletedDownloadRow(row.role)
            }
        }
        recomputeSizesIfNeeded()
    }

    func advanceCompletedDownloadRow(_ role: DownloadRole) {
        // The backgroundDownloadsPublisher can fire a .completed event *after* the row has already
        // advanced to .loaded (the load finished before the final publish arrived). Don't downgrade.
        if case .loaded = pipelineRows.first(where: { $0.role == role })?.state { return }
        if modelLoadInProgress {
            updatePipelineRow(role) { $0.state = .specializing; $0.downloadId = nil }
        } else {
            updatePipelineRow(role) { $0.state = .downloaded; $0.downloadId = nil; $0.sizeOnDisk = nil }
        }
    }

    /// Maps a `ModelState` change (transcription or diarization) into a row-state update during a load.
    func syncModelState(_ role: DownloadRole, _ state: ModelState) {
        guard let currentState = pipelineRows.first(where: { $0.role == role })?.state else { return }
        switch state {
        case .downloading:
            // Byte-level progress comes from the active-download sink. Only set the initial
            // pre-progress placeholder for diarization, and only if the row isn't already
            // showing real download/paused/wifi state from the sink -- otherwise we'd clobber it
            // back to 0% every time `prepare` re-enters and reassigns `speakerKitModelState`.
            guard role == .diarization else { return }
            switch currentState {
            case .downloading, .waitingForWifi, .paused: return
            default: updatePipelineRow(role) { $0.state = .downloading(fraction: 0, bytesDone: 0, bytesTotal: 0) }
            }
        case .prewarming, .downloaded:
            updatePipelineRow(role) { $0.state = .specializing }
        case .prewarmed, .loading:
            // The transcriber surfaces a distinct "loading into memory" phase after specialization;
            // the diarizer's loader doesn't, so keep it on "Specializing..." for visual consistency.
            updatePipelineRow(role) { $0.state = (role == .diarization) ? .specializing : .loading }
        case .loaded:
            updatePipelineRow(role) { $0.state = .loaded; $0.sizeOnDisk = nil }
            recomputeSizesIfNeeded()
        case .unloaded, .unloading:
            // Re-derive from disk on unload -- but only if there's no active (non-terminal)
            // background download for this role. If there IS one (e.g. the user paused
            // mid-download, prepare bailed, and the .paused record is still in the active list),
            // the active-downloads sink is the authoritative source for the row's state -- letting
            // `staticState` (which sees the partial folder as "downloaded") win would briefly
            // flash the row to `.downloaded` before the sink corrects it back to `.paused`.
            if activeDownloadId(for: role) == nil {
                updatePipelineRow(role) { $0.state = staticState(for: role) }
            }
        }
    }

    /// Reconstructs panel rows at launch for any download still in progress from a prior run
    /// (e.g. the app was quit mid-download -- background-session transfers keep running). Reads
    /// the SDK's records synchronously so the panel shows the in-progress download immediately,
    /// rather than waiting for the first `backgroundDownloadsPublisher` publish.
    func reconstructPipelineRowsFromPersistedState() {
        applyActiveDownloads(modelStore.activeBackgroundDownloads)
    }

    /// Waits for a background download to reach a terminal state. Returns the model folder URL on
    /// completion, or `nil` if the download is parked (waiting for Wi-Fi), user-paused, or
    /// cancelled -- callers should treat `nil` as "deferred, not failed". Throws on `.failed`.
    @MainActor
    func waitForBackgroundDownload(_ result: BackgroundDownloadResult, expectedFolder: URL) async throws -> URL? {
        let downloadId: String
        switch result {
        case .alreadyComplete(let path):
            return path
        case .waitingForNetwork:
            return nil
        case .started(let id), .resumed(let id), .alreadyInProgress(let id):
            downloadId = id
        }
        while true {
            try Task.checkCancellation()
            guard let state = modelStore.getBackgroundDownloadState(downloadId) else {
                // No longer tracked -- assume it was cancelled/deleted; nothing to load.
                return nil
            }
            switch state.status {
            case .completed:
                return state.destinationFolder
            case .failed:
                let message = state.files.first(where: { $0.status == .failed })?.errorMessage ?? "Download failed"
                throw ArgmaxError.generic(message)
            case .cancelled:
                return nil
            case .pausedByNetwork, .paused:
                return nil
            case .downloading, .pending:
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Panel actions (delete / retry / repair / pause / resume / cancel)

    /// The active (non-terminal) background download for the currently-selected variant of `role`.
    /// Matches by `(modelVariant, repoId)` against `pipelineSelection`. Leftover downloads for
    /// previously-selected variants (e.g. a paused download for a transcription model the user
    /// switched away from) are intentionally not returned here -- they live on in the SDK so a
    /// switch-back can resume them, but they don't belong to the current row.
    func activeDownload(for role: DownloadRole) -> BackgroundDownloadState? {
        let states = modelStore.activeBackgroundDownloads
        let isActive: (BackgroundDownloadState) -> Bool = { state in
            state.status != .completed && state.status != .failed && state.status != .cancelled
        }
        return states.first { state in
            isActive(state) && matchesCurrentSelection(state, for: role)
        }
    }

    /// `true` when `state` corresponds to the currently-selected `(variant, repo)` for `role`.
    /// Tolerant of an empty `pipelineSelection` (pre-`syncPipelineRows`, e.g. during `init`'s
    /// reconstruction) so we don't drop persisted downloads on the floor before the view has
    /// declared what's selected.
    func matchesCurrentSelection(_ state: BackgroundDownloadState, for role: DownloadRole) -> Bool {
        let (transcriptionModel, diarizationModel, customVocabularyModel) = pipelineSelection
        switch role {
        case .transcription:
            if transcriptionModel.isEmpty { return true }
            return state.modelVariant == transcriptionModel
        case .diarization:
            guard let model = diarizationModel else { return true }
            if model.isSortformer {
                let info = ModelInfo.sortformerDefault()
                return state.modelVariant == (info.variant ?? info.name) && state.repoId == model.modelRepo
            }
            return false
        case .customVocabulary:
            guard let cvModel = customVocabularyModel else { return false }
            return state.modelVariant == cvModel.variant && state.repoId == cvModel.modelRepo
        }
    }

    /// Returns the download id from ``activeDownload(for:)``.
    func activeDownloadId(for role: DownloadRole) -> String? {
        activeDownload(for: role)?.downloadId
    }

    /// All `BackgroundDownloadState` records that match the currently-selected `(variant, repo)`
    /// for this role -- *including* terminal ones (`.completed`/`.failed`/`.cancelled`). Used by
    /// `deletePipeline` to wipe stale records that `activeDownload` (which filters to non-terminal)
    /// won't surface; without removing them, `verifyModelSync` keeps falling through to the live
    /// record and reports `.incomplete` even after the user deleted everything.
    func allDownloadIds(matchingSelectionFor role: DownloadRole) -> [String] {
        modelStore.activeBackgroundDownloads
            .filter { matchesCurrentSelection($0, for: role) }
            .map(\.downloadId)
    }

    func pauseModelDownload(_ role: DownloadRole) {
        guard let id = activeDownloadId(for: role) else { return }
        modelStore.pauseBackgroundDownload(id)
    }

    func resumeModelDownload(_ role: DownloadRole) {
        guard let id = activeDownloadId(for: role) else { return }
        Task { try? await modelStore.resumeBackgroundDownload(id, token: keyProvider.huggingFaceToken) }
    }

    func cancelModelDownload(_ role: DownloadRole, deleteProgress: Bool) {
        if let id = activeDownloadId(for: role) {
            modelStore.cancelBackgroundDownload(id, deleteProgress: deleteProgress)
        }
        updatePipelineRow(role) { $0.state = staticState(for: role); $0.downloadId = nil; $0.sizeOnDisk = nil }
        recomputeSizesIfNeeded()
    }

    /// Removes a pipeline's model from disk (cancelling *all* matching download records -- active
    /// and terminal -- clearing its download-cache entry, and unloading the corresponding transcriber or diarizer),
    /// then re-derives the panel rows. Resets the row to `.notDownloaded` explicitly so a sticky
    /// `.failed` state from a prior load failure doesn't survive the wipe.
    @MainActor
    func deletePipeline(_ role: DownloadRole) async {
        Logging.debug("[ModelDiag] deletePipeline(\(role.rawValue)) starting")
        // Wiping the model invalidates any prior content-mismatch tracking for this role.
        contentMismatchFiles[role] = nil
        // Wipe every download record for this `(variant, repo)` -- including terminal `.completed`
        // records that linger after a successful download. Leaving those behind makes
        // `verifyModelSync` fall through to the live state and report `.incomplete` (cache says
        // files should be X bytes, disk has none). `deleteProgress: true` is the hard-cancel
        // path that removes the record from `downloads` (the `false` path is a soft cancel that
        // flips status to `.paused`).
        for id in allDownloadIds(matchingSelectionFor: role) {
            modelStore.cancelBackgroundDownload(id, deleteProgress: true)
        }
        let (transcriptionModel, diarizationModel, _) = pipelineSelection
        switch role {
        case .transcription:
            if whisperKitModelState != .unloaded { await reset() }
            for repo in modelStore.availableModelRepos() where modelStore.modelExists(variant: transcriptionModel, from: repo) {
                try? await modelStore.deleteModel(variant: transcriptionModel, from: repo)   // also clears the cache entry
            }
            // Qwen lives in its own HF repo outside availableModelRepos(), so handle it explicitly.
            if TranscriptionModelFamily(modelName: transcriptionModel) == .qwen {
                let qwenRepo = AppSettings.qwenModelRepo
                modelStore.clearDownloadCacheEntry(modelVariant: transcriptionModel, repoId: qwenRepo)
                let qwenFolder = modelStore.transcriberFolder(repo: qwenRepo)
                    .appendingPathComponent(transcriptionModel, isDirectory: true)
                removeFolderIfPresent(qwenFolder, context: "qwen-transcription")
            }
            await updateModelList()
        case .diarization:
            guard let model = diarizationModel else { break }
            await unloadSpeakerKit()
            if model.isSortformer {
                let info = ModelInfo.sortformerDefault()
                modelStore.clearDownloadCacheEntry(modelVariant: info.variant ?? info.name, repoId: model.modelRepo)
            }
            removeFolderIfPresent(diarizationModelFolder(model), context: "diarization")
        case .customVocabulary:
            if whisperKit != nil { await reset() }
            modelStore.clearDownloadCacheEntry(modelVariant: customVocabularyVariant, repoId: customVocabularyRepoId)
            removeFolderIfPresent(customVocabularyModelFolder(), context: "customVocabulary")
        }
        // Explicit user wipe: reset the row past any sticky `.failed`. `syncPipelineRows` then
        // re-derives via `staticState` (which, with no cache entry and no folder, lands on
        // `.notDownloaded`).
        updatePipelineRow(role) { $0.downloadId = nil; $0.sizeOnDisk = nil; $0.state = .notDownloaded }
        syncPipelineRows(transcriptionModel: pipelineSelection.transcriptionModel,
                         diarizationModel: pipelineSelection.diarizationModel,
                         customVocabularyModel: pipelineSelection.customVocabularyModel)
        logModelDiagnostics("after deletePipeline(\(role.rawValue))")
    }

    private func removeFolderIfPresent(_ folder: URL, context: String) {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            Logging.debug("[ModelDiag] deletePipeline(\(context)): nothing to remove at \(folder.path)")
            return
        }
        do {
            try FileManager.default.removeItem(at: folder)
            Logging.debug("[ModelDiag] deletePipeline(\(context)): removed \(folder.path)")
        } catch {
            Logging.error("[ModelDiag] deletePipeline(\(context)): removeItem(\(folder.path)) failed: \(error)")
        }
    }

    /// Re-attempts a model download for a row that needs action. For `.failed` (a load failure --
    /// usually content corruption that passed size-only verification), a bare retry would just
    /// see `.alreadyComplete` and load the same corrupt files again -- so wipe first, then load.
    /// For `.incomplete`, the background downloader will fill in missing/wrong-sized files on
    /// the next `prepare` so no wipe is needed.
    func retryPipeline(_ role: DownloadRole, settings: AppSettings) {
        let currentState = pipelineRows.first(where: { $0.role == role })?.state
        if case .failed = currentState {
            Task { @MainActor in
                await self.deletePipeline(role)
                self.requestLoadModels(modelName: settings.selectedModel, redownload: false, settings: settings)
            }
            return
        }
        requestLoadModels(modelName: settings.selectedModel, redownload: false, settings: settings)
    }

    /// Targeted re-download of only the files reported as content-corrupt by the SHA-256
    /// gate in `prepare`. Distinct from `retryPipeline`, which wipes the whole model and
    /// re-fetches every file. Used by the "Repair" button on rows whose `.failed` state was
    /// a content-mismatch failure.
    func repairContentMismatch(_ role: DownloadRole, settings: AppSettings) {
        guard let bad = contentMismatchFiles[role], !bad.isEmpty else { return }
        let request: (variant: String, repo: String)?
        switch role {
        case .transcription:
            let model = settings.selectedModel
            request = transcriptionModelRepo(model).map { (model, $0) }
        case .diarization:
            if let m = settings.selectedDiarizationModel, m.isSortformer {
                let info = ModelInfo.sortformerDefault()
                request = (info.variant ?? info.name, m.modelRepo)
            } else {
                request = nil
            }
        case .customVocabulary:
            if let cvModel = settings.selectedCustomVocabularyModel {
                request = (cvModel.variant, cvModel.modelRepo)
            } else {
                request = nil
            }
        }
        guard let req = request else { return }
        Task { @MainActor in
            do {
                _ = try await modelStore.redownloadFiles(modelVariant: req.variant, repoId: req.repo, relativePaths: bad)
                self.contentMismatchFiles[role] = nil
                self.requestLoadModels(modelName: settings.selectedModel, redownload: false, settings: settings)
            } catch {
                Logging.error("[ArgmaxSDKCoordinator] Repair failed for \(role.rawValue): \(error)")
            }
        }
    }

    /// True when the most recent prepare attempt for `role` failed specifically due to a
    /// content-hash mismatch (SHA-256 != recorded HF ETag) -- distinct from a generic load
    /// failure. Drives the "Repair" affordance in the sidebar.
    func hasContentMismatch(_ role: DownloadRole) -> Bool {
        !(contentMismatchFiles[role]?.isEmpty ?? true)
    }

    /// Updates the interface restriction for a tracked download (e.g. lift Wi-Fi-only for a
    /// single download from the "Use cellular" button on a waiting row).
    func setBackgroundDownloadRestriction(_ types: [NWInterface.InterfaceType]?, role: DownloadRole) {
        guard let id = activeDownloadId(for: role) else { return }
        modelStore.setDisabledBackgroundDownloadNetworkTypes(types, for: id)
    }
}
