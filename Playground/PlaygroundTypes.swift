import Foundation
import SwiftUI
import Argmax

// MARK: - SDK Type Extensions

extension SpeakerInfoStrategy {
    /// Each word is assigned its own speaker (subsegment with zero gap threshold).
    static var word: SpeakerInfoStrategy { .subsegment(betweenWordThreshold: 0.0) }

    static var allCases: [SpeakerInfoStrategy] {
        [.segment, .subsegment, .word]
    }

    var stringValue: String {
        switch self {
        case .segment: return "segment"
        case .subsegment(let t) where t == 0.0: return "word"
        case .subsegment: return "subsegment"
        @unknown default: return "subsegment"
        }
    }

    var displayName: String {
        switch self {
        case .segment: return "Segment"
        case .subsegment(let t) where t == 0.0: return "Word"
        case .subsegment: return "Subsegment"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Utility Extensions

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var set = Set<Element>()
        return filter { set.insert($0).inserted }
    }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let a, r, g, b: UInt64
        switch clean.count {
        case 3: (a, r, g, b) = (255, (value >> 8) * 17, (value >> 4 & 0xF) * 17, (value & 0xF) * 17)
        case 6: (a, r, g, b) = (255, value >> 16, value >> 8 & 0xFF, value & 0xFF)
        case 8: (a, r, g, b) = (value >> 24, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        default: (a, r, g, b) = (255, 255, 255, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Speaker Utilities

enum SpeakerUI {
    static let unknownColor = Color(red: 0.45, green: 0.44, blue: 0.40)
    private static let speakerColors: [Color] = [
        Color(red: 0.22, green: 0.21, blue: 0.85), // Blue
        Color(red: 0.66, green: 0.78, blue: 0.53), // Green
        Color(red: 0.87, green: 0.37, blue: 0.18), // Orange
        Color(red: 0.94, green: 0.76, blue: 0.28), // Yellow
    ]

    static func color(for speakerId: Int?) -> Color {
        guard let id = speakerId else { return unknownColor }
        return speakerColors[abs(id) % speakerColors.count]
    }

    static func label(for speakerId: Int?) -> String {
        guard let id = speakerId else { return "Unknown" }
        return "Speaker \(id)"
    }
}

// MARK: - Liquid Glass Button Styles

struct GlassProminentButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
    }
}

struct GlassSecondaryButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}

struct GlassBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isInteractive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            let glass: Glass = isInteractive ? .regular.interactive() : .regular
            content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

struct GlassControlBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(in: .rect(cornerRadius: 16))
        } else {
            content
        }
    }
}

extension View {
    func glassProminentButtonStyle() -> some View {
        modifier(GlassProminentButtonModifier())
    }

    func glassSecondaryButtonStyle() -> some View {
        modifier(GlassSecondaryButtonModifier())
    }

    func glassBackground(cornerRadius: CGFloat = 12, interactive: Bool = false) -> some View {
        modifier(GlassBackgroundModifier(cornerRadius: cornerRadius, isInteractive: interactive))
    }

    func glassControlBar() -> some View {
        modifier(GlassControlBarModifier())
    }

    @ViewBuilder
    func softScrollEdgeEffect(for edges: Edge.Set = .bottom) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}

// MARK: - Focus Mode

/// `true` while a tab view is presented inside the iOS focus-mode cover.
///
/// Focus mode puts the "Playground / by Argmax" label in the leading toolbar slot, and the tab's
/// own three-to-four trailing icons merge into that same bar and crowd it out on a narrow top bar.
/// Tab views read this to fold those icons into a single overflow menu instead.
private struct IsFocusModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isFocusMode: Bool {
        get { self[IsFocusModeKey.self] }
        set { self[IsFocusModeKey.self] = newValue }
    }
}

// MARK: - Constants

enum AudioConstants {
    #if os(macOS)
    static let energyHistoryLimit = 512
    #else
    static let energyHistoryLimit = 256
    #endif
}

// MARK: - Navigation

enum PlaygroundFeature: String, CaseIterable, Identifiable {
    case transcribe = "Pre-recorded"
    case stream = "Real-time"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcribe: return "book.pages"
        case .stream: return "waveform.badge.mic"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Tab Mode

enum TabMode: String, CaseIterable {
    case transcription = "Transcription"
    case diarize = "Speakers"
}

// MARK: - Diarization Mode

enum DiarizationMode: String, CaseIterable {
    case disabled = "Disabled"
    case concurrent = "Enabled: Concurrent"
    case sequential = "Enabled: Sequential"
}

// MARK: - Settings Snapshot

struct SettingsSnapshot: Equatable {
    let whisperKitModel: String
    let diarizationModel: String
    let sortformerMode: String
    let enableTimestamps: Bool
    let temperatureStart: Double
    let fallbackCount: Double
    let sampleLength: Double
    let silenceThreshold: Double
    let transcriptionMode: String
    let chunkingStrategy: String
    let concurrentWorkerCount: Double
    let encoderComputeUnits: String
    let decoderComputeUnits: String
    let diarizationMode: String
    let speakerInfoStrategy: String
    /// `nil` when the UI is set to "Auto"; the sentinel encoding stays in the persistence layer.
    /// SDK callers that need an int should branch on `nil` themselves.
    let minNumOfSpeakers: Int?
    let enableCustomVocabulary: Bool
    let customVocabularyWords: [String]

    var diffDescription: String {
        var parts: [String] = []
        // Drop the vendor prefix from underscored names ("openai_whisper-large-v3" ->
        // "whisper-large-v3"); names without one ("qwen3-asr") are already short.
        let components = whisperKitModel.components(separatedBy: "_")
        let modelShort = components.count > 1 ? components.dropFirst().joined(separator: " ") : whisperKitModel
        parts.append("Transcription: \(modelShort)")
        if diarizationModel != "none" {
            let diarizationDisplay = DiarizationModelSelection(rawValue: diarizationModel)?.displayName ?? diarizationModel
            parts.append("Diarization: \(diarizationDisplay)")
            if diarizationModel == DiarizationModelSelection.sortformer.rawValue {
                parts.append("Mode: \(sortformerMode)")
            }
        }
        if enableCustomVocabulary {
            if customVocabularyWords.isEmpty {
                parts.append("Custom Vocab: []")
            } else {
                parts.append("Custom Vocab: [\(customVocabularyWords.joined(separator: ", "))]")
            }
        }
        return parts.joined(separator: " | ")
    }
}

// MARK: - Session Record

enum SessionMode: String {
    case stream = "Real-time"
    case transcribeFile = "File"
    case transcribeRecord = "Record"
}

// MARK: - Stream Trace

struct StreamTraceEntry: Codable {
    let wallOffset: TimeInterval
    let confirmedText: String
    let hypothesisText: String
    let computeTime: TimeInterval?
    let specDecTokensPerStep: Double?
    let audioSeconds: TimeInterval?
    let runningRTF: Double?
}

struct StreamTrace: Codable {
    let model: String
    let startedAt: Date
    let entries: [StreamTraceEntry]

    /// Serializes a trace to a temp-directory JSON file and returns its URL (nil on failure).
    /// Shared by the stream and file/record transcription paths so every session can export
    /// a replay trace.
    static func write(model: String, startedAt: Date, entries: [StreamTraceEntry]) -> URL? {
        let trace = StreamTrace(model: model, startedAt: startedAt, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(trace) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace_\(UUID().uuidString).json")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// Reconstructs progressive trace entries from a finished result's segments, timing each
    /// entry to its segment's end (audio) time with cumulative confirmed text. Used by the
    /// file/record transcription paths, which produce a single final result rather than a live
    /// stream of hypothesis/confirmed updates.
    static func entries(fromSegments segments: [TranscriptionSegment]) -> [StreamTraceEntry] {
        var cumulative = ""
        return segments.map { segment in
            cumulative += segment.text
            return StreamTraceEntry(
                wallOffset: TimeInterval(segment.end),
                confirmedText: cumulative,
                hypothesisText: "",
                computeTime: nil,
                specDecTokensPerStep: nil,
                audioSeconds: TimeInterval(segment.end),
                runningRTF: nil
            )
        }
    }
}

struct SessionRecord: Identifiable {
    let id: UUID
    let timestamp: Date
    let mode: SessionMode
    let sourceDescription: String

    let settings: SettingsSnapshot

    var segments: [TranscriptionSegment]
    var speakerSegments: [SpeakerSegment]?
    var wordsWithSpeakers: [WordWithSpeaker]?
    var transcriptionTimings: TranscriptionTimings?
    var diarizationTimings: PyannoteDiarizationTimings?
    /// Stored as `Any?` to allow use on pre-macOS 15 / iOS 18 targets.
    /// Access via `streamingDiarizationTimings` on supported OS versions.
    var streamingDiarizationTimings: Any?
    var diarizationDurationMs: Double?

    var audioFileURL: URL?
    var traceFileURL: URL?
    var audioDuration: TimeInterval

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var displayTitle: String {
        let timeStr = Self.timeFormatter.string(from: timestamp)
        if mode == .transcribeFile {
            return "\(timeStr) - \(sourceDescription)"
        }
        if mode == .stream && sourceDescription != "Live Stream" && !sourceDescription.isEmpty {
            return "\(timeStr) - \(sourceDescription)"
        }
        return "\(timeStr) - \(mode.rawValue)"
    }

    var displayDuration: String {
        if audioDuration < 60 {
            return String(format: "%.1fs", audioDuration)
        }
        let mins = Int(audioDuration) / 60
        let secs = Int(audioDuration) % 60
        return "\(mins)m \(secs)s"
    }

    var speakerCount: Int? {
        guard let segments = speakerSegments, !segments.isEmpty else { return nil }
        let ids = segments.compactMap { $0.speaker.speakerId }
        return Set(ids).count
    }

    var displaySpeakerSegments: [DisplaySpeakerSegment] {
        if let segs = speakerSegments, !segs.isEmpty {
            return segs.map { seg in
                DisplaySpeakerSegment(
                    speakerId: seg.speaker.speakerId,
                    text: seg.text,
                    startTime: seg.speakerWords.first?.wordTiming.start ?? 0,
                    endTime: seg.speakerWords.last?.wordTiming.end ?? 0
                )
            }
        }
        if let words = wordsWithSpeakers, !words.isEmpty {
            return displaySegmentsFromWords(words)
        }
        return []
    }

    var hasSpeakerData: Bool {
        !displaySpeakerSegments.isEmpty
    }
}

// MARK: - Transcription Mode

enum TranscriptionModeSelection: String, CaseIterable, Identifiable {
    case alwaysOn = "alwaysOn"
    case voiceTriggered = "voiceTriggered"
    case batteryOptimized = "batteryOptimized"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysOn:
            return "Always On"
        case .voiceTriggered:
            return "Voice Triggered"
        case .batteryOptimized:
            return "Battery Optimized"
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

// MARK: - Type Aliases

/// Convenient alias used for mapping `WordTiming` values to their matching custom vocabulary hits.
typealias VocabularyResults = [WordTiming: [WordTiming]]

// MARK: - Formatting Helpers

func formatTimingRow(_ label: String, ms: Double, percentage: Double? = nil) -> String {
    if let pct = percentage {
        return String(format: "%-24s %8.2f ms  %5.1f%%", (label as NSString).utf8String!, ms, pct)
    }
    return String(format: "%-24s %8.2f ms", (label as NSString).utf8String!, ms)
}

func formatTimingSeconds(_ label: String, seconds: Double) -> String {
    return String(format: "%-24s %8.3f s", (label as NSString).utf8String!, seconds)
}

/// A lightweight speaker segment for display in session history,
/// grouping consecutive words from the same speaker. Exists because `SpeakerSegment.init`
/// is internal to the SDK -- once that initializer is made public, this struct + the
/// `wordsWithSpeakers` field on `SessionRecord` can be collapsed.
struct DisplaySpeakerSegment: Identifiable {
    let id = UUID()
    let speakerId: Int?
    let text: String
    let startTime: Float
    let endTime: Float
}

/// Groups consecutive `WordWithSpeaker` items by speaker ID for display.
func displaySegmentsFromWords(_ words: [WordWithSpeaker]) -> [DisplaySpeakerSegment] {
    guard !words.isEmpty else { return [] }

    var segments: [DisplaySpeakerSegment] = []
    var currentSpeaker: Int? = words[0].speaker
    var currentText = ""
    var startTime: Float = words[0].wordTiming.start
    var endTime: Float = words[0].wordTiming.end

    func flush() {
        guard !currentText.isEmpty else { return }
        segments.append(DisplaySpeakerSegment(
            speakerId: currentSpeaker,
            text: currentText.trimmingCharacters(in: .whitespaces),
            startTime: startTime,
            endTime: endTime
        ))
    }

    for w in words {
        if w.speaker != currentSpeaker {
            flush()
            currentSpeaker = w.speaker
            currentText = ""
            startTime = w.wordTiming.start
        }
        currentText += w.wordTiming.word
        endTime = w.wordTiming.end
    }
    flush()
    return segments
}
