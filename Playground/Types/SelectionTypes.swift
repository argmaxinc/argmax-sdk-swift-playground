import Foundation
import Argmax

// MARK: - Sortformer mode

/// User-facing selection for Sortformer streaming mode. Resolves to the SDK's
/// `SortformerStreamingConfig` (when targeting macOS 15 / iOS 18+) via `config(isRealtimeMode:)`.
enum SortformerModeSelection: String, Sendable {
    case automatic = "automatic"
    case realtime = "real-time"
    case prerecorded = "pre-recorded"

    /// Resolves the effective SDK config. `automatic` is resolved by the caller based on context.
    @available(macOS 15, iOS 18, *)
    public func config(isRealtimeMode: Bool) -> SortformerStreamingConfig {
        switch self {
        case .automatic:
            return isRealtimeMode ? .realtime : .prerecorded
        case .realtime: return .realtime
        case .prerecorded: return .prerecorded
        }
    }

    /// Human-readable label with "(auto)" suffix when the mode is automatically resolved.
    public func displayLabel(isStream: Bool) -> String {
        switch self {
        case .automatic: return isStream ? "Real-time (auto)" : "Pre-recorded (auto)"
        case .realtime: return "Real-time"
        case .prerecorded: return "Pre-recorded"
        }
    }
}

// MARK: - Custom-vocabulary CTC variant

/// User-facing selection for the CTC custom-vocabulary model variant.
///
/// The SDK's `CustomVocabularyCoordinator` picks canary vs parakeet at load time based on the
/// loaded CTC model's mel count (128 -> canary, 80 -> parakeet); this picker controls which
/// variant the playground downloads and hands to the SDK. Both variants live in the same
/// `argmaxinc/ctckit-pro` repo.
enum CustomVocabularyModelSelection: String, CaseIterable, Sendable {
    case canary = "canary"
    case parakeet = "parakeet"

    public var displayName: String {
        switch self {
        case .canary: return "Canary"
        case .parakeet: return "Parakeet"
        }
    }

    /// HuggingFace variant id under `argmaxinc/ctckit-pro`.
    public var variant: String {
        switch self {
        case .canary: return "canary-1b-v2_474MB"
        case .parakeet: return "parakeet-tdt_ctc-110m"
        }
    }

    public var modelRepo: String { "argmaxinc/ctckit-pro" }
}

// MARK: - Diarization model

/// User-facing selection for the diarization pipeline (speaker labeling).
enum DiarizationModelSelection: String, CaseIterable, Sendable {
    case pyannote4 = "pyannote4"
    case sortformer = "sortformer"

    public var displayName: String {
        switch self {
        case .pyannote4: return "Pyannote v4"
        case .sortformer: return "Sortformer"
        }
    }

    public var isSortformer: Bool {
        self == .sortformer
    }

    public var isPyannote: Bool {
        self == .pyannote4
    }

    /// The HuggingFace repository for this model.
    public var modelRepo: String {
        switch self {
        case .pyannote4: return "argmaxinc/speakerkit-coreml"
        case .sortformer: return "argmaxinc/speakerkit-pro"
        }
    }
}
