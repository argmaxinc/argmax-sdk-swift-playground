#if os(iOS)
import ActivityKit
import Foundation

/// Defines the static attributes and dynamic state for transcription live activities
/// 
/// This struct provides the configuration for displaying real-time transcription status
/// when the app is running in background stream mode. Shows current transcription
/// hypothesis across different iOS presentation contexts including Dynamic Island, 
/// Lock Screen, and StandBy mode.
struct TranscriptionAttributes: ActivityAttributes {
    /// Static configuration that doesn't change during the live activity session
    public struct ContentState: Codable, Hashable {
        /// Current transcription hypothesis text being processed
        var currentHypothesis: String
        
        /// Whether voice is currently being detected above silence threshold
        var hasVoice: Bool
        
        /// Duration of audio processed in seconds
        var audioSeconds: Double
        
        /// Whether audio stream has been interrupted (no data received for >0.5s)
        var isInterrupted: Bool
    }
    
    /// Static identifier for the transcription session
    let sessionId: String
}
#endif
