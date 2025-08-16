#if os(iOS)
import ActivityKit
import Foundation
import Argmax

/// Manages live activity lifecycle for transcription sessions
/// 
/// Handles starting, updating, and stopping live activities when the app enters
/// background mode during stream transcription. Integrates with the transcription
/// pipeline to provide real-time status updates across iOS presentation contexts.
/// 
/// Key responsibilities:
/// - Activity lifecycle management (start/stop/update)
/// - Background/foreground state coordination
/// - Real-time content state updates
/// - Error handling and cleanup
@MainActor
class LiveActivityManager: ObservableObject {
    private var currentActivity: Activity<TranscriptionAttributes>?
    private var isAppInBackground = false
    private var bufferedContentState = TranscriptionAttributes.ContentState(
        currentHypothesis: "",
        hasVoice: false,
        audioSeconds: 0.0,
        isInterrupted: true
    )
    
    // Throttling to limit updates to once per second
    private var lastUpdateTime: TimeInterval = 0
    private var pendingUpdate = false
    
    /// Starts a live activity for the current transcription session
    /// - Parameters:
    ///   - sessionId: Unique identifier for the transcription session
    /// - Throws: ActivityKit errors if activity cannot be started
    func startActivity(sessionId: String) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Logging.error("Live Activities are not enabled")
            return
        }
        
        guard currentActivity == nil else {
            Logging.error("Live activity already running")
            return
        }
        
        let attributes = TranscriptionAttributes(
            sessionId: sessionId
        )
        
        let initialContentState = TranscriptionAttributes.ContentState(
            currentHypothesis: "",
            hasVoice: false,
            audioSeconds: 0.0,
            isInterrupted: true
        )
        bufferedContentState = initialContentState
        
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: nil)
            )
            
            currentActivity = activity
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
        guard newState != bufferedContentState else { return }
        
        bufferedContentState = newState
        
        let now = Date().timeIntervalSince1970
        let timeSinceLastUpdate = now - lastUpdateTime
        
        // Throttle updates to maximum once per second
        if timeSinceLastUpdate >= 1.0 {
            await performUpdate()
        } else if !pendingUpdate {
            // Schedule a delayed update
            pendingUpdate = true
            Task {
                try? await Task.sleep(nanoseconds: UInt64((1.0 - timeSinceLastUpdate) * 1_000_000_000))
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
        
        await activity.end(nil, dismissalPolicy: .immediate)
        currentActivity = nil
    }
    
    /// Indicates whether a live activity is currently running
    var isActivityRunning: Bool {
        currentActivity != nil
    }
    
    /// Handles app entering background state
    /// Should be called when app backgrounding is detected
    func appDidEnterBackground() {
        isAppInBackground = true
    }
    
    /// Handles app entering foreground state
    /// Should be called when app foregrounding is detected
    func appDidEnterForeground() {
        isAppInBackground = false
    }
}
#endif
