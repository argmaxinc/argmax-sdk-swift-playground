import Foundation
import SwiftUI
import Argmax

/// A SwiftUI view to present the results of audio transcription from files or recordings.
/// This view handles the display of both standard transcription and speaker diarization results.
///
/// ## Core Features
///
/// - **Dual Mode Display:** Supports both transcription and diarization result presentation
/// - **Progress Tracking:** Shows real-time transcription progress with cancellation support
/// - **Audio Visualization:** Integrates `VoiceEnergyView` for buffer energy display
/// - **Interactive Elements:** Provides speaker renaming functionality in diarization mode
/// - **Status Messages:** Shows contextual recording and processing status information
///
/// ## Display Modes
///
/// - **Transcription Mode:** Shows confirmed and unconfirmed text segments with optional timestamps
/// - **Diarization Mode:** Displays speaker-segmented results with speaker identification and timing
///
/// ## Dependencies
///
/// - `TranscribeViewModel`: Provides transcription state and results data
/// - `ArgmaxSDKCoordinator`: Manages model availability and loading status
struct TranscribeResultView: View {
    @Binding var selectedMode: ContentView.TabMode
    @Binding var isRecording: Bool
    
    let loadModel: (String, Bool) -> Void
    
    // Static constant to avoid recomputing on every view render
    private static let defaultModel = WhisperKit.recommendedModels().default
    
    @AppStorage("enableTimestamps") private var enableTimestamps: Bool = true
    @AppStorage("selectedModel") private var selectedModel: String = TranscribeResultView.defaultModel
    @AppStorage("enableDecoderPreview") private var enableDecoderPreview: Bool = true
    
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var transcribeViewModel: TranscribeViewModel
    
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !transcribeViewModel.bufferEnergy.isEmpty {
                VoiceEnergyView(bufferEnergy: transcribeViewModel.bufferEnergy)
            }
            
            // Show transcription message when recording and transcribing
            if isRecording && transcribeViewModel.isTranscribing {
                Text("🎙️ Recording in progress... Transcription will appear after you stop recording. For real-time results, switch to Stream mode.")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if selectedMode == .transcription {
                        ForEach(Array(transcribeViewModel.confirmedSegments.enumerated()), id: \.element) { _, segment in
                            let timestampText = enableTimestamps
                                ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))] "
                                : ""
                            HighlightedTextView(
                                text: timestampText + segment.text,
                                customVocabularyResults: transcribeViewModel.customVocabularyResults,
                                font: .headline.bold(),
                                foregroundColor: .primary
                            )
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ForEach(Array(transcribeViewModel.unconfirmedSegments.enumerated()), id: \.element) { _, segment in
                            let timestampText = enableTimestamps
                                ? "[\(String(format: "%.2f", segment.start)) --> \(String(format: "%.2f", segment.end))] "
                                : ""
                            HighlightedTextView(
                                text: timestampText + segment.text,
                                customVocabularyResults: transcribeViewModel.customVocabularyResults,
                                font: .headline.bold(),
                                foregroundColor: .gray
                            )
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                    } else if selectedMode == .diarize {
                        if transcribeViewModel.showShortAudioToast {
                            HStack(alignment: .firstTextBaseline) {
                                let toastMessage = sdkCoordinator.speakerKit == nil
                                    ? "⚠️ SpeakerKit not loaded"
                                    : "⚠️ Diarization works best with audio longer than 1 minute"
                                ToastMessage(message: toastMessage)

                                if sdkCoordinator.speakerKit == nil {
                                    Button {
                                        loadModel(selectedModel, false)
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.bottom, 8)
                            .padding(.horizontal)
                            .animation(.easeInOut, value: transcribeViewModel.showShortAudioToast)
                        }

                        ForEach(Array(transcribeViewModel.diarizedSpeakerSegments.enumerated()), id: \.element.id) { index, segment in
                            HStack {
                                VStack(alignment: .leading) {
                                    if index == 0 || transcribeViewModel.diarizedSpeakerSegments[index - 1].speaker.speakerId != segment.speaker.speakerId {
                                        Text(transcribeViewModel.speakerDisplayName(speakerId: segment.speaker.speakerId ?? -1))
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        Text(transcribeViewModel.messageChainTimestamp(currentIndex: index))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    HighlightedTextView(
                                        text: segment.text,
                                        customVocabularyResults: transcribeViewModel.customVocabularyResults,
                                        font: .headline,
                                        foregroundColor: .white
                                    )
                                    .padding(10)
                                    .background(transcribeViewModel.getMessageBackground(speaker: segment.speaker))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .multilineTextAlignment(.leading)
                                        .contextMenu {
                                            Button(action: {
                                                transcribeViewModel.renameSpeaker(speakerId: segment.speaker.speakerId ?? -1)
                                            }) {
                                                Label("Rename Speaker", systemImage: "pencil")
                                            }

                                            Text("[\(String(format: "%.2f", segment.speakerWords.first?.wordTiming.start ?? 0)) → \(String(format: "%.2f", segment.speakerWords.last?.wordTiming.end ?? 0))]")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .onLongPressGesture {
                                            transcribeViewModel.renameSpeaker(speakerId: segment.speaker.speakerId ?? -1)
                                        }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    if enableDecoderPreview {
                        HighlightedTextView(
                            text: transcribeViewModel.currentText,
                            customVocabularyResults: transcribeViewModel.customVocabularyResults,
                            font: .caption,
                            foregroundColor: .secondary
                        )
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .defaultScrollAnchor(.top)
            .textSelection(.enabled)
            .padding()
        }
        
        if let whisperKit = sdkCoordinator.whisperKit,
           transcribeViewModel.isTranscribing,
           let task = transcribeViewModel.transcribeTask,
           !task.isCancelled,
           whisperKit.progress.fractionCompleted < 1
        {
            HStack {
                ProgressView(whisperKit.progress)
                    .progressViewStyle(.linear)
                    .labelsHidden()
                    .padding(.horizontal)
                
                Button {
                    transcribeViewModel.transcribeTask?.cancel()
                    transcribeViewModel.transcribeTask = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
    }
}

#Preview("TranscribeResultView Sample") {
    let sdkCoordinator = ArgmaxSDKCoordinator(
        keyProvider: ObfuscatedKeyProvider(mask: 12)
    )
    let transcribeViewModel = TranscribeViewModel(sdkCoordinator: sdkCoordinator)
    
    TranscribeResultView(
        selectedMode: .constant(.transcription),
        isRecording: .constant(false),
        loadModel: { _, _ in }
    )
    .environmentObject(sdkCoordinator)
    .environmentObject(transcribeViewModel)
    .frame(height: 400)
    .padding()
    .onAppear {
        UserDefaults.standard.set(true, forKey: "enableTimestamps")
        UserDefaults.standard.set(true, forKey: "enableDecoderPreview")
        
        let quickWord = WordTiming(word: "quick", tokens: [], start: 0.0, end: 0.3, probability: 0.95)
        let sampleWord = WordTiming(word: "sample", tokens: [], start: 2.5, end: 2.9, probability: 0.92)
        transcribeViewModel.customVocabularyResults = [
            quickWord: [quickWord],
            sampleWord: [sampleWord]
        ]
        // Set up sample transcription segments
        transcribeViewModel.confirmedSegments = [
            TranscriptionSegment(
                id: 0,
                start: 0.0,
                end: 2.5,
                text: "The quick brown fox jumps over the lazy dog."
            ),
            TranscriptionSegment(
                id: 1,
                start: 2.5,
                end: 5.0,
                text: "This is a sample transcription for preview purposes."
            )
        ]
        
        transcribeViewModel.unconfirmedSegments = [
            TranscriptionSegment(
                id: 2,
                start: 5.0,
                end: 7.5,
                text: "This text appears in gray as unconfirmed."
            )
        ]
        
        transcribeViewModel.currentText = "Currently processing more text..."
        transcribeViewModel.bufferEnergy = (0..<200).map { _ in Float.random(in: 0...1) }
    }
}
