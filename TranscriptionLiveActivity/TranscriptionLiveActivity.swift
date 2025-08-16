import ActivityKit
import WidgetKit
import SwiftUI

/// A simple indicator for voice activity - when there is voice, turn on the red indicator
struct VoiceActivityIndicator: View {
    let hasVoice: Bool
    var body: some View {
        Circle()
            .frame(width: 8, height: 8)
            .padding(.leading, 4)
            .foregroundStyle(hasVoice ? .red : .red.opacity(0.35))
            .animation(.easeInOut(duration: 0.1), value: hasVoice)
    }
}

struct TranscriptionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranscriptionAttributes.self) { context in
            // Lock screen/banner UI
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack {
                        VoiceActivityIndicator(hasVoice: context.state.hasVoice)
                        Text(context.state.isInterrupted ? "Interrupted" : "Transcribing...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 8)
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    Text(formatDuration(context.state.audioSeconds))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 8)
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if context.state.isInterrupted {
                            Text("Microphone session interrupted. Restart transcription from the app.\n")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(minHeight: 32, alignment: .topLeading)
                        } else if !context.state.currentHypothesis.isEmpty {
                            Text(context.state.currentHypothesis)
                                .font(.caption)
                                .lineLimit(nil)
                                .truncationMode(.head)
                                .frame(minHeight: 32, alignment: .topLeading)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Listening...\n")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(minHeight: 32, alignment: .topLeading)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                VoiceActivityIndicator(hasVoice: context.state.hasVoice)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                VoiceActivityIndicator(hasVoice: context.state.hasVoice)
            }
        }
    }
    
    /// Formats duration in seconds to MM:SS format
    /// - Parameter seconds: Duration in seconds
    /// - Returns: Formatted time string
    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

/// Lock screen live activity view component
///
/// Displays comprehensive transcription information optimized for lock screen presentation
/// including current hypothesis and transcription status.
struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<TranscriptionAttributes>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with Argmax branding
            HStack {
                HStack(spacing: 8) {
                    VoiceActivityIndicator(hasVoice: context.state.hasVoice)
                    Text(context.state.isInterrupted ? "Interrupted" : "Transcribing...")
                        .font(.headline)
                        .fontWeight(.medium)
                }
                
                Spacer()
            }
            if context.state.isInterrupted {
                Text("Microphone session interrupted. Restart transcription from the app.\n")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minHeight: 32, alignment: .topLeading)
            } else if !context.state.currentHypothesis.isEmpty {
                Text(context.state.currentHypothesis)
                    .font(.body)
                    .lineLimit(3)
                    .truncationMode(.head)
            } else {
                Text("Listening...")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview("Live Activity", as: .content, using: TranscriptionAttributes.preview) {
    TranscriptionLiveActivity()
} contentStates: {
    TranscriptionAttributes.ContentState.sampleActive
    TranscriptionAttributes.ContentState.sampleListening
    TranscriptionAttributes.ContentState.sampleCompleted
}

#Preview("Dynamic Island Compact", as: .dynamicIsland(.compact), using: TranscriptionAttributes.preview) {
    TranscriptionLiveActivity()
} contentStates: {
    TranscriptionAttributes.ContentState.sampleActive
}

#Preview("Dynamic Island Expanded", as: .dynamicIsland(.expanded), using: TranscriptionAttributes.preview) {
    TranscriptionLiveActivity()
} contentStates: {
    TranscriptionAttributes.ContentState.sampleActive
    TranscriptionAttributes.ContentState.sampleListening
}

// MARK: - Preview Data

extension TranscriptionAttributes {
    static var preview: TranscriptionAttributes {
        TranscriptionAttributes(
            sessionId: "preview-session-123"
        )
    }
}

extension TranscriptionAttributes.ContentState {
    static var sampleActive: TranscriptionAttributes.ContentState {
        TranscriptionAttributes.ContentState(
            currentHypothesis: "This is a sample transcription showing real-time voice recognition in progress.",
            hasVoice: true,
            audioSeconds: 45.2,
            isInterrupted: false
        )
    }
    
    static var sampleListening: TranscriptionAttributes.ContentState {
        TranscriptionAttributes.ContentState(
            currentHypothesis: "",
            hasVoice: false,
            audioSeconds: 12.1,
            isInterrupted: false
        )
    }
    
    static var sampleCompleted: TranscriptionAttributes.ContentState {
        TranscriptionAttributes.ContentState(
            currentHypothesis: "Transcription session completed successfully with final results.",
            hasVoice: false,
            audioSeconds: 120.0,
            isInterrupted: false
        )
    }
}
