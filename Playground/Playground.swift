import SwiftUI

#if canImport(ArgmaxSecrets)
import ArgmaxSecrets
#endif

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
    @StateObject private var sessionHistory = SessionHistoryManager()
    @StateObject private var appSettings: AppSettings

    init() {
        #if canImport(ArgmaxSecrets)
        self.envInitializer = ArgmaxEnvInitializer()
        #else
        self.envInitializer = DefaultEnvInitializer()
        #endif
        
        let apiKeyProvider = envInitializer.createAPIKeyProvider()
        self.analyticsLogger = envInitializer.createAnalyticsLogger()
        
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
        let settings = AppSettings()
        let transcribeVM = TranscribeViewModel(sdkCoordinator: coordinator, settings: settings)
        
        self._appSettings = StateObject(wrappedValue: settings)
        self._sdkCoordinator = StateObject(wrappedValue: coordinator)
        self._audioDeviceDiscoverer = StateObject(wrappedValue: deviceDiscoverer)
        self._streamViewModel = StateObject(wrappedValue: streamVM)
        self._transcribeViewModel = StateObject(wrappedValue: transcribeVM)
    }

    var body: some Scene {
        WindowGroup("Argmax Playground") {
            ContentView(analyticsLogger: analyticsLogger)
                #if os(macOS)
                .environmentObject(audioProcessDiscoverer)
                #endif
                .environmentObject(audioDeviceDiscoverer)
                .environmentObject(sdkCoordinator)
                .environmentObject(streamViewModel)
                .environmentObject(transcribeViewModel)
                .environmentObject(sessionHistory)
                .environmentObject(appSettings)
                .onAppear {
                    sdkCoordinator.setupArgmax()
                    analyticsLogger.configureIfNeeded()
                    #if os(iOS)
                    Task {
                        await streamViewModel.liveActivityManager.cleanupOrphanedActivities()
                    }
                    #endif
                }
            #if os(macOS)
                .frame(minWidth: 1000, minHeight: 700)
            #endif
        }
    }
    #endif
}
