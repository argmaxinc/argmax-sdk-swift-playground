import SwiftUI
import Argmax

/// A SwiftUI view component that displays transcription results for a single audio stream.
/// This view handles the presentation of confirmed text, hypothesis text, timestamps, and audio energy visualization.
struct StreamResultLine: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.result == rhs.result &&
        lhs.showSpeakerLabels == rhs.showSpeakerLabels &&
        lhs.isDeviceSource == rhs.isDeviceSource &&
        lhs.enableTimestamps == rhs.enableTimestamps &&
        lhs.autoScroll == rhs.autoScroll
    }

    let result: StreamViewModel.StreamResult
    let showSpeakerLabels: Bool
    /// True for the device microphone source — causes the waveform to read live energy
    /// directly from the ViewModel rather than from `result`, so this view's body is not
    /// invalidated on every energy poll cycle.
    let isDeviceSource: Bool
    /// Passed as a stored prop (not via @EnvironmentObject) so that `.equatable()` can
    /// correctly gate body re-evaluation: a settings change updates this prop and trips the
    /// equality check, while a bufferEnergy-only poll leaves it unchanged and skips body.
    let enableTimestamps: Bool
    let autoScroll: Bool

    init(result: StreamViewModel.StreamResult, showSpeakerLabels: Bool = false, isDeviceSource: Bool = false, enableTimestamps: Bool = false, autoScroll: Bool = true) {
        self.result = result
        self.showSpeakerLabels = showSpeakerLabels
        self.isDeviceSource = isDeviceSource
        self.enableTimestamps = enableTimestamps
        self.autoScroll = autoScroll
    }

    /// Isolated sub-view that absorbs @EnvironmentObject invalidations from waveform energy
    /// updates so that StreamResultLine.body is only re-evaluated when
    /// the transcription result or speaker-label flag changes.
    private struct WaveformSection: View {
        @EnvironmentObject var streamViewModel: StreamViewModel
        @EnvironmentObject var settings: AppSettings
        let isDeviceSource: Bool
        let staticSamples: [Float]

        var body: some View {
            let samples: [Float] = isDeviceSource && !streamViewModel.deviceBufferEnergy.isEmpty
                ? streamViewModel.deviceBufferEnergy
                : staticSamples
            let isActive = isDeviceSource && !streamViewModel.deviceBufferEnergy.isEmpty
            if !samples.isEmpty {
                WaveformView(samples: samples, silenceThreshold: Float(settings.silenceThreshold), isActive: isActive)
            }
        }
    }

    /// Speaker segment for grouping consecutive words by speaker
    private struct SpeakerSegment: Identifiable {
        /// Stable across re-renders for the same segment: speaker + start time in ms.
        var id: String { "\(speaker ?? -1)_\(Int(startTime * 1000))" }
        let speaker: Int?
        let words: [WordWithSpeaker]
        
        var text: String {
            words.map { $0.wordTiming.word }.joined()
        }
        
        var startTime: Float {
            words.first?.wordTiming.start ?? 0
        }
        
        var endTime: Float {
            words.last?.wordTiming.end ?? 0
        }
    }
    
    private func groupBySpeaker(_ words: [WordWithSpeaker]) -> [SpeakerSegment] {
        guard !words.isEmpty else { return [] }
        
        var segments: [SpeakerSegment] = []
        var currentSpeaker: Int? = words.first?.speaker
        var currentWords: [WordWithSpeaker] = []
        
        for word in words {
            if word.speaker != currentSpeaker {
                if !currentWords.isEmpty {
                    segments.append(SpeakerSegment(speaker: currentSpeaker, words: currentWords))
                }
                currentSpeaker = word.speaker
                currentWords = [word]
            } else {
                currentWords.append(word)
            }
        }
        
        if !currentWords.isEmpty {
            segments.append(SpeakerSegment(speaker: currentSpeaker, words: currentWords))
        }
        
        return segments
    }
    
    private func createHighlightedAttributedString(prefix: String = "", segments: [TranscriptionSegment], customVocabularyResults: VocabularyResults = [:], isBold: Bool, color: Color) -> AttributedString {
        let baseFont: Font = isBold ? .headline.bold() : .headline
        return HighlightedTextView.createHighlightedAttributedString(
            prefixText: prefix,
            segments: segments,
            customVocabularyResults: customVocabularyResults,
            font: baseFont,
            foregroundColor: color
        )
    }
    
    
    private func timestampRange(start: Float, end: Float) -> String {
        "[\(String(format: "%.2f", start)) → \(String(format: "%.2f", end))]"
    }
    
    private func hasContent(in segments: [TranscriptionSegment]) -> Bool {
        for segment in segments {
            if let words = segment.words, !words.isEmpty {
                return true
            }
            if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - Subviews
    
    /// Single speaker bubble view
    @ViewBuilder
    private func speakerBubble(segment: SpeakerSegment, isHypothesis: Bool = false) -> some View {
        let wordTimings = segment.words.map(\.wordTiming)
        let transcriptionSegment = TranscriptionSegment(
            text: segment.text,
            words: wordTimings.isEmpty ? nil : wordTimings
        )
        let baseColor: Color = isHypothesis ? .white.opacity(0.7) : .white
        HighlightedTextView(
            segments: [transcriptionSegment],
            customVocabularyResults: result.customVocabularyResults,
            font: isHypothesis ? .headline : .headline.bold(),
            foregroundColor: baseColor
        )
        .equatable()
        .padding(10)
        .background(SpeakerUI.color(for: segment.speaker))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .multilineTextAlignment(.leading)
    }
    
    /// View for speaker-labeled content: confirmed words + hypothesis words with known speakers
    @ViewBuilder
    private var speakerLabeledContentView: some View {
        let confirmedSegments = groupBySpeaker(result.confirmedWordsWithSpeakers)
        let knownHypothesis = groupBySpeaker(result.hypothesisWordsWithSpeakers.filter { $0.speaker != nil })
        let allSegments = confirmedSegments + knownHypothesis
        
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(allSegments.enumerated()), id: \.element.id) { index, segment in
                let isHypothesis = index >= confirmedSegments.count
                let showHeader = index == 0 || allSegments[index - 1].speaker != segment.speaker
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if showHeader {
                            Text(SpeakerUI.label(for: segment.speaker))
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(timestampRange(start: segment.startTime, end: segment.endTime))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        speakerBubble(segment: segment, isHypothesis: isHypothesis)
                    }
                    Spacer()
                }
                .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("bottom")
    }
    
    /// View for standard content without speaker labels
    private var standardContentView: some View {
        let hasConfirmed = hasContent(in: result.confirmedSegments)
        let hasHypothesis = hasContent(in: result.hypothesisSegments)
        let timestampText = enableTimestamps ? result.streamTimestampText : ""
        let confirmedPrefix = hasConfirmed ? timestampText : ""
        let hypothesisPrefix = hasConfirmed ? "" : (hasHypothesis ? timestampText : "")
        
        let confirmedAttributed = createHighlightedAttributedString(
            prefix: confirmedPrefix,
            segments: result.confirmedSegments,
            customVocabularyResults: result.customVocabularyResults,
            isBold: true,
            color: .primary
        )
        let hypothesisAttributed = createHighlightedAttributedString(
            prefix: hypothesisPrefix,
            segments: result.hypothesisSegments,
            customVocabularyResults: result.customVocabularyResults,
            isBold: false,
            color: .gray
        )
        
        return buildStandardTextView(
            confirmedAttributed: confirmedAttributed,
            hypothesisAttributed: hypothesisAttributed
        )
    }
    
    /// Builds the standard text view from attributed strings
    private func buildStandardTextView(confirmedAttributed: AttributedString, hypothesisAttributed: AttributedString) -> some View {
        return (Text(confirmedAttributed) + Text(hypothesisAttributed))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("bottom")
    }
    
    /// Whether to show speaker-labeled view
    private var shouldShowSpeakerLabels: Bool {
        showSpeakerLabels && (!result.confirmedWordsWithSpeakers.isEmpty || !result.hypothesisWordsWithSpeakers.isEmpty)
    }
    
    /// Fixed zone for hypothesis words awaiting speaker assignment (unknown/nil speaker only).
    /// Always renders its container to avoid pop-in/pop-out flickering during streaming.
    @ViewBuilder
    private var hypothesisBar: some View {
        let unknownWordTimings = result.hypothesisWordsWithSpeakers
            .filter { $0.speaker == nil }
            .map(\.wordTiming)
        let fallbackText = result.hypothesisWordsWithSpeakers.isEmpty
            ? result.hypothesisSegments.map { $0.text }.joined()
            : ""
        let isEmpty = unknownWordTimings.isEmpty
            && fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let segments: [TranscriptionSegment] = {
            if !unknownWordTimings.isEmpty {
                return [TranscriptionSegment(
                    text: unknownWordTimings.map(\.word).joined(),
                    words: unknownWordTimings
                )]
            } else if !fallbackText.isEmpty {
                return [TranscriptionSegment(text: fallbackText, words: nil)]
            } else {
                return [TranscriptionSegment(text: " ", words: nil)]
            }
        }()

        HighlightedTextView(
            segments: segments,
            customVocabularyResults: result.customVocabularyResults,
            font: .headline,
            foregroundColor: .secondary
        )
        .equatable()
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .glassBackground(cornerRadius: 12)
        .opacity(isEmpty ? 0.3 : 1.0)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            #if os(macOS)
            Text(result.title)
                .font(.title3)
                .fontWeight(.bold)
                .padding(.all, 8)
            #endif
            
            WaveformSection(isDeviceSource: isDeviceSource, staticSamples: result.bufferEnergy)
            
            ScrollViewReader { proxy in
                ScrollView {
                    if shouldShowSpeakerLabels {
                        speakerLabeledContentView
                    } else {
                        standardContentView
                    }
                }
                .softScrollEdgeEffect()
                .onChange(of: result.confirmedSegments) { _, _ in
                    guard autoScroll else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: result.confirmedWordsWithSpeakers) { _, _ in
                    guard autoScroll else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: result.hypothesisSegments) { _, _ in
                    guard autoScroll else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            
            if shouldShowSpeakerLabels {
                hypothesisBar
            }
        }
        .padding()
        #if os(macOS)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
        )
        #endif
    }
}

#Preview("StreamResultLine Sample") {
    let gunmanWord = WordTiming(word: "gunman", tokens: [], start: 0.0, end: 0.2, probability: 0.95)
    let victimWord = WordTiming(word: "victim", tokens: [], start: 0.3, end: 0.5, probability: 0.92)
    let corneredWord = WordTiming(word: "cornered", tokens: [], start: 0.6, end: 0.8, probability: 0.9)
    let confirmedSegment = TranscriptionSegment(text: "The gunman kept his victim", words: [
        WordTiming(word: "The", tokens: [], start: 0, end: 0.1, probability: 0.9),
        gunmanWord,
        WordTiming(word: "kept", tokens: [], start: 0.2, end: 0.3, probability: 0.9),
        WordTiming(word: "his", tokens: [], start: 0.3, end: 0.35, probability: 0.9),
        victimWord
    ])
    let hypothesisSegment = TranscriptionSegment(text: "cornered at gunpoint…", words: [
        corneredWord,
        WordTiming(word: "at", tokens: [], start: 0.8, end: 0.85, probability: 0.9),
        WordTiming(word: "gunpoint…", tokens: [], start: 0.85, end: 0.95, probability: 0.9)
    ])
    let sampleResult = StreamViewModel.StreamResult(
        title: "Audio Stream #1",
        confirmedSegments: [confirmedSegment],
        hypothesisSegments: [hypothesisSegment],
        customVocabularyResults: [
            gunmanWord: [gunmanWord],
            victimWord: [victimWord],
            corneredWord: [corneredWord]
        ],
        streamEndSeconds: 12.3,
        bufferEnergy: (0..<350).map { _ in Float.random(in: 0...1) }
    )
    StreamResultLine(result: sampleResult)
        .padding()
        .frame(maxWidth: 400)
}


/// The main container view that presents results from multiple concurrent audio streams.
/// This view coordinates the display of device and system stream results using `StreamResultLine` components.
///
/// ## Architecture
///
/// - Observes `StreamViewModel` for real-time result updates
/// - Displays separate `StreamResultLine` views for device and system streams
/// - Provides text selection capabilities across all displayed content
/// - Maintains responsive layout that adapts to available content
///
/// ## User Settings Integration
///
/// - Respects timestamp display preferences via `AppSettings`
/// - Adapts to silence threshold settings for audio visualization
/// - Supports speaker label display when streaming diarization is enabled
struct StreamResultView: View {
    @EnvironmentObject private var streamViewModel: StreamViewModel
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var settings: AppSettings

    let selectedMode: TabMode
    let isRecording: Bool
    let autoScroll: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedMode == .diarize && !sdkCoordinator.isSortformerLoaded {
                if isRecording && !streamViewModel.deviceBufferEnergy.isEmpty {
                    WaveformView(samples: streamViewModel.deviceBufferEnergy, silenceThreshold: Float(settings.silenceThreshold), isActive: true)
                }
                HStack(alignment: .firstTextBaseline) {
                    ToastMessage(message: "⚠️ Streaming diarization requires Sortformer")
                }
                .padding(.bottom, 8)
                .padding(.horizontal)
                .animation(.easeInOut, value: sdkCoordinator.isSortformerLoaded)
            }
            
            if selectedMode != .diarize || sdkCoordinator.isSortformerLoaded {
                if let device = streamViewModel.deviceResult {
                    StreamResultLine(
                        result: device,
                        showSpeakerLabels: streamViewModel.enableStreamingDiarization && selectedMode == .diarize,
                        isDeviceSource: true,
                        enableTimestamps: settings.enableTimestamps,
                        autoScroll: autoScroll
                    )
                    .equatable()
                }
                if let system = streamViewModel.systemResult {
                    StreamResultLine(
                        result: system,
                        showSpeakerLabels: streamViewModel.enableStreamingDiarization && selectedMode == .diarize,
                        enableTimestamps: settings.enableTimestamps,
                        autoScroll: autoScroll
                    )
                    .equatable()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Disable text selection while recording — same SelectionOverlay / NavigationState.SelectionSeed
        // cascade as in TranscribeResultView: hover-tracking fires ~79k times during active processing,
        // cascading into Text Content attribute graph updates for every visible text node.
        .conditionalTextSelection(!isRecording)
        .padding()
    }
}

// MARK: - View Helpers

private extension View {
    @ViewBuilder
    func conditionalTextSelection(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}

#Preview("Multiple Active Stream results") {
    // 1. Create an instance of the view model for the preview
    #if os(macOS)
    let sdkCoordinator = ArgmaxSDKCoordinator(
        keyProvider: ObfuscatedKeyProvider(mask: 12)
    )
    let processDiscoverer = AudioProcessDiscoverer()
    let deviceDiscoverer = AudioDeviceDiscoverer()
    let streamViewModel = StreamViewModel(
        sdkCoordinator: sdkCoordinator,
        audioProcessDiscoverer: processDiscoverer,
        audioDeviceDiscoverer: deviceDiscoverer
    )
    #else
    let sdkCoordinator = ArgmaxSDKCoordinator(
        keyProvider: ObfuscatedKeyProvider(mask: 12)
    )
    let deviceDiscoverer = AudioDeviceDiscoverer()
    let liveActivityManager = LiveActivityManager()
    let streamViewModel = StreamViewModel(
        sdkCoordinator: sdkCoordinator,
        audioDeviceDiscoverer: deviceDiscoverer,
        liveActivityManager: liveActivityManager
    )
    #endif

    // 2. Create two sample result objects with different data
    let highlightedWord = WordTiming(word: "highlighted", tokens: [], start: 0.0, end: 0.2, probability: 0.95)
    let sampleSegments = [
        TranscriptionSegment(
            text: "This is a much longer text block designed to test the scrolling behavior.",
            words: [
                WordTiming(word: "This", tokens: [], start: 0, end: 0.1, probability: 0.9),
                WordTiming(word: "is", tokens: [], start: 0.1, end: 0.15, probability: 0.9),
                WordTiming(word: "a", tokens: [], start: 0.15, end: 0.17, probability: 0.9),
                WordTiming(word: "much", tokens: [], start: 0.17, end: 0.2, probability: 0.9),
                highlightedWord,
                WordTiming(word: "text", tokens: [], start: 0.25, end: 0.3, probability: 0.9),
                WordTiming(word: "block", tokens: [], start: 0.3, end: 0.35, probability: 0.9),
                WordTiming(word: "designed", tokens: [], start: 0.35, end: 0.4, probability: 0.9),
                WordTiming(word: "to", tokens: [], start: 0.4, end: 0.45, probability: 0.9),
                WordTiming(word: "test", tokens: [], start: 0.45, end: 0.5, probability: 0.9),
                WordTiming(word: "the", tokens: [], start: 0.5, end: 0.55, probability: 0.9),
                WordTiming(word: "scrolling", tokens: [], start: 0.55, end: 0.6, probability: 0.9),
                WordTiming(word: "behavior.", tokens: [], start: 0.6, end: 0.65, probability: 0.9)
            ]
        )
    ]
    let sampleHypothesis = [
        TranscriptionSegment(
            text: "It seems to be working...",
            words: [
                WordTiming(word: "It", tokens: [], start: 0, end: 0.05, probability: 0.9),
                WordTiming(word: "seems", tokens: [], start: 0.05, end: 0.1, probability: 0.9),
                WordTiming(word: "to", tokens: [], start: 0.1, end: 0.15, probability: 0.9),
                WordTiming(word: "be", tokens: [], start: 0.15, end: 0.2, probability: 0.9),
                WordTiming(word: "working...", tokens: [], start: 0.2, end: 0.25, probability: 0.9)
            ]
        )
    ]
    let result1 = StreamViewModel.StreamResult(
        title: "Device: Your microphone",
        confirmedSegments: sampleSegments,
        hypothesisSegments: sampleHypothesis,
        customVocabularyResults: [highlightedWord: [highlightedWord]],
        streamEndSeconds: 15.8,
        bufferEnergy: (0..<200).map { _ in Float.random(in: 0...1) }
    )
    
    #if os(macOS)
    let result2 = StreamViewModel.StreamResult(
        title: "System: YouTube app",
        confirmedSegments: sampleSegments,
        hypothesisSegments: [],
        customVocabularyResults: [:],
        streamEndSeconds: 22.1
    )
    #endif
    // 3. Populate the view model's published properties
    streamViewModel.deviceResult = result1
    #if os(macOS)
    streamViewModel.systemResult = result2
    #endif
    
    return StreamResultView(selectedMode: .transcription, isRecording: false, autoScroll: true)
    .environmentObject(streamViewModel)
    #if os(macOS)
    .environmentObject(processDiscoverer)
    #endif
    .environmentObject(deviceDiscoverer)
    .frame(height: 400)
    .padding()
    .onAppear() {
        UserDefaults.standard.set(false, forKey: "enableDecoderPreview")
        UserDefaults.standard.set(0.2, forKey: "silenceThreshold")
    }
}
