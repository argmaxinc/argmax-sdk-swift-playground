import Foundation
import SwiftUI
import Argmax

/// A SwiftUI view component that displays transcription results for a single audio stream.
/// This view handles the presentation of confirmed text, hypothesis text, timestamps, and audio energy visualization.
///
/// ## Features
///
/// - **Text Display:** Shows both confirmed (bold) and hypothesis (gray) transcription text
/// - **Timestamp Support:** Optional timestamp display controlled by user preferences
/// - **Audio Visualization:** Integrates `VoiceEnergyView` for real-time audio energy display
/// - **Auto-Scrolling:** Automatically scrolls to show latest transcription results
/// - **Platform Styling:** Applies platform-specific visual styling (border on macOS)
struct StreamResultLine: View {
    @AppStorage("enableTimestamps") private var enableTimestamps: Bool = true

    let result: StreamViewModel.StreamResult
    
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            #if os(macOS)
            // Title is now at the top, outside the scroll area
            Text(result.title)
                .font(.title3)
                .fontWeight(.bold)
                .padding(.all, 8)
            #endif
            if !result.bufferEnergy.isEmpty {
                VoiceEnergyView(bufferEnergy: result.bufferEnergy)
            }
            
            // This ScrollView makes the text content scrollable if it overflows
            ScrollViewReader { proxy in
                ScrollView {
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
                    let needsSpacer = !confirmedAttributed.characters.isEmpty && !hypothesisAttributed.characters.isEmpty
                    (
                        Text(confirmedAttributed) +
                        (needsSpacer ? Text(" ") : Text("")) +
                        Text(hypothesisAttributed)
                    )
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("bottom")
                }
                .onChange(of: result.confirmedSegments) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                // Avoid animating on every hypothesis token; keep scroll position but don't animate
                .onChange(of: result.hypothesisSegments) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
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
/// - Respects timestamp display preferences via `@AppStorage`
/// - Adapts to silence threshold settings for audio visualization
struct StreamResultView: View {
    @EnvironmentObject var streamViewModel: StreamViewModel
    @AppStorage("enableTimestamps") private var enableTimestamps: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let device = streamViewModel.deviceResult {
                StreamResultLine(result: device)
            }
            if let system = streamViewModel.systemResult {
                StreamResultLine(result: system)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure the root VStack fills all space
        .textSelection(.enabled)
        .padding()
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
    
    return StreamResultView()
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
