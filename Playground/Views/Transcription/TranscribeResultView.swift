import Foundation
import SwiftUI
import Argmax

struct TranscribeResultView: View {
    @Binding var selectedMode: TabMode
    @Binding var isRecording: Bool

    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var transcribeViewModel: TranscribeViewModel
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var audioPlayer = AudioPlayer()

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Show waveform as soon as recording starts, even before the first energy callback.
            let energySamples: [Float] = transcribeViewModel.bufferEnergy.isEmpty && isRecording
                ? Array(repeating: 0, count: 50)
                : transcribeViewModel.bufferEnergy
            if !energySamples.isEmpty {
                WaveformView(
                    samples: energySamples,
                    silenceThreshold: Float(settings.silenceThreshold),
                    isActive: isRecording
                )
            }

            // Audio playback for file-based transcriptions. The .id() key forces the view
            // to recreate (and re-fire onAppear -> player.load) when the file path changes.
            if !isRecording, let pathString = transcribeViewModel.currentAudioPath {
                let audioURL = URL(fileURLWithPath: pathString)
                AudioPlaybackView(
                    audioURL: audioURL,
                    segments: transcribeViewModel.confirmedSegments,
                    player: audioPlayer
                )
                .id(pathString)
                .padding(.bottom, 4)
            }

            if isRecording {
                Text("Recording in progress... Transcription will appear after you stop.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            SessionInfoStrip(
                detectedLanguage: transcribeViewModel.detectedLanguage,
                sessionLanguages: transcribeViewModel.sessionLanguages,
                itnStatus: settings.itnStatus(detectedLanguage: transcribeViewModel.detectedLanguage,
                                              loadedITNEnabled: sdkCoordinator.loadedITNEnabled)
            )

            if selectedMode == .diarize && settings.diarizationMode == .disabled {
                ContentUnavailableView(
                    "Diarization Disabled",
                    systemImage: "person.2.slash",
                    description: Text("Enable diarization in Settings to identify speakers.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        segmentsContent()

                        // Decoder preview is isolated in DecoderPreviewLine which observes
                        // transcribeViewModel.decoderPreview (@Observable) directly, so only
                        // this one small view re-renders on every currentText tick -- not the
                        // full TranscribeResultView body with all speaker bubbles.
                        if settings.enableDecoderPreview {
                            DecoderPreviewLine(state: transcribeViewModel.decoderPreview)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .defaultScrollAnchor(.top)
                // Text selection triggers expensive layout recalculations during processing
                .conditionalTextSelection(!transcribeViewModel.isTranscribing && !transcribeViewModel.isDiarizing)
                .softScrollEdgeEffect()
                .padding()
            }
        }

        TranscriptionProgressBar()
    }

    // MARK: - Segment content

    @ViewBuilder
    private func segmentsContent() -> some View {
        let confirmedSegments = transcribeViewModel.confirmedSegments
        let unconfirmedSegments = transcribeViewModel.unconfirmedSegments
        let diarizedSpeakerSegments = transcribeViewModel.diarizedSpeakerSegments
        let customVocabularyResults = transcribeViewModel.customVocabularyResults
        let keywordHighlights = sdkCoordinator.currentCustomVocabularyWords
        let enableTimestamps = settings.enableTimestamps
        let showShortAudioToast = transcribeViewModel.showShortAudioToast
        let isSpeakerKitMissing = sdkCoordinator.speakerKit == nil
        let isPyannoteModel = sdkCoordinator.loadedDiarizationModel?.isPyannote == true
        let itnOn = settings.inverseTextNormalization

        // True when an audio file is loaded -- we show PlaybackWordHighlightRow so
        // word-level highlights can track player.currentTime without re-rendering the
        // whole list (only the individual row re-renders via @ObservedObject).
        let hasAudioFile = !isRecording && transcribeViewModel.currentAudioPath != nil

        if selectedMode == .transcription {
            ForEach(Array(confirmedSegments.enumerated()), id: \.element) { _, segment in
                if hasAudioFile, segment.words?.isEmpty == false {
                    PlaybackWordHighlightRow(
                        segment: segment,
                        enableTimestamps: enableTimestamps,
                        player: audioPlayer
                    )
                } else {
                    let timestampText = enableTimestamps
                        ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))] "
                        : ""
                    HighlightedTextView(
                        prefixText: timestampText,
                        segments: [segment],
                        customVocabularyResults: customVocabularyResults,
                        keywordHighlights: keywordHighlights,
                        itnHighlight: settings.inverseTextNormalization,
                        font: .headline.bold(),
                        foregroundColor: .primary
                    )
                    .equatable()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            ForEach(Array(unconfirmedSegments.enumerated()), id: \.element) { _, segment in
                let timestampText = enableTimestamps
                    ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))] "
                    : ""
                HighlightedTextView(
                    prefixText: timestampText,
                    segments: [segment],
                    customVocabularyResults: customVocabularyResults,
                    keywordHighlights: keywordHighlights,
                    itnHighlight: settings.inverseTextNormalization,
                    font: .headline.bold(),
                    foregroundColor: .gray
                )
                .equatable()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        } else if selectedMode == .diarize {
            if showShortAudioToast {
                HStack(alignment: .firstTextBaseline) {
                    let toastMessage: String = {
                        if isSpeakerKitMissing { return "SpeakerKit not loaded" }
                        if isPyannoteModel { return "Diarization works best with audio longer than 1 minute" }
                        return ""
                    }()
                    if !toastMessage.isEmpty {
                        ToastMessage(message: toastMessage)
                    }
                    if isSpeakerKitMissing {
                        Button {
                            sdkCoordinator.loadModel(settings.selectedModel, redownload: false, settings: settings)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.bottom, 8)
                .padding(.horizontal)
                .animation(.easeInOut, value: showShortAudioToast)
            }

            // Dimmed placeholder while diarization is running and speaker segments aren't ready yet.
            if diarizedSpeakerSegments.isEmpty && !confirmedSegments.isEmpty {
                ForEach(Array(confirmedSegments.enumerated()), id: \.offset) { _, segment in
                    Text(segment.text)
                        .font(.headline.bold())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
            }

            let groupBubbles = settings.groupSpeakerBubbles
            ForEach(makeSpeakerGroups(diarizedSpeakerSegments, grouped: groupBubbles), id: \.firstIndex) { group in
                HStack {
                    VStack(alignment: .leading) {
                        Text(transcribeViewModel.speakerDisplayName(speakerId: group.speakerId ?? -1))
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(transcribeViewModel.messageChainTimestamp(currentIndex: group.firstIndex))
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        DiarizedSpeakerBubble(
                            segments: group.diarizedSegments,
                            customVocabularyResults: customVocabularyResults,
                            keywordHighlights: keywordHighlights,
                            itnHighlight: itnOn,
                            backgroundColor: SpeakerUI.color(for: group.speakerId),
                            startTime: group.startTime,
                            endTime: group.endTime,
                            speakerId: group.speakerId,
                            onRenameSpeaker: { transcribeViewModel.requestSpeakerRename(speakerId: $0) }
                        )
                        .equatable()
                    }
                    Spacer()
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Speaker group helpers

/// Flat representation of one speaker bubble (may span multiple source segments when grouped).
private struct SpeakerGroup {
    let firstIndex: Int
    let speakerId: Int?
    let diarizedSegments: [TranscriptionSegment]
    let startTime: Float
    let endTime: Float
}

/// Converts `SpeakerSegment` array into display groups.
/// When `grouped` is false each segment becomes its own group (original behaviour).
/// When `grouped` is true consecutive segments from the same speaker are merged.
private func makeSpeakerGroups(_ segments: [SpeakerSegment], grouped: Bool) -> [SpeakerGroup] {
    guard !segments.isEmpty else { return [] }
    if !grouped {
        return segments.enumerated().map { (idx, seg) in
            let words = seg.speakerWords.map(\.wordTiming)
            return SpeakerGroup(
                firstIndex: idx,
                speakerId: seg.speaker.speakerId,
                diarizedSegments: [TranscriptionSegment(text: seg.text, words: words.isEmpty ? nil : words)],
                startTime: seg.speakerWords.first?.wordTiming.start ?? 0,
                endTime: seg.speakerWords.last?.wordTiming.end ?? 0
            )
        }
    }
    var groups: [SpeakerGroup] = []
    var i = 0
    while i < segments.count {
        let speakerId = segments[i].speaker.speakerId
        var j = i
        while j < segments.count && segments[j].speaker.speakerId == speakerId { j += 1 }
        let slice = Array(segments[i..<j])
        let txSegs = slice.map { seg -> TranscriptionSegment in
            let words = seg.speakerWords.map(\.wordTiming)
            return TranscriptionSegment(text: seg.text, words: words.isEmpty ? nil : words)
        }
        groups.append(SpeakerGroup(
            firstIndex: i,
            speakerId: speakerId,
            diarizedSegments: txSegs,
            startTime: slice.first?.speakerWords.first?.wordTiming.start ?? 0,
            endTime: slice.last?.speakerWords.last?.wordTiming.end ?? 0
        ))
        i = j
    }
    return groups
}

// MARK: - Playback word-highlight row

/// Replaces HighlightedTextView for file-based sessions when word timing data is available.
/// Uses @ObservedObject on AudioPlayer so only this row re-renders on each 50ms timer tick
/// rather than the entire segment list.
private struct PlaybackWordHighlightRow: View {
    let segment: TranscriptionSegment
    let enableTimestamps: Bool
    @ObservedObject var player: AudioPlayer

    private var activeWordIndex: Int? {
        guard (player.isPlaying || player.currentTime > 0),
              let words = segment.words, !words.isEmpty else { return nil }
        let t = Float(player.currentTime)
        return words.firstIndex { t >= $0.start && t < $0.end }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if enableTimestamps {
                Text("[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))]")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let words = segment.words, !words.isEmpty {
                Text(wordHighlightedText(words))
                    .font(.headline.bold())
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(segment.text)
                    .font(.headline.bold())
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            player.seek(to: TimeInterval(segment.start))
            if !player.isPlaying { player.play() }
        }
    }

    private func wordHighlightedText(_ words: [WordTiming]) -> AttributedString {
        var result = AttributedString()
        let idx = activeWordIndex
        for (i, word) in words.enumerated() {
            var chunk = AttributedString(word.word)
            if i == idx {
                chunk.foregroundColor = .accentColor
                chunk.font = Font.headline.bold()
            }
            result += chunk
        }
        return result
    }
}

// MARK: - Progress bar

/// Status bar shown while transcription or diarization is active.
/// Isolated via @Observable pipelineProgress so updates don't invalidate TranscribeResultView.
private struct TranscriptionProgressBar: View {
    @EnvironmentObject private var transcribeViewModel: TranscribeViewModel

    var body: some View {
        let isTranscribing = transcribeViewModel.isTranscribing
        let isDiarizing = transcribeViewModel.isDiarizing

        if isTranscribing || isDiarizing {
            let label =
                isTranscribing && isDiarizing ? "Running transcription and diarization..." :
                isTranscribing ? "Running transcription..." :
                "Running diarization..."

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let pct: Int =
                        if isTranscribing && isDiarizing {
                            ((transcribeViewModel.pipelineProgress.transcription ?? 0) +
                             (transcribeViewModel.pipelineProgress.diarization ?? 0)) / 2
                        } else if isTranscribing {
                            transcribeViewModel.pipelineProgress.transcription ?? 0
                        } else {
                            transcribeViewModel.pipelineProgress.diarization ?? 0
                        }
                    ProgressView(value: Double(pct), total: 100)
                        .progressViewStyle(.linear)
                }

                if transcribeViewModel.hasActiveTranscriptionTask {
                    Button {
                        transcribeViewModel.cancelTranscription()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
    }
}

// MARK: - Decoder preview

/// Isolated view that subscribes only to DecoderPreviewText (@Observable),
/// so currentText changes don't invalidate the parent body.
private struct DecoderPreviewLine: View {
    let state: DecoderPreviewText

    var body: some View {
        Text(state.value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Speaker bubble

/// Equatable speaker bubble so contextMenu/gesture modifiers aren't re-registered
/// on every parent body run.
private struct DiarizedSpeakerBubble: View, Equatable {
    let segments: [TranscriptionSegment]
    let customVocabularyResults: VocabularyResults
    let keywordHighlights: [String]
    let itnHighlight: Bool
    let backgroundColor: Color
    let startTime: Float
    let endTime: Float
    let speakerId: Int?
    let onRenameSpeaker: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segments == rhs.segments &&
        lhs.customVocabularyResults == rhs.customVocabularyResults &&
        lhs.keywordHighlights == rhs.keywordHighlights &&
        lhs.itnHighlight == rhs.itnHighlight &&
        lhs.backgroundColor == rhs.backgroundColor &&
        lhs.startTime == rhs.startTime &&
        lhs.endTime == rhs.endTime &&
        lhs.speakerId == rhs.speakerId
        // onRenameSpeaker excluded: stable method reference from the ViewModel
    }

    var body: some View {
        HighlightedTextView(
            segments: segments,
            customVocabularyResults: customVocabularyResults,
            keywordHighlights: keywordHighlights,
            itnHighlight: itnHighlight,
            font: .headline,
            foregroundColor: .white
        )
        .equatable()
        .padding(10)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .multilineTextAlignment(.leading)
        .contextMenu {
            Button(action: { onRenameSpeaker(speakerId ?? -1) }) {
                Label("Rename Speaker", systemImage: "pencil")
            }
            Text("[\(String(format: "%.2f", startTime)) -> \(String(format: "%.2f", endTime))]")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Qwen Dictation Result View

/// Shown instead of TranscribeResultView during Qwen dictation. Renders fast and exact
/// final results as they arrive, with latency relative to the recording stop gesture.
struct QwenDictationResultView: View {
    let isRecording: Bool

    @EnvironmentObject private var transcribeViewModel: TranscribeViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let energySamples: [Float] = transcribeViewModel.bufferEnergy.isEmpty && isRecording
                ? Array(repeating: 0, count: 50)
                : transcribeViewModel.bufferEnergy
            if !energySamples.isEmpty {
                WaveformView(
                    samples: energySamples,
                    silenceThreshold: Float(settings.silenceThreshold),
                    isActive: isRecording
                )
            }

            let metrics = transcribeViewModel.qwenMetrics
            let audioSeconds = metrics?.audioSeconds

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if transcribeViewModel.dictationFastFinalText == nil && isRecording {
                        Text("Listening...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let text = transcribeViewModel.dictationFastFinalText {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Label("Hypothesis", systemImage: "waveform")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                if let audio = audioSeconds,
                                   let ffa = metrics?.timelineFastFinalApp {
                                    Text(hypothesisLatencyLabel(delta: ffa - audio))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(text)
                                .font(.headline)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if let text = transcribeViewModel.dictationExactFinalText {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Label("Exact final", systemImage: "checkmark.seal.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                                if let label = exactFinalLatencyLabel(metrics: metrics) {
                                    Text(label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(text)
                                .font(.headline)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func hypothesisLatencyLabel(delta: Double) -> String {
        if delta < 0 {
            return "(\(String(format: "%.2f", -delta))s before stop)"
        } else {
            return "(+\(String(format: "%.2f", delta))s after stop)"
        }
    }

    private func exactFinalLatencyLabel(metrics: QwenStreamMetrics?) -> String? {
        guard let metrics else { return nil }
        let latency = metrics.exactFinalSeconds ?? 0
        if metrics.fastFinalSeconds != nil {
            // Auto-prewarm was consumed: finish() returned from cache (near-instant).
            let ms = Int(latency * 1000)
            return "Finalized during trailing silence · finish: ~\(ms)ms"
        }
        // Cold decode: finish() ran the full decode after the stop gesture.
        return "+\(String(format: "%.2f", latency))s after stop (cold decode)"
    }
}

// MARK: - Preview

#Preview("TranscribeResultView Sample") {
    let sdkCoordinator = ArgmaxSDKCoordinator(
        keyProvider: ObfuscatedKeyProvider(mask: 12)
    )
    let settings = AppSettings()
    let transcribeViewModel = TranscribeViewModel(sdkCoordinator: sdkCoordinator, settings: settings)

    TranscribeResultView(
        selectedMode: .constant(.transcription),
        isRecording: .constant(false)
    )
    .environmentObject(sdkCoordinator)
    .environmentObject(transcribeViewModel)
    .environmentObject(settings)
    .frame(height: 400)
    .padding()
    .onAppear {
        let quickWord = WordTiming(word: "quick", tokens: [], start: 0.0, end: 0.3, probability: 0.95)
        let sampleWord = WordTiming(word: "sample", tokens: [], start: 2.5, end: 2.9, probability: 0.92)
        let foxWord = WordTiming(word: "fox", tokens: [], start: 0.3, end: 0.4, probability: 0.9)
        transcribeViewModel.customVocabularyResults = [
            quickWord: [quickWord],
            sampleWord: [sampleWord],
            foxWord: [foxWord]
        ]
        transcribeViewModel.confirmedSegments = [
            TranscriptionSegment(
                id: 0,
                start: 0.0,
                end: 2.5,
                text: "The quick brown fox jumps over the lazy dog.",
                words: [
                    WordTiming(word: "The", tokens: [], start: 0.0, end: 0.05, probability: 0.9),
                    quickWord,
                    WordTiming(word: "brown", tokens: [], start: 0.1, end: 0.15, probability: 0.9),
                    foxWord
                ]
            ),
            TranscriptionSegment(
                id: 1,
                start: 2.5,
                end: 5.0,
                text: "This is a sample transcription for preview purposes.",
                words: [
                    WordTiming(word: "This", tokens: [], start: 0.0, end: 0.05, probability: 0.9),
                    WordTiming(word: "is", tokens: [], start: 0.05, end: 0.1, probability: 0.9),
                    WordTiming(word: "a", tokens: [], start: 0.1, end: 0.12, probability: 0.9),
                    sampleWord
                ]
            )
        ]
        transcribeViewModel.unconfirmedSegments = [
            TranscriptionSegment(
                id: 2,
                start: 5.0,
                end: 7.5,
                text: "This text appears in gray as unconfirmed.",
                words: [
                    WordTiming(word: "This", tokens: [], start: 0.0, end: 0.05, probability: 0.9),
                    WordTiming(word: "text", tokens: [], start: 0.05, end: 0.1, probability: 0.9),
                    WordTiming(word: "appears", tokens: [], start: 0.1, end: 0.2, probability: 0.9)
                ]
            )
        ]
        transcribeViewModel.currentText = "Currently processing more text..."
        transcribeViewModel.bufferEnergy = (0..<200).map { _ in Float.random(in: 0...1) }
    }
}

// MARK: - View Helpers

private extension View {
    /// Conditionally enables or disables text selection (ternary doesn't compile
    /// because .enabled and .disabled are different concrete types).
    @ViewBuilder
    func conditionalTextSelection(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}

// MARK: - Session Info Strip

/// Compact horizontal strip showing detected language and ITN status.
/// Placed at the top of both TranscribeResultView and StreamResultView.
struct SessionInfoStrip: View {
    let detectedLanguage: String?
    let sessionLanguages: [String]
    let itnStatus: AppSettings.ITNStatus

    private var displayLanguage: String? {
        guard let l = detectedLanguage, !l.isEmpty, l != "auto" else { return nil }
        return l
    }

    private var itnLabel: String? {
        switch itnStatus {
        case .inactive: nil
        case .active: "ITN"
        case .unsupportedLanguage: "ITN unavailable"
        case .reloadRequired: "ITN: reload model"
        }
    }

    var body: some View {
        if displayLanguage != nil || itnLabel != nil {
            HStack(spacing: 6) {
                if let lang = displayLanguage {
                    infoChip(lang.capitalized, systemImage: "globe")
                    if sessionLanguages.count > 1 {
                        let allLanguages = sessionLanguages.map { $0.capitalized }.joined(separator: " · ")
                        Text("+\(sessionLanguages.count - 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Session languages: \(allLanguages)")
                    }
                }
                if let itn = itnLabel {
                    infoChip(itn, systemImage: "textformat.123")
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func infoChip(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}
