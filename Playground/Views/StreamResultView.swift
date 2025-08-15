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
                    (
                        (enableTimestamps ?
                            Text(result.streamTimestampText)
                                .font(.caption)
                                .foregroundColor(.secondary) :
                            Text("")
                        ) +
                        Text(result.confirmedText)
                            .font(.headline)
                            .fontWeight(.bold) +
                        Text(result.confirmedText.isEmpty || result.hypothesisText.isEmpty ? "" : " ") +
                        Text(result.hypothesisText)
                            .font(.headline)
                            .foregroundColor(.gray)
                    )
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("bottom")
                }
                .onChange(of: result.confirmedText) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                // Avoid animating on every hypothesis token; keep scroll position but don't animate
                .onChange(of: result.hypothesisText) {
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
    let sampleResult = StreamViewModel.StreamResult(
        title: "Audio Stream #1",
        confirmedText: "The gunman kept his victim",
        hypothesisText: "cornered at gunpoint…",
        streamEndSeconds: 12.3,
        bufferEnergy: (0..<350).map { _ in Float.random(in: 0...1) },
        bufferSeconds: 2.5,
        transcribeResult: nil
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
    @AppStorage("silenceThreshold") private var silenceThreshold: Double = 0.2

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
    let streamViewModel = StreamViewModel(
        sdkCoordinator: sdkCoordinator,
        audioDeviceDiscoverer: deviceDiscoverer
    )
    #endif

    // 2. Create two sample result objects with different data
    let longText = "This is a much longer text block designed to test the scrolling behavior within the StreamResultLine. When content overflows its allocated space, a scrollbar should appear, allowing the user to see all of the text. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur."
    let result1 = StreamViewModel.StreamResult(
        title: "Device: Your microphone",
        confirmedText: longText,
        hypothesisText: "It seems to be working...",
        streamEndSeconds: 15.8,
        bufferEnergy: (0..<200).map { _ in Float.random(in: 0...1) }
    )
    
    #if os(macOS)
    let result2 = StreamViewModel.StreamResult(
        title: "System: YouTube app",
        confirmedText: "This is the second audio stream from a different process. ",
        hypothesisText: "There is no energy data available for this stream yet.",
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
