import ActivityKit
import WidgetKit
import SwiftUI

/// A static indicator showing transcription status - bright when active, dim when interrupted
struct RecordingIndicator: View {
    let isInterrupted: Bool
    
    var body: some View {
        Circle()
            .frame(width: 8, height: 8)
            .padding(.leading, 4)
            .foregroundStyle(isInterrupted ? .red.opacity(0.35) : .red)
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
                        RecordingIndicator(isInterrupted: context.state.isInterrupted)
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
                        } else if !context.state.currentHypothesis.characters.isEmpty {
                            Text(context.state.currentHypothesis)
                                .font(.caption)
                                .lineLimit(3)
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
                RecordingIndicator(isInterrupted: context.state.isInterrupted)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                RecordingIndicator(isInterrupted: context.state.isInterrupted)
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
                    RecordingIndicator(isInterrupted: context.state.isInterrupted)
                    Text(context.state.isInterrupted ? "Interrupted" : "Transcribing...")
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                
                Spacer()
            }
            if context.state.isInterrupted {
                Text("Microphone session interrupted. Restart transcription from the app.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if !context.state.currentHypothesis.characters.isEmpty {
                Text(context.state.currentHypothesis)
                    .font(.subheadline)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .foregroundColor(.primary)
            } else {
                Text("Listening...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground).opacity(0.9))
        )
    }
}

#Preview("Live Activity", as: .content, using: TranscriptionAttributes.preview) {
    TranscriptionLiveActivity()
} contentStates: {
    TranscriptionAttributes.ContentState.sampleActive
    TranscriptionAttributes.ContentState.sampleListening
    TranscriptionAttributes.ContentState.sampleCompleted
    TranscriptionAttributes.ContentState.sampleInterrupted
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
            audioSeconds: 45.2,
            isInterrupted: false
        )
    }
    
    static var sampleListening: TranscriptionAttributes.ContentState {
        TranscriptionAttributes.ContentState(
            currentHypothesis: "",
            audioSeconds: 12.1,
            isInterrupted: false
        )
    }
    
    static var sampleCompleted: TranscriptionAttributes.ContentState {
        TranscriptionAttributes.ContentState(
            currentHypothesis: "Transcription session completed successfully with final results.",
            audioSeconds: 120.0,
            isInterrupted: false
        )
    }
    
    static var sampleInterrupted: TranscriptionAttributes.ContentState {
        TranscriptionAttributes.ContentState(
            currentHypothesis: "",
            audioSeconds: 120.0,
            isInterrupted: true
        )
    }
}
