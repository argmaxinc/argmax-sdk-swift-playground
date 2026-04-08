import Foundation
import SwiftUI
import Argmax

struct TranscribeResultView: View {
    @Binding var selectedMode: TabMode
    @Binding var isRecording: Bool

    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var transcribeViewModel: TranscribeViewModel
    @EnvironmentObject private var settings: AppSettings

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !transcribeViewModel.bufferEnergy.isEmpty {
                WaveformView(
                    samples: transcribeViewModel.bufferEnergy,
                    silenceThreshold: Float(settings.silenceThreshold),
                    isActive: isRecording
                )
            }

            if isRecording && transcribeViewModel.isTranscribing {
                Text("🎙️ Recording in progress... Transcription will appear after you stop recording. For real-time results, switch to Stream mode.")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

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
                        // this one small view re-renders on every currentText tick — not the
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
        let enableTimestamps = settings.enableTimestamps
        let showShortAudioToast = transcribeViewModel.showShortAudioToast
        let isSpeakerKitMissing = sdkCoordinator.speakerKit == nil
        let isPyannoteModel = sdkCoordinator.loadedDiarizationModel?.isPyannote == true

        if selectedMode == .transcription {
            ForEach(Array(confirmedSegments.enumerated()), id: \.element) { _, segment in
                let timestampText = enableTimestamps
                    ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))] "
                    : ""
                HighlightedTextView(
                    prefixText: timestampText,
                    segments: [segment],
                    customVocabularyResults: customVocabularyResults,
                    font: .headline.bold(),
                    foregroundColor: .primary
                )
                .equatable()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(Array(unconfirmedSegments.enumerated()), id: \.element) { _, segment in
                let timestampText = enableTimestamps
                    ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))] "
                    : ""
                HighlightedTextView(
                    prefixText: timestampText,
                    segments: [segment],
                    customVocabularyResults: customVocabularyResults,
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

            ForEach(Array(diarizedSpeakerSegments.enumerated()), id: \.element.id) { index, segment in
                let words = segment.speakerWords.map(\.wordTiming)
                let diarizedSegments = [TranscriptionSegment(text: segment.text, words: words.isEmpty ? nil : words)]
                HStack {
                    VStack(alignment: .leading) {
                        if index == 0 || diarizedSpeakerSegments[index - 1].speaker.speakerId != segment.speaker.speakerId {
                            Text(transcribeViewModel.speakerDisplayName(speakerId: segment.speaker.speakerId ?? -1))
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(transcribeViewModel.messageChainTimestamp(currentIndex: index))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        DiarizedSpeakerBubble(
                            segments: diarizedSegments,
                            customVocabularyResults: customVocabularyResults,
                            backgroundColor: transcribeViewModel.getMessageBackground(speaker: segment.speaker),
                            startTime: segment.speakerWords.first?.wordTiming.start ?? 0,
                            endTime: segment.speakerWords.last?.wordTiming.end ?? 0,
                            speakerId: segment.speaker.speakerId,
                            onRenameSpeaker: { transcribeViewModel.renameSpeaker(speakerId: $0) }
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

                if let task = transcribeViewModel.transcribeTask, !task.isCancelled {
                    Button {
                        transcribeViewModel.transcribeTask?.cancel()
                        transcribeViewModel.transcribeTask = nil
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
    let backgroundColor: Color
    let startTime: Float
    let endTime: Float
    let speakerId: Int?
    let onRenameSpeaker: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segments == rhs.segments &&
        lhs.customVocabularyResults == rhs.customVocabularyResults &&
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
            Text("[\(String(format: "%.2f", startTime)) → \(String(format: "%.2f", endTime))]")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onLongPressGesture {
            onRenameSpeaker(speakerId ?? -1)
        }
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
