/// Enumeration representing the available transcription modes for stream processing.
enum TranscriptionModeSelection: String, CaseIterable, Identifiable {
    case alwaysOn = "alwaysOn"
    case voiceTriggered = "voiceTriggered"
    case batteryOptimized = "batteryOptimized"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .alwaysOn:
            return "Always-On"
        case .voiceTriggered:
            return "Voice-Triggered"
        case .batteryOptimized:
            return "Battery-Optimized"
        }
    }
    
    var description: String {
        switch self {
        case .alwaysOn:
            return "Continuous real-time transcription with lowest latency. Uses more system resources."
        case .voiceTriggered:
            return "Processes only audio above energy threshold. Conserves battery while staying responsive."
        case .batteryOptimized:
            return "Intelligent streaming with dynamic optimizations for maximum battery life."
        }
    }
}
