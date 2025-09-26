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
/// - **Error Recovery:** Graceful handling of ActivityKit errors and edge cases
/// 
/// ## Heartbeat Protection
/// 
/// The manager implements a 60-second heartbeat timer that automatically terminates activities
/// that haven't received updates, preventing lingering notifications when:
/// - App crashes unexpectedly
/// - iOS terminates the app due to memory pressure
/// - Transcription pipeline hangs or stops unexpectedly
/// - Network connectivity issues prevent updates
/// 
/// The heartbeat resets on every content update, so active transcriptions remain visible indefinitely.
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
class LiveActivityManager: ObservableObject {
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
    private var pendingUpdate = false
    private var updateInterval = 1.0
    
    // Heartbeat to auto-dismiss stale activities
    private var heartbeatTask: Task<Void, Never>?
    private let heartbeatTimeout: TimeInterval = 60.0
    
    /// Starts a live activity for the current transcription session
    /// - Throws: ActivityKit errors if activity cannot be started
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
                content: .init(state: initialContentState, staleDate: nil)
            )
            
            currentActivity = activity
            startHeartbeat()
            Logging.error("Live activity started successfully: \(activity.id)")
        } catch {
            Logging.error("Failed to start live activity: \(error)")
            throw error
        }
    }
    
    /// Updates the buffered content state with throttling to limit to once per second, too frequent update to dynamic island will be throttled
    /// - Parameter updateBlock: Block that modifies the content state
    func updateContentState(updateBlock: (TranscriptionAttributes.ContentState) -> TranscriptionAttributes.ContentState) async {
        guard currentActivity != nil else { return }
        
        let oldState = bufferedContentState
        let newState = updateBlock(oldState)
        
        // Only proceed if state actually changed
        guard newState != oldState else { return }
        
        bufferedContentState = newState
        
        let now = Date().timeIntervalSince1970
        let timeSinceLastUpdate = now - lastUpdateTime
        
        // Reset heartbeat since we're receiving updates
        startHeartbeat()
        
        // Throttle updates to maximum once per second
        if timeSinceLastUpdate >= updateInterval {
            await performUpdate()
        } else if !pendingUpdate {
            // Schedule a delayed update
            pendingUpdate = true
            Task {
                try? await Task.sleep(nanoseconds: UInt64((updateInterval - timeSinceLastUpdate) * 1_000_000_000))
                if pendingUpdate {
                    await performUpdate()
                }
            }
        }
    }
    
    /// Performs the actual Live Activity update
    private func performUpdate() async {
        guard let activity = currentActivity else { return }
        
        lastUpdateTime = Date().timeIntervalSince1970
        pendingUpdate = false

        await activity.update(.init(state: bufferedContentState, staleDate: nil))
    }
    
    /// Stops the current live activity
    /// - Parameter dismissalPolicy: How to dismiss the activity
    func stopActivity(dismissalPolicy: ActivityUIDismissalPolicy = .default) async {
        guard let activity = currentActivity else {
            return
        }
        
        // Cancel heartbeat before stopping activity
        stopHeartbeat()
        
        await activity.end(nil, dismissalPolicy: .immediate)
        bufferedContentState = .init(currentHypothesis: "", audioSeconds: 0, isInterrupted: false)
        currentActivity = nil
    }
    
    /// Indicates whether a live activity is currently running
    var isActivityRunning: Bool {
        currentActivity != nil
    }
    
    /// Cleans up any orphaned activities on app launch
    /// Should be called during app initialization to clear stale activities
    func cleanupOrphanedActivities() async {
        // End any existing activities that might be left over from previous sessions
        for activity in Activity<TranscriptionAttributes>.activities {
            Logging.error("Cleaning up orphaned activity: \(activity.id)")
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    
    // MARK: - Heartbeat Management
    
    /// Starts or restarts the heartbeat timer to auto-dismiss stale activities
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
    
    /// Stops the heartbeat timer
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
    
    /// Handles heartbeat timeout by auto-dismissing the stale activity
    /// Interrupted activities are preserved to inform the user of the issue
    private func handleHeartbeatTimeout() async {
        guard currentActivity != nil else { return }
        
        // Don't auto-dismiss interrupted activities - let them persist for user awareness
        if bufferedContentState.isInterrupted {
            Logging.debug("Live Activity heartbeat timeout - preserving interrupted activity for user notification")
            return
        }
        
        Logging.error("Live Activity heartbeat timeout - auto-dismissing stale activity")
        await stopActivity(dismissalPolicy: .immediate)
    }
    
    /// Handles app entering foreground - dismisses interrupted activities since user has seen them
    func handleAppEnteredForeground() async {
        // If there's an interrupted activity, dismiss it since user has acknowledged it
        if currentActivity != nil && bufferedContentState.isInterrupted {
            await stopActivity(dismissalPolicy: .immediate)
        }
    }
    
    /// Cleanup when manager is deallocated
    deinit {
        heartbeatTask?.cancel()
    }
    
}
#endif
