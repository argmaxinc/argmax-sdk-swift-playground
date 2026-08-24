import Foundation

// MARK: - Pipeline role

/// Which model pipeline a row in the sidebar "Models" panel represents. Used as the internal
/// identifier for row lookups; downloads are attributed back to a role by their `repoId`.
enum DownloadRole: String, CaseIterable, Sendable {
    case transcription
    case diarization
    case customVocabulary
}

// MARK: - Pipeline state machine

/// Lifecycle of a model pipeline, from "not on disk" through "loaded in memory". The static
/// states (`.notDownloaded`, `.downloaded`, `.loaded`, `.failed`) are derived from the
/// filesystem and the loaded transcriber and diarizer; the transient ones (`.downloading`, `.waitingForWifi`,
/// `.paused`, `.specializing`, `.loading`) come from an active background download or a
/// `ModelState` callback during a load.
enum PipelineState: Equatable {
    case notDownloaded
    /// Actively downloading. `fraction` is 0...1; byte counts are the sum across the model's files.
    case downloading(fraction: Double, bytesDone: Int64, bytesTotal: Int64)
    /// Paused by the SDK because the active path violates a Wi-Fi-only restriction. Auto-resumes.
    case waitingForWifi
    /// Paused by the user (resumes only on an explicit resume action). `fraction` is 0...1.
    case paused(fraction: Double)
    /// On disk and complete, not loaded into memory.
    case downloaded
    /// Files exist on disk for this model, but we have no cache entry / live record to verify
    /// them against -- e.g. an upgrade from a prior SDK build that didn't write cache entries.
    /// We can't claim `.downloaded` (the bytes might not match upstream), and
    /// `.incomplete` would be a lie (we don't *know* anything is wrong). Tapping Load Models
    /// triggers a HEAD-pass verification that either heals the cache (-> `.downloaded`) or
    /// starts a fill-in download.
    case unverified
    /// Background HEAD-based verification is in flight for this row. Transient -- resolves to
    /// `.downloaded`, `.incomplete`, or back to `.unverified` (if HEAD couldn't reach upstream).
    case verifying
    /// Files are on disk but the model is incomplete (a prior download was interrupted). Needs
    /// to be deleted and re-downloaded before it can be used.
    case incomplete
    /// Downloaded; the Core ML model is compiling/specializing for the device (no fractional
    /// progress).
    case specializing
    /// Loading the specialized model into memory.
    case loading
    /// Loaded and ready to use.
    case loaded
    /// Failed (or cancelled), with a short message.
    case failed(String)
}

// MARK: - Pipeline row

/// One row in the sidebar "Models" panel -- one per pipeline the current configuration uses
/// (transcription always; diarization when a diarization model is selected; custom vocabulary
/// when enabled).
struct ModelPipelineRow: Identifiable, Equatable {
    let role: DownloadRole
    var id: DownloadRole { role }
    /// Pipeline label, e.g. "Transcription", "Diarization", "Custom Vocabulary".
    var pipelineName: String
    /// Human-readable variant, e.g. "Parakeet v2", "Sortformer".
    var modelName: String
    var iconName: String
    /// `true` when the user has the pipeline selected (transcription is always enabled;
    /// diarization when a model is picked; custom vocabulary when the toggle is on). Disabled
    /// rows still render (so the selector stays reachable) but skip status text, progress bar,
    /// and lifecycle controls.
    var isEnabled: Bool
    var state: PipelineState
    /// Total bytes on disk; `nil` until computed (computed lazily for `.downloaded`/`.loaded`).
    var sizeOnDisk: Int64?
    /// Folder to reveal in Finder (macOS); `nil` when the model isn't on disk.
    var folderURL: URL?
    /// The SDK download id while a background download is active; `nil` otherwise.
    var downloadId: String?
}

// MARK: - Pending cellular prompt

/// Captured when "Load Models" is tapped under a Wi-Fi-only restriction with no satisfying
/// path. The UI presents a "wait vs use cellular this time" prompt; resolving it kicks off the
/// load.
struct PendingCellularDecision: Equatable {
    let modelName: String
    let redownload: Bool
}
