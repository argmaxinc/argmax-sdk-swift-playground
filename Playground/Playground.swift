import SwiftUI

#if canImport(ArgmaxSecrets)
import ArgmaxSecrets
#endif

/// The main entry point for the Playground application.
///
/// `Playground` is a SwiftUI app that provides audio transcription capabilities using WhisperKit technology.
/// The app uses a configurable environment initialization pattern to support different deployment contexts
/// (development, production, public) while maintaining a consistent architecture.
///
/// The app supports both macOS and iOS platforms, with additional audio process discovery features available
/// exclusively on macOS. Analytics integration and API key management are configured through the environment initializer.
///
/// ## Architecture
///
/// The app follows an MVVM architecture pattern with the following key components:
/// - `PlaygroundEnvInitializer`: Configures environment-specific dependencies (API keys, analytics)
/// - `ArgmaxSDKCoordinator`: Manages SDK initialization and configuration
/// - `AudioDeviceDiscoverer`: Discovers and manages audio input devices
/// - `AudioProcessDiscoverer`: (macOS only) Discovers system audio processes for tapping
/// - `StreamViewModel`: Handles real-time audio streaming and transcription
/// - `TranscribeViewModel`: Manages file-based transcription operations
///
/// ## Environment Configuration
///
/// The app uses dependency injection through `PlaygroundEnvInitializer` to configure:
/// - **API Key Providers**: Different implementations for development vs production
/// - **Analytics Loggers**: No-op for development, Firebase for production
/// - **Additional Setup**: Environment-specific initialization requirements
///
/// ## Usage
///
/// The app automatically initializes all required components and sets up the environment objects
/// for dependency injection throughout the SwiftUI view hierarchy. The specific environment configuration
/// is determined by the `PlaygroundEnvInitializer` implementation used during initialization.
@main
struct Playground: App {
    #if !os(watchOS)
    private let envInitializer: PlaygroundEnvInitializer
    private let analyticsLogger: AnalyticsLogger
    
    #if os(macOS)
    @StateObject private var audioProcessDiscoverer: AudioProcessDiscoverer
    #endif
    @StateObject private var audioDeviceDiscoverer: AudioDeviceDiscoverer
    @StateObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @StateObject private var streamViewModel: StreamViewModel
    @StateObject private var transcribeViewModel: TranscribeViewModel

    init() {
        // Initialize environment configuration
        #if canImport(ArgmaxSecrets)
        // Import from Internal submodule when available
        self.envInitializer = ArgmaxEnvInitializer()
        #else
        // Use default public implementation
        self.envInitializer = DefaultEnvInitializer()
        #endif
        
        // Create environment-specific components
        let apiKeyProvider = envInitializer.createAPIKeyProvider()
        self.analyticsLogger = envInitializer.createAnalyticsLogger()
        
        // Initialize core components with environment configuration
        let coordinator = ArgmaxSDKCoordinator(keyProvider: apiKeyProvider)
        let deviceDiscoverer = AudioDeviceDiscoverer()
        
        #if os(macOS)
        let processDiscoverer = AudioProcessDiscoverer()
        let streamVM = StreamViewModel(
            sdkCoordinator: coordinator,
            audioProcessDiscoverer: processDiscoverer,
            audioDeviceDiscoverer: deviceDiscoverer
        )
        self._audioProcessDiscoverer = StateObject(wrappedValue: processDiscoverer)
        #else
        let liveActivityMgr = LiveActivityManager()
        let streamVM = StreamViewModel(
            sdkCoordinator: coordinator,
            audioDeviceDiscoverer: deviceDiscoverer,
            liveActivityManager: liveActivityMgr
        )
        #endif
        let transcribeVM = TranscribeViewModel(sdkCoordinator: coordinator)
        
        self._sdkCoordinator = StateObject(wrappedValue: coordinator)
        self._audioDeviceDiscoverer = StateObject(wrappedValue: deviceDiscoverer)
        self._streamViewModel = StateObject(wrappedValue: streamVM)
        self._transcribeViewModel = StateObject(wrappedValue: transcribeVM)
    }

    var body: some Scene {
        WindowGroup {
             ContentView(analyticsLogger: analyticsLogger)
                 #if os(macOS)
                 .environmentObject(audioProcessDiscoverer)
                 #endif
                 .environmentObject(audioDeviceDiscoverer)
                 .environmentObject(sdkCoordinator)
                 .environmentObject(streamViewModel)
                 .environmentObject(transcribeViewModel)
                 .onAppear {
                     sdkCoordinator.setupArgmax()
                     analyticsLogger.configureIfNeeded()
                 }
            #if os(macOS)
                .frame(minWidth: 1000, minHeight: 700)
            #endif
        }
    }
    #endif
}
