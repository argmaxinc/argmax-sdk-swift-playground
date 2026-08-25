#if os(iOS)
import ActivityKit
import Foundation

/// Static configuration that doesn't change during a transcription Live Activity session.
///
/// In ActivityKit, the outer `ActivityAttributes` type holds *static* configuration (set once
/// at request time, never updated), and the nested `ContentState` carries the *dynamic* state
/// that updates over the activity's lifetime. This file follows that contract.
///
/// Drives the Dynamic Island, Lock Screen, and StandBy presentations while the app is
/// streaming in the background.
struct TranscriptionAttributes: ActivityAttributes {
    /// Progress state for the idle/model-loading widget presentation. Non-nil when the
    /// widget should show download or initialization status instead of transcription UI.
    struct ModelProgressState: Codable, Hashable {
        /// Short status label, e.g. "Downloading", "Specializing", "Loading".
        var stateLabel: String
        /// Pretty model name, e.g. "Qwen3-ASR 1.7B", "Parakeet v2".
        var modelName: String
        /// 0–100 for download/paused states; nil for non-fractional transitions.
        var progressPercent: Int?

        /// SF Symbol for the current phase, shared by every Live Activity region so the
        /// lock screen and Dynamic Island never disagree on the icon.
        var iconName: String {
            switch stateLabel {
            case "Waiting for Wi-Fi": return "wifi.slash"
            case "Paused":            return "pause.circle.fill"
            case "Verifying":         return "checkmark.shield.fill"
            case "Specializing", "Loading": return "cpu.fill"
            default:                  return "arrow.down.circle.fill"
            }
        }
    }

    /// Dynamic state -- updated via `Activity.update(_:)` whenever the transcription
    /// hypothesis, audio duration, interruption flag, or model-loading progress changes.
    public struct ContentState: Codable, Hashable {
        /// Current transcription hypothesis text being processed
        var currentHypothesis: AttributedString
        /// Duration of audio processed in seconds
        var audioSeconds: Double
        /// Whether audio stream has been interrupted (no data received for >0.5s)
        var isInterrupted: Bool
        /// Non-nil when the widget is in model-loading mode instead of transcription mode.
        var modelProgress: ModelProgressState?

        init(
            currentHypothesis: AttributedString,
            audioSeconds: Double,
            isInterrupted: Bool,
            modelProgress: ModelProgressState? = nil
        ) {
            self.currentHypothesis = currentHypothesis
            self.audioSeconds = audioSeconds
            self.isInterrupted = isInterrupted
            self.modelProgress = modelProgress
        }
    }

    /// Static identifier for the transcription session
    let sessionId: String
}
#endif
