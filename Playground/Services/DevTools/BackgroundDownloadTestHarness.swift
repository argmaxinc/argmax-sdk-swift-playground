import Argmax
import Combine
import Foundation
import Network
import UserNotifications

/// Background-download verification harness for `ArgmaxSDKCoordinator`, surfaced in
/// `BackgroundDownloadTestPage` behind Settings > Developer. It ships in Release builds:
/// the playground is a developer-facing sample app, and the harness is part of what it
/// demonstrates.
///
/// Implemented as an extension because every operation needs the coordinator's `modelStore`
/// and feeds the coordinator's `@Published` harness state the settings UI already observes.
/// Extensions can't hold stored properties, so that state (`backgroundDownloadTest*`,
/// `backgroundEvents`, `currentBackgroundDownloadId`, etc.) lives on the coordinator;
/// behavior lives here.
extension ArgmaxSDKCoordinator {

    // MARK: - Event log

    /// Appends a timestamped event and persists immediately (capped at `BackgroundEvent.cap`)
    /// so the log survives a background-relaunch cycle. `@MainActor` via the coordinator.
    public func recordBackgroundEvent(_ message: String) {
        let event = BackgroundEvent(id: UUID(), timestamp: Date(), message: message)
        Logging.debug("[BackgroundEvent] \(message)")
        var current = backgroundEvents
        current.insert(event, at: 0)
        if current.count > BackgroundEvent.cap {
            current.removeLast(current.count - BackgroundEvent.cap)
        }
        backgroundEvents = current
        BackgroundEvent.save(current)
    }

    /// Clears the persisted background event log.
    public func clearBackgroundEvents() {
        backgroundEvents = []
        BackgroundEvent.save([])
    }

    // MARK: - Schedule / start

    /// Schedules a background download test: deletes the selected model (so the test is
    /// repeatable), starts a background-session download, and fires notifications at start,
    /// 50%, and completion. Resumes an existing resumable download for the model instead of
    /// starting fresh.
    ///
    /// - Parameter modelName: The model to download
    /// - Parameter disabledNetworkTypes: Network interface types this download is not allowed
    ///   to use (e.g. `[.cellular]` for "Wi-Fi only"). `nil` (default) means no restriction.
    @MainActor
    public func scheduleBackgroundDownloadTest(
        modelName: String,
        disabledNetworkTypes: [NWInterface.InterfaceType]? = nil
    ) async {
        // Request notification permission
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                backgroundDownloadTestStatus = "Notification permission denied"
                return
            }
        } catch {
            backgroundDownloadTestStatus = "Failed to request notification permission: \(error)"
            return
        }

        backgroundDownloadTestActive = true
        recordBackgroundEvent("Scheduling \(modelName) (disabled: \(formatRestriction(disabledNetworkTypes)))")

        // Check if there's a paused download for this model we can resume
        let existingDownload = modelStore.activeBackgroundDownloads.first {
            $0.modelVariant == modelName && ($0.status == .paused || $0.status == .downloading || $0.status == .pausedByNetwork)
        }

        if let existing = existingDownload {
            backgroundDownloadTestStatus = "Found existing download (\(Int(existing.overallProgress * 100))%) - resuming..."
            currentBackgroundDownloadId = existing.downloadId
            // Apply any restriction change before resuming.
            modelStore.setDisabledBackgroundDownloadNetworkTypes(disabledNetworkTypes, for: existing.downloadId)
            do {
                try await modelStore.resumeBackgroundDownload(existing.downloadId)
                subscribeToDownloadProgress(downloadId: existing.downloadId)
                hasPausedDownload = false
                recordBackgroundEvent("Resumed existing download \(existing.downloadId.prefix(8))")
            } catch {
                backgroundDownloadTestStatus = "Failed to resume: \(error.localizedDescription)"
                backgroundDownloadTestActive = false
                recordBackgroundEvent("Resume failed: \(error.localizedDescription)")
            }
            return
        }

        // Fresh download -- reset milestone tracking only after confirming no resumable download
        // exists, so a resume doesn't re-fire the 50% notification for progress already past it.
        notifiedMilestones.removeAll()

        let repo = await findRepositoryForModel(modelName)

        backgroundDownloadTestStatus = "Deleting existing model..."

        // Delete the model first to make the test repeatable
        do {
            try await modelStore.deleteModel(variant: modelName, from: repo)
            backgroundDownloadTestStatus = "Model deleted. Starting background download..."
        } catch {
            // Model might not exist, that's fine
            backgroundDownloadTestStatus = "Starting background download..."
        }

        // Start the download immediately - the system will continue it in the background
        // when the app is closed. The URLSession background session is managed by iOS,
        // not our app process.
        await startBackgroundDownloadTest(modelName: modelName, repo: repo, disabledNetworkTypes: disabledNetworkTypes)
    }

    @MainActor
    private func startBackgroundDownloadTest(
        modelName: String,
        repo: some RepoId,
        disabledNetworkTypes: [NWInterface.InterfaceType]?
    ) async {
        backgroundDownloadTestStatus = "Starting background download..."

        // Send start notification
        await sendNotification(
            title: "Download Scheduled",
            body: "Downloading \(modelName) will start in 5 seconds - close app now!",
            identifier: "download-started"
        )

        do {
            // Schedule the background download to start in 5 seconds
            // iOS will manage this even if the app is closed - close the app now to test!
            let delaySeconds: TimeInterval = 5

            let result = try await modelStore.downloadModelInBackground(
                name: modelName,
                repo: repo,
                token: keyProvider.huggingFaceToken,
                delaySeconds: delaySeconds,
                disabledNetworkTypes: disabledNetworkTypes
            )

            // Handle the result based on what happened
            switch result {
            case .started(let downloadId):
                currentBackgroundDownloadId = downloadId
                hasPausedDownload = false
                backgroundDownloadTestStatus = "Scheduled in \(Int(delaySeconds))s - CLOSE APP NOW!"
                recordBackgroundEvent("Started \(modelName) [\(downloadId.prefix(8))] in \(Int(delaySeconds))s")
                subscribeToDownloadProgress(downloadId: downloadId)

            case .resumed(let downloadId):
                currentBackgroundDownloadId = downloadId
                hasPausedDownload = false
                backgroundDownloadTestStatus = "Resuming previous download..."
                recordBackgroundEvent("Resumed \(modelName) [\(downloadId.prefix(8))]")
                subscribeToDownloadProgress(downloadId: downloadId)

            case .alreadyInProgress(let downloadId):
                currentBackgroundDownloadId = downloadId
                hasPausedDownload = false
                backgroundDownloadTestStatus = "Download already in progress"
                recordBackgroundEvent("Already in progress [\(downloadId.prefix(8))]")
                subscribeToDownloadProgress(downloadId: downloadId)

            case .alreadyComplete(let path):
                backgroundDownloadTestStatus = "Model already downloaded"
                backgroundDownloadTestActive = false
                recordBackgroundEvent("Already complete: \(path.lastPathComponent)")
                await sendNotification(
                    title: "Already Downloaded",
                    body: "Model is already available at \(path.lastPathComponent)",
                    identifier: "download-complete"
                )

            case .waitingForNetwork(let downloadId):
                currentBackgroundDownloadId = downloadId
                hasPausedDownload = false
                backgroundDownloadTestStatus = "Waiting for an allowed network interface..."
                recordBackgroundEvent("Waiting for network [\(downloadId.prefix(8))] (restriction: \(formatRestriction(disabledNetworkTypes)))")
                subscribeToDownloadProgress(downloadId: downloadId)
            }

        } catch {
            backgroundDownloadTestStatus = "Failed to start download: \(error)"
            backgroundDownloadTestActive = false

            await sendNotification(
                title: "Download Failed",
                body: "Failed to start: \(error.localizedDescription)",
                identifier: "download-failed"
            )
        }
    }

    private func sendNotification(title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive  // More prominent, breaks through focus
        content.relevanceScore = 1.0  // Highest priority

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logging.error("Failed to send notification: \(error)")
        }
    }

    // MARK: - Cancel / resume / fresh-start

    /// Cancels the background download test.
    /// - Parameter deleteProgress: If true, deletes all partial downloads. If false (default),
    ///   preserves progress for resumption.
    @MainActor
    public func cancelBackgroundDownloadTest(deleteProgress: Bool = false) {
        // Cancel the actual background download tasks
        if let downloadId = currentBackgroundDownloadId {
            modelStore.cancelBackgroundDownload(downloadId, deleteProgress: deleteProgress)
            currentBackgroundDownloadId = nil
        }

        // Cancel the progress subscription
        backgroundDownloadCancellable?.cancel()
        backgroundDownloadCancellable = nil

        backgroundDownloadTestActive = false
        backgroundDownloadTestStatus = deleteProgress ? "Test cancelled (progress deleted)" : "Test paused (can resume)"
        backgroundDownloadProgress = 0
        notifiedMilestones.removeAll()

        if deleteProgress {
            // Hard-cancel: deletion is the desired terminal state. `BackgroundDownloader`
            // removes the record synchronously, but its `activeDownloads` is `@Published` and
            // updates via an async `Task { @MainActor ... }` hop -- calling `checkForPausedDownloads()`
            // here would still see the doomed entry and re-promote it into `hasPausedDownload`,
            // resurrecting a stale "Resume" button that fails with "download not found". Force
            // the terminal UI state directly.
            hasPausedDownload = false
            pausedDownloadModel = nil
            recordBackgroundEvent("Cancelled & deleted")
        } else {
            recordBackgroundEvent("Paused (preserved for resume)")
            checkForPausedDownloads()
        }
    }

    /// Checks for resumable downloads and populates `currentBackgroundDownloadId` from the
    /// most recent persisted record so the Verify button works after a cold relaunch.
    @MainActor
    public func checkForPausedDownloads() {
        let downloads = modelStore.activeBackgroundDownloads
        if let pausedDownload = downloads.first(where: {
            // Only truly-suspended states qualify as "paused". A `.downloading` download is
            // actively running and doesn't need a Resume button -- showing one leads to a
            // confusing "download not found" failure if tapped while the transfer is live.
            $0.status == .paused || $0.status == .pausedByNetwork
        }) {
            hasPausedDownload = true
            pausedDownloadModel = pausedDownload.modelVariant
            currentBackgroundDownloadId = pausedDownload.downloadId
        } else if let activeDownload = downloads.first(where: {
            $0.status == .downloading || $0.status == .pending
        }) {
            // Download is running (e.g. resumed after a cold relaunch) -- restore progress
            // subscription so the UI stays live, but don't surface a Resume button.
            hasPausedDownload = false
            pausedDownloadModel = nil
            currentBackgroundDownloadId = activeDownload.downloadId
            if !backgroundDownloadTestActive {
                backgroundDownloadTestActive = true
                subscribeToDownloadProgress(downloadId: activeDownload.downloadId)
            }
        } else {
            hasPausedDownload = false
            pausedDownloadModel = nil
            // Even with no resumable record, surface the most-recent terminal record (.completed
            // / .failed / .cancelled) so the Verify button can target it. Picks the latest by
            // `startedAt` so a cold relaunch lands on the most-relevant download.
            if currentBackgroundDownloadId == nil,
               let mostRecent = downloads.max(by: { $0.startedAt < $1.startedAt })
            {
                currentBackgroundDownloadId = mostRecent.downloadId
            }
        }
    }

    /// Resumes a paused background download.
    @MainActor
    public func resumeBackgroundDownload() async {
        guard let downloadId = currentBackgroundDownloadId else {
            backgroundDownloadTestStatus = "No download to resume"
            return
        }

        backgroundDownloadTestActive = true
        backgroundDownloadTestStatus = "Resuming download..."

        do {
            try await modelStore.resumeBackgroundDownload(downloadId)
            subscribeToDownloadProgress(downloadId: downloadId)
            hasPausedDownload = false
        } catch {
            backgroundDownloadTestStatus = "Failed to resume: \(error.localizedDescription)"
            backgroundDownloadTestActive = false
            hasPausedDownload = false
            currentBackgroundDownloadId = nil
        }
    }

    /// Starts a fresh download, clearing any existing progress.
    @MainActor
    public func startFreshBackgroundDownload(
        modelName: String,
        disabledNetworkTypes: [NWInterface.InterfaceType]? = nil
    ) async {
        modelStore.clearAllBackgroundDownloads()
        hasPausedDownload = false
        pausedDownloadModel = nil
        currentBackgroundDownloadId = nil
        recordBackgroundEvent("Cleared all downloads, starting fresh")

        await scheduleBackgroundDownloadTest(modelName: modelName, disabledNetworkTypes: disabledNetworkTypes)
    }

    /// Updates the per-download network-type restriction for the currently tracked download.
    /// Pass `nil` (or empty) to lift the restriction.
    @MainActor
    public func setBackgroundDownloadRestriction(_ types: [NWInterface.InterfaceType]?) {
        guard let id = currentBackgroundDownloadId else {
            recordBackgroundEvent("setRestriction called with no active download id")
            return
        }
        modelStore.setDisabledBackgroundDownloadNetworkTypes(types, for: id)
        recordBackgroundEvent("Restriction updated to \(formatRestriction(types)) [\(id.prefix(8))]")
    }

    // MARK: - Verify

    /// Read-only verification of a model's download state. Tries, in order: the active state
    /// for `currentBackgroundDownloadId`, the persistent ``DownloadCacheEntry`` for
    /// `(modelVariant, repoId)`, then HEAD upstream when `offlineMode == false`. Writes the
    /// result to the event log and `backgroundDownloadTestStatus`; never resumes/restarts.
    ///
    /// - Parameter offlineMode: When `false`, allows upstream HEAD requests and populates
    ///   `updateStatus` via etag comparison. Default `true` (no network).
    @MainActor
    @discardableResult
    public func verifyCurrentBackgroundDownload(
        modelVariant: String,
        offlineMode: Bool = true
    ) async -> ModelVerification? {
        // Path 1 -- verify by active downloadId when present.
        if let downloadId = currentBackgroundDownloadId,
           let activeStateReport = modelStore.verifyBackgroundDownload(downloadId)
        {
            logVerification(activeStateReport, prefix: "Verify [\(downloadId.prefix(8))]")
            return activeStateReport
        }

        // Path 2 + 3 -- fall back to (variant, repoId) lookup. Picks up cache entries from
        // prior completions and (with offlineMode == false) does HEAD-based verification for
        // sideloaded models or to populate `updateStatus`.
        guard !modelVariant.isEmpty else {
            backgroundDownloadTestStatus = "Verify: no model selected"
            recordBackgroundEvent("Verify: no model selected")
            return nil
        }
        let repoId = await findRepositoryForModel(modelVariant)
        let report = await modelStore.verifyModel(
            modelVariant: modelVariant,
            repoId: repoId,
            offlineMode: offlineMode
        )
        logVerification(report, prefix: "Verify \(modelVariant)")
        return report
    }

    /// Writes a ``ModelVerification`` result to the status string and event log, with a
    /// capped per-file breakdown when the outcome isn't `.verified`.
    @MainActor
    private func logVerification(_ result: ModelVerification, prefix: String) {
        backgroundDownloadTestStatus = "\(prefix): \(result.summary)"
        recordBackgroundEvent("\(prefix) (\(result.source)): \(result.summary)")

        if !result.missingFiles.isEmpty {
            let listing = result.missingFiles.prefix(8).joined(separator: ", ")
            let suffix = result.missingFiles.count > 8 ? "..." : ""
            recordBackgroundEvent("  Missing: \(listing)\(suffix)")
        }
        if !result.mismatchedFiles.isEmpty {
            let listing = result.mismatchedFiles.prefix(4).map { file in
                "\(file.relativePath) \(file.actualBytes ?? -1)/\(file.expectedBytes ?? -1)"
            }.joined(separator: ", ")
            let suffix = result.mismatchedFiles.count > 4 ? "..." : ""
            recordBackgroundEvent("  Wrong size: \(listing)\(suffix)")
        }
        if result.updateStatus == .updateAvailable {
            recordBackgroundEvent("  Upstream has newer revision (etag mismatch)")
        }
    }

    // MARK: - Helpers

    /// Short human-readable restriction label for log entries.
    fileprivate func formatRestriction(_ types: [NWInterface.InterfaceType]?) -> String {
        guard let types = types, !types.isEmpty else { return "none" }
        return types.map { typeName($0) }.joined(separator: ",")
    }

    fileprivate func typeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "ethernet"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    /// Clears ALL download state - use this to reset to a clean slate.
    @MainActor
    public func resetAllDownloadState() {
        backgroundDownloadCancellable?.cancel()
        backgroundDownloadCancellable = nil

        modelStore.clearAllBackgroundDownloads()

        hasPausedDownload = false
        pausedDownloadModel = nil
        currentBackgroundDownloadId = nil
        backgroundDownloadTestActive = false
        backgroundDownloadTestStatus = "All downloads cleared"
        notifiedMilestones.removeAll()
    }

    /// Subscribes to progress updates for a download, driving `backgroundDownloadProgress`,
    /// the 50% notification, and a once-per-transition status log.
    fileprivate func subscribeToDownloadProgress(downloadId: String) {
        backgroundDownloadCancellable = modelStore.backgroundDownloadsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] downloads in
                guard let self = self else { return }
                guard let download = downloads.first(where: { $0.downloadId == downloadId }) else { return }

                let progress = download.overallProgress
                self.backgroundDownloadProgress = Double(progress)

                // Fire the 50% milestone notification exactly once per download.
                if progress >= 0.5 && !self.notifiedMilestones.contains("50") {
                    self.notifiedMilestones.insert("50")
                    Task {
                        await self.sendNotification(
                            title: "Download 50% complete",
                            body: "\(download.modelVariant) is halfway downloaded",
                            identifier: "download-50pct-\(downloadId)"
                        )
                    }
                }

                // Log every status change once per transition.
                let prev = self.lastLoggedStatus[downloadId]
                if prev != download.status {
                    self.lastLoggedStatus[downloadId] = download.status
                    self.recordBackgroundEvent("[\(downloadId.prefix(8))] \(self.statusLabel(download.status)) @ \(Int(progress * 100))%")
                }

                switch download.status {
                case .pending, .downloading:
                    self.backgroundDownloadTestStatus = "Downloading: \(Int(progress * 100))%"
                case .paused:
                    self.backgroundDownloadTestStatus = "Paused at \(Int(progress * 100))%"
                case .pausedByNetwork:
                    self.backgroundDownloadTestStatus = "Waiting for allowed network at \(Int(progress * 100))%"
                case .completed:
                    self.backgroundDownloadTestStatus = "Download completed!"
                    self.backgroundDownloadTestActive = false
                    self.backgroundDownloadCancellable?.cancel()
                    self.hasPausedDownload = false
                    // Keep `currentBackgroundDownloadId` so the user can run "Verify
                    // Download" against the completed record.
                case .failed:
                    let errorMsg = download.files.first { $0.status == .failed }?.errorMessage ?? "Unknown error"
                    self.backgroundDownloadTestStatus = "Download failed: \(errorMsg)"
                    self.backgroundDownloadTestActive = false
                    self.backgroundDownloadCancellable?.cancel()
                    self.hasPausedDownload = false
                case .cancelled:
                    self.backgroundDownloadTestStatus = "Cancelled"
                    self.backgroundDownloadTestActive = false
                    self.backgroundDownloadCancellable?.cancel()
                    self.currentBackgroundDownloadId = nil
                    self.hasPausedDownload = false
                }
            }
    }

    fileprivate func statusLabel(_ status: BackgroundDownloadStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .downloading: return "downloading"
        case .paused: return "paused"
        case .pausedByNetwork: return "pausedByNetwork"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}
