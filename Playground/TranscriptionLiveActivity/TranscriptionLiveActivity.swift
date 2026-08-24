import ActivityKit
import WidgetKit
import SwiftUI
#if os(iOS)
import AppIntents
#endif

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

/// Shared model-loading content used in both the lock screen and Dynamic Island.
struct ModelLoadingContentView: View {
    let state: TranscriptionAttributes.ModelProgressState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(.blue)
                    .font(.subheadline)
                Text(state.stateLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let pct = state.progressPercent {
                    Text("\(pct)%")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }
            }
            Text(state.modelName)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Percent-less phases (Specializing, Loading) show no bar: Live Activities render
            // static snapshots, so an indeterminate ProgressView would sit frozen.
            if let pct = state.progressPercent {
                ProgressView(value: Double(pct), total: 100.0)
                    .tint(.blue)
            }
        }
    }

    private var iconName: String { state.iconName }
}


struct TranscriptionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranscriptionAttributes.self) { context in
            // Lock screen/banner UI
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let mp = context.state.modelProgress {
                        HStack(spacing: 4) {
                            Image(systemName: mp.iconName)
                                .foregroundStyle(.blue)
                                .font(.caption2)
                            Text(mp.stateLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 8)
                    } else {
                        HStack {
                            RecordingIndicator(isInterrupted: context.state.isInterrupted)
                            Text(context.state.isInterrupted ? "Interrupted" : "Transcribing...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 8)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let mp = context.state.modelProgress {
                        if let pct = mp.progressPercent {
                            Text("\(pct)%")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.blue)
                                .padding(.trailing, 8)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text(formatDuration(context.state.audioSeconds))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                            if #available(iOS 17.0, *) {
                                Button(intent: StopTranscriptionIntent()) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.red)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Stop transcription")
                            }
                        }
                        .padding(.trailing, 8)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let mp = context.state.modelProgress {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mp.modelName)
                                .font(.caption)
                                .fontWeight(.medium)
                            if let pct = mp.progressPercent {
                                ProgressView(value: Double(pct), total: 100.0)
                                    .tint(.blue)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            if context.state.isInterrupted {
                                Text("Microphone session interrupted. Restart transcription from the app.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if !context.state.currentHypothesis.characters.isEmpty {
                                Text(context.state.currentHypothesis)
                                    .font(.caption)
                                    .lineLimit(3)
                                    .truncationMode(.head)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Listening...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 32, alignment: .topLeading)
                        .padding(.horizontal, 8)
                    }
                }
            } compactLeading: {
                if let mp = context.state.modelProgress {
                    Image(systemName: mp.iconName)
                        .foregroundStyle(.blue)
                        .font(.caption2)
                        .padding(.leading, 2)
                } else {
                    RecordingIndicator(isInterrupted: context.state.isInterrupted)
                }
            } compactTrailing: {
                if let mp = context.state.modelProgress {
                    if let pct = mp.progressPercent {
                        Text("\(pct)%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.blue)
                    }
                } else {
                    Text(formatDuration(context.state.audioSeconds))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            } minimal: {
                if context.state.modelProgress != nil {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption2)
                } else {
                    RecordingIndicator(isInterrupted: context.state.isInterrupted)
                }
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
        Group {
            if let mp = context.state.modelProgress {
                ModelLoadingContentView(state: mp)
                    .padding(16)
            } else {
                transcriptionView
                    .padding(16)
            }
        }
        .activityBackgroundTint(nil)
        .activitySystemActionForegroundColor(.primary)
    }

    private var transcriptionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    RecordingIndicator(isInterrupted: context.state.isInterrupted)
                    Text(context.state.isInterrupted ? "Interrupted" : "Transcribing...")
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                Spacer()
                if #available(iOS 17.0, *) {
                    Button(intent: StopTranscriptionIntent()) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop transcription")
                }
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
    }
}

#Preview("Live Activity", as: .content, using: TranscriptionAttributes.preview) {
    TranscriptionLiveActivity()
} contentStates: {
    TranscriptionAttributes.ContentState.sampleActive
    TranscriptionAttributes.ContentState.sampleListening
    TranscriptionAttributes.ContentState.sampleCompleted
    TranscriptionAttributes.ContentState.sampleInterrupted
    TranscriptionAttributes.ContentState.sampleModelDownloading
    TranscriptionAttributes.ContentState.sampleModelSpecializing
    TranscriptionAttributes.ContentState.sampleModelLoading
}

#Preview("Dynamic Island Compact", as: .dynamicIsland(.compact), using: TranscriptionAttributes.preview) {
    TranscriptionLiveActivity()
} contentStates: {
    TranscriptionAttributes.ContentState.sampleActive
    TranscriptionAttributes.ContentState.sampleModelDownloading
    TranscriptionAttributes.ContentState.sampleModelSpecializing
}

#Preview("Dynamic Island Expanded", as: .dynamicIsland(.expanded), using: TranscriptionAttributes.preview) {
    TranscriptionLiveActivity()
} contentStates: {
    TranscriptionAttributes.ContentState.sampleActive
    TranscriptionAttributes.ContentState.sampleListening
    TranscriptionAttributes.ContentState.sampleModelDownloading
    TranscriptionAttributes.ContentState.sampleModelLoading
}

#Preview("Dynamic Island Minimal", as: .dynamicIsland(.minimal), using: TranscriptionAttributes.preview) {
    TranscriptionLiveActivity()
} contentStates: {
    TranscriptionAttributes.ContentState.sampleActive
    TranscriptionAttributes.ContentState.sampleInterrupted
    TranscriptionAttributes.ContentState.sampleModelDownloading
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

    static var sampleModelDownloading: TranscriptionAttributes.ContentState {
        TranscriptionAttributes.ContentState(
            currentHypothesis: "",
            audioSeconds: 0,
            isInterrupted: false,
            modelProgress: .init(stateLabel: "Downloading", modelName: "Qwen3-ASR 1.7B", progressPercent: 42)
        )
    }

    static var sampleModelSpecializing: TranscriptionAttributes.ContentState {
        TranscriptionAttributes.ContentState(
            currentHypothesis: "",
            audioSeconds: 0,
            isInterrupted: false,
            modelProgress: .init(stateLabel: "Specializing", modelName: "Qwen3-ASR 1.7B", progressPercent: nil)
        )
    }

    static var sampleModelLoading: TranscriptionAttributes.ContentState {
        TranscriptionAttributes.ContentState(
            currentHypothesis: "",
            audioSeconds: 0,
            isInterrupted: false,
            modelProgress: .init(stateLabel: "Loading", modelName: "Sortformer Diarization", progressPercent: nil)
        )
    }
}
