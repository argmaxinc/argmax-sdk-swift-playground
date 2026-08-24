#if os(iOS)
import ActivityKit
import Foundation
import Argmax

/// Manages live activity lifecycle for transcription sessions with automatic cleanup
/// 
/// `LiveActivityManager` provides a robust Live Activity implementation for real-time transcription
/// status display on iOS lock screen, Dynamic Island, and notification banners. It handles the complete
/// lifecycle from creation to cleanup, with built-in safeguards against stale notifications.
/// 
/// ## Core Features
/// 
/// - **Activity Lifecycle:** Start, update, and stop Live Activities for transcription sessions
/// - **Content State Management:** Buffers and throttles updates to prevent system rate limiting
/// - **Heartbeat Monitoring:** Auto-dismisses stale activities after 60 seconds of no updates
/// - **Orphaned Activity Cleanup:** Removes lingering activities from previous app sessions
/// - **Resilient Lifecycle:** Logs and rethrows ActivityKit errors so the caller can surface them
/// 
/// ## Heartbeat
///
/// The manager runs a 60-second heartbeat timer. Each content update resets the timer, so active
/// transcriptions stay visible indefinitely; if updates stop arriving (suspended app, system
/// memory reclaim, lost connectivity), the timer ends the activity so a stale indicator doesn't
/// linger on the Lock Screen or Dynamic Island.
/// 
/// ## Usage Pattern
/// 
/// ```swift
/// // Start transcription and Live Activity
/// try await liveActivityManager.startActivity()
/// 
/// // Update with transcription progress (resets heartbeat)
/// await liveActivityManager.updateContentState { state in
///     var newState = state
///     newState.currentHypothesis = "Current transcription text..."
///     newState.audioSeconds = elapsedTime
///     return newState
/// }
/// 
/// // Handle app foregrounding (dismisses interrupted activities)
/// await liveActivityManager.handleAppEnteredForeground()
/// 
/// // Stop normally (cancels heartbeat)
/// await liveActivityManager.stopActivity()
/// ```
/// 
/// ## Thread Safety
/// 
/// All methods are marked `@MainActor` and must be called from the main thread to ensure
/// thread-safe access to ActivityKit APIs and internal state management.
@MainActor
final class LiveActivityManager: ObservableObject {
    private var currentActivity: Activity<TranscriptionAttributes>?
    private var bufferedContentState = TranscriptionAttributes.ContentState(
        currentHypothesis: "",
        audioSeconds: 0.0,
        isInterrupted: false
    )

    // Single identifier for the activity
    private static let activityAttributes = TranscriptionAttributes(sessionId: "stream-transcription")

    // Throttling to limit updates to once per second
    private var lastUpdateTime: TimeInterval = 0
    private var pendingUpdateTask: Task<Void, Never>?
    private var updateInterval = 1.0

    // Heartbeat to auto-dismiss stale streaming activities (model loading uses stale date instead)
    private var heartbeatTask: Task<Void, Never>?
    private let heartbeatTimeout: TimeInterval = 60.0

    // Tracks whether the current activity is for streaming or model loading.
    private enum ActivityMode { case none, streaming, modelLoading }
    private var activityMode: ActivityMode = .none

    // Last download percentage pushed to the widget; -1 = not yet set. Used to gate the
    // 1%-minimum step so Apple's widget-update budget isn't exhausted on fractional changes.
    private var lastReportedPercent: Int = -1
    private var lastReportedStateLabel: String?
    
    /// - Throws: any ActivityKit error from `Activity.request`. When the user has disabled Live
    ///   Activities at the system level (`areActivitiesEnabled == false`) the call returns
    ///   without throwing -- the user controls that setting and the caller shouldn't treat it
    ///   as an error.
    func startActivity() async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Logging.error("Live Activities are not enabled")
            return
        }
        
        // End any existing activities (current tracked one + any orphaned ones)
        if currentActivity != nil {
            await stopActivity(dismissalPolicy: .immediate)
        }
        
        // End any orphaned activities that might still be running
        await cleanupOrphanedActivities()
        
        let initialContentState = bufferedContentState
        
        do {
            let activity = try Activity.request(
                attributes: Self.activityAttributes,
                content: .init(state: initialContentState, staleDate: nextStaleDate())
            )
            
            currentActivity = activity
            activityMode = .streaming
            startHeartbeat()
            Logging.debug("Live activity started successfully: \(activity.id)")
        } catch {
            Logging.error("Failed to start live activity: \(error)")
            throw error
        }
    }
    
    /// Applies `updateBlock` to the buffered content state and schedules the result for delivery.
    /// Calls inside the throttle window coalesce: the latest state wins, so callers can fire
    /// updates per transcription tick without flooding ActivityKit.
    func updateContentState(updateBlock: (TranscriptionAttributes.ContentState) -> TranscriptionAttributes.ContentState) async {
        guard currentActivity != nil else { return }
        
        let oldState = bufferedContentState
        let newState = updateBlock(oldState)
        
        // Only proceed if state changed
        guard newState != oldState else { return }
        
        bufferedContentState = newState
        
        let now = Date().timeIntervalSince1970
        let timeSinceLastUpdate = now - lastUpdateTime
        
        // Reset heartbeat for streaming sessions only; model loading is governed by its stale date.
        if activityMode == .streaming { startHeartbeat() }
        
        // Throttle updates to maximum once per second. Coalesce by cancelling any prior
        // pending task -- the last call wins, so updates can't stack up under high frequency.
        if timeSinceLastUpdate >= updateInterval {
            pendingUpdateTask?.cancel()
            pendingUpdateTask = nil
            await performUpdate()
        } else {
            pendingUpdateTask?.cancel()
            let delaySeconds = updateInterval - timeSinceLastUpdate
            pendingUpdateTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.performUpdate()
            }
        }
    }

    private func performUpdate() async {
        guard let activity = currentActivity else { return }

        lastUpdateTime = Date().timeIntervalSince1970
        pendingUpdateTask = nil

        await activity.update(.init(state: bufferedContentState, staleDate: nextStaleDate()))
    }

    /// Stale-date sentinel synced to the heartbeat timeout -- iOS dims the activity if no
    /// update arrives by then, which matches when our heartbeat would have ended it anyway.
    private func nextStaleDate() -> Date {
        Date().addingTimeInterval(heartbeatTimeout)
    }
    
    func stopActivity(dismissalPolicy: ActivityUIDismissalPolicy = .default) async {
        guard let activity = currentActivity else {
            return
        }
        
        // Cancel heartbeat and any pending throttled update before stopping activity
        stopHeartbeat()
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil

        await activity.end(nil, dismissalPolicy: dismissalPolicy)
        bufferedContentState = .init(currentHypothesis: "", audioSeconds: 0, isInterrupted: false)
        currentActivity = nil
        activityMode = .none
    }
    
    var isActivityRunning: Bool {
        currentActivity != nil
    }

    /// Ends every `TranscriptionAttributes` activity the system has registered -- crash and
    /// force-quit leftovers included -- except the one this manager is driving, so it's safe
    /// to call at any time.
    func cleanupOrphanedActivities() async {
        for activity in Activity<TranscriptionAttributes>.activities where activity.id != currentActivity?.id {
            Logging.debug("Cleaning up orphaned activity: \(activity.id)")
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    
    // MARK: - Heartbeat Management

    private func startHeartbeat() {
        // Cancel existing heartbeat
        heartbeatTask?.cancel()
        
        // Start new heartbeat
        heartbeatTask = Task {
            do {
                try await Task.sleep(for: .seconds(heartbeatTimeout))
                // If we reach here, no updates were received for the timeout period
                await handleHeartbeatTimeout()
            } catch {
                // Task was cancelled (expected when updates are received)
            }
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
    
    /// Interrupted streaming activities survive the timeout so the user still sees the "session
    /// was cut off" indicator. Model-loading activities are never auto-dismissed by the heartbeat
    /// (they use a dedicated stale date instead).
    private func handleHeartbeatTimeout() async {
        guard currentActivity != nil, activityMode == .streaming else { return }

        if bufferedContentState.isInterrupted {
            Logging.debug("Live Activity heartbeat timeout - preserving interrupted activity for user notification")
            return
        }

        Logging.debug("Live Activity heartbeat timeout - auto-dismissing stale streaming activity")
        await stopActivity(dismissalPolicy: .immediate)
    }
    
    /// When the app comes back to the foreground we treat an interrupted streaming activity as
    /// acknowledged: the user is looking at the app, so the "session interrupted" banner has
    /// served its purpose and can be dismissed. Model-loading activities are left running.
    func handleAppEnteredForeground() async {
        await cleanupOrphanedActivities()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.cleanupOrphanedActivities()
        }
        guard activityMode == .streaming else { return }
        if bufferedContentState.isInterrupted {
            await stopActivity(dismissalPolicy: .immediate)
        }
    }

    // MARK: - Model loading progress

    /// Starts a Live Activity showing model download or initialization progress.
    /// No-ops when a streaming session is already running or Live Activities are disabled.
    func startModelLoadingActivity(progress: TranscriptionAttributes.ModelProgressState) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activityMode == .none else { return }
        // Claim the mode before the first await so a concurrent call can't start a second activity.
        activityMode = .modelLoading

        await cleanupOrphanedActivities()

        let initialState = TranscriptionAttributes.ContentState(
            currentHypothesis: "",
            audioSeconds: 0,
            isInterrupted: false,
            modelProgress: progress
        )
        bufferedContentState = initialState

        do {
            let activity = try Activity.request(
                attributes: Self.activityAttributes,
                // 10-minute stale window: large models on slow connections take several minutes.
                content: .init(state: initialState, staleDate: Date().addingTimeInterval(600))
            )
            currentActivity = activity
            lastReportedPercent = progress.progressPercent ?? -1
            lastReportedStateLabel = progress.stateLabel
            Logging.debug("[LiveActivity] Model loading activity started: \(progress.modelName) - \(progress.stateLabel)")
        } catch {
            activityMode = .none
            Logging.error("[LiveActivity] Failed to start model loading activity: \(error)")
        }
    }

    /// Stops the model loading Live Activity (no-op if none is running).
    func stopModelLoadingActivity() async {
        guard activityMode == .modelLoading else { return }
        await stopActivity(dismissalPolicy: .immediate)
        lastReportedPercent = -1
        lastReportedStateLabel = nil
    }

    /// Called whenever pipeline rows or session state changes. Starts, updates, or stops the
    /// model-loading Live Activity. Only runs when no streaming/transcription session is active.
    ///
    /// Updates are throttled to 1% steps for download progress; discrete state transitions
    /// (Specializing, Loading, etc.) always push immediately.
    func handleModelStateChange(pipelineRows: [ModelPipelineRow], isSessionActive: Bool) async {
        guard !isSessionActive else { return }

        // Transcription row takes priority; fall through to diarization row if transcription is idle.
        let candidate = pipelineRows.first { isActiveLoadingState($0.state) }

        if let row = candidate, let progress = modelProgressState(from: row) {
            // Throttle by percent only while the label is unchanged: a state flip at the
            // same percent (e.g. Downloading -> Paused at 42%) must still go through.
            if let pct = progress.progressPercent, activityMode == .modelLoading,
               progress.stateLabel == lastReportedStateLabel {
                guard abs(pct - lastReportedPercent) >= 1 else { return }
            }

            if activityMode == .none {
                await startModelLoadingActivity(progress: progress)
            } else if activityMode == .modelLoading {
                lastReportedPercent = progress.progressPercent ?? -1
                lastReportedStateLabel = progress.stateLabel
                await updateContentState { state in
                    var s = state
                    s.modelProgress = progress
                    return s
                }
            }
        } else if activityMode == .modelLoading {
            await stopModelLoadingActivity()
        }
    }

    private func isActiveLoadingState(_ state: PipelineState) -> Bool {
        switch state {
        case .downloading, .waitingForWifi, .paused, .verifying, .unverified, .specializing, .loading:
            return true
        case .notDownloaded, .downloaded, .loaded, .failed, .incomplete:
            return false
        }
    }

    private func modelProgressState(from row: ModelPipelineRow) -> TranscriptionAttributes.ModelProgressState? {
        switch row.state {
        case .downloading(let fraction, _, _):
            let pct = max(0, min(100, Int((fraction * 100).rounded())))
            return .init(stateLabel: "Downloading", modelName: row.modelName, progressPercent: pct)
        case .waitingForWifi:
            return .init(stateLabel: "Waiting for Wi-Fi", modelName: row.modelName, progressPercent: nil)
        case .paused(let fraction):
            let pct = max(0, min(100, Int((fraction * 100).rounded())))
            return .init(stateLabel: "Paused", modelName: row.modelName, progressPercent: pct)
        case .verifying, .unverified:
            return .init(stateLabel: "Verifying", modelName: row.modelName, progressPercent: nil)
        case .specializing:
            return .init(stateLabel: "Specializing", modelName: row.modelName, progressPercent: nil)
        case .loading:
            return .init(stateLabel: "Loading", modelName: row.modelName, progressPercent: nil)
        case .notDownloaded, .downloaded, .loaded, .failed, .incomplete:
            return nil
        }
    }


    deinit {
        heartbeatTask?.cancel()
        pendingUpdateTask?.cancel()
    }

}
#endif
