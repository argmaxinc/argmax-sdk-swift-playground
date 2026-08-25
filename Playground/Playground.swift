import SwiftUI
import Argmax

#if canImport(ArgmaxSecrets)
import ArgmaxSecrets
#endif

#if os(iOS)
import UserNotifications
import os.log

/// AppDelegate to handle background URL session events and notifications
class PlaygroundAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set ourselves as the notification delegate to show notifications in foreground
        UNUserNotificationCenter.current().delegate = self

        // Opt in to SDK-managed Core ML cache warmup. The SDK owns BGProcessingTask
        // registration, scheduling, warm-target selection and run history -- registering
        // just has to happen before this method returns.
        ModelWarmup.register()

        return true
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    /// This allows notifications to show even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner, sound, badge, and keep in notification list
        completionHandler([.banner, .list, .sound, .badge])
    }
    
    /// Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // User tapped on notification -- could deep-link to download status here
        completionHandler()
    }
    
    // MARK: - Background URL Session
    
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        #if DEBUG
        // Notify that app was woken up
        sendNotification(
            title: "📲 App Woken",
            body: "Processing background download events...",
            identifier: "app-woken"
        )
        #endif
        // Log wake into the persistent event log so the user can review it later.
        // Use the static appender -- Coordinator.shared may not exist yet on a background relaunch.
        BackgroundEvent.append("App woken for background URL session \(identifier)")

        // Forward to the backgroundDownloader via the coordinator's modelStore
        // The coordinator's modelStore owns the BackgroundDownloader instance
        if let coordinator = ArgmaxSDKCoordinator.shared {
            coordinator.modelStore.handleEventsForBackgroundSession(
                identifier: identifier,
                completionHandler: { [self] in
                    self.checkDownloadStatusAndNotify()
                    completionHandler()
                }
            )
        } else {
            BackgroundEvent.append("Coordinator unavailable on wake -- completing without forwarding")
            completionHandler()
        }
    }

    private func checkDownloadStatusAndNotify() {
        // Check download status via coordinator
        guard let coordinator = ArgmaxSDKCoordinator.shared else { return }

        for download in coordinator.modelStore.activeBackgroundDownloads {
            let pct = Int(download.overallProgress * 100)
            Logging.debug("[AppDelegate] Download \(download.modelVariant): \(pct)% - \(download.status)")
            BackgroundEvent.append("Wake snapshot: \(download.modelVariant) [\(download.downloadId.prefix(8))] \(download.status.rawValue) @ \(pct)%")
        }
    }
    
    private func sendNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        // Make notification more persistent/prominent
        content.interruptionLevel = .timeSensitive  // Breaks through focus modes
        content.relevanceScore = 1.0  // Highest relevance for sorting
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logging.error("Failed to send notification: \(error)")
            }
        }
    }
}
#endif

/// Process entry point.
///
/// `@main` lives here rather than on ``Playground`` so the warm-while-closed launch agent can
/// be serviced before any UI exists. On an agent launch (`--argmax-warm-only`)
/// `handleWarmOnlyLaunchIfNeeded()` warms and exits without ever returning, so `Playground.main()`
/// is only reached on ordinary launches. ``Playground`` keeps its synthesized `main()`.
@main
enum PlaygroundEntry {
    static func main() async {
        #if os(macOS)
        // The headless branch logs nothing unless a level is set first -- the SDK's default
        // is `.none`, and this process has no UI to report through.
        Logging.shared.logLevel = .info
        await ModelWarmup.handleWarmOnlyLaunchIfNeeded()
        #endif
        Playground.main()
    }
}

/// MVVM SwiftUI app for on-device transcription and diarization with the Argmax SDK.
///
/// `PlaygroundEnvInitializer` injects the environment-specific pieces (API key provider,
/// analytics); `ArgmaxSDKCoordinator` owns SDK setup and model lifecycle; the view models
/// (`StreamViewModel` for live streaming, `TranscribeViewModel` for files and recordings)
/// and audio discoverers are created here and shared through the environment.
struct Playground: App {
    #if os(iOS)
    /// AppDelegate adaptor to handle background URL session events
    @UIApplicationDelegateAdaptor(PlaygroundAppDelegate.self) var appDelegate
    #endif
    
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
        // Bind the AppDelegate to the coordinator here in the App owner,
        // since background URL-session relaunches happen before SwiftUI scenes run.
        ArgmaxSDKCoordinator.shared = coordinator
        let deviceDiscoverer = AudioDeviceDiscoverer()

        #if os(macOS)
        let processDiscoverer = AudioProcessDiscoverer()
        let streamViewModel = StreamViewModel(
            sdkCoordinator: coordinator,
            audioProcessDiscoverer: processDiscoverer,
            audioDeviceDiscoverer: deviceDiscoverer
        )
        self._audioProcessDiscoverer = StateObject(wrappedValue: processDiscoverer)
        #else
        let liveActivityMgr = LiveActivityManager()
        let streamViewModel = StreamViewModel(
            sdkCoordinator: coordinator,
            audioDeviceDiscoverer: deviceDiscoverer,
            liveActivityManager: liveActivityMgr
        )
        #endif
        let settings = AppSettings()

        let transcribeViewModel = TranscribeViewModel(sdkCoordinator: coordinator, settings: settings)
        
        self._appSettings = StateObject(wrappedValue: settings)
        self._sdkCoordinator = StateObject(wrappedValue: coordinator)
        self._audioDeviceDiscoverer = StateObject(wrappedValue: deviceDiscoverer)
        self._streamViewModel = StateObject(wrappedValue: streamViewModel)
        self._transcribeViewModel = StateObject(wrappedValue: transcribeViewModel)
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
                    #else
                    // iOS registers in the AppDelegate because BGTaskScheduler demands it
                    // before launch completes; macOS has no such deadline, so registration
                    // stays off the first-frame path.
                    Self.registerModelWarmup(warmWhileClosed: appSettings.warmWhileClosed)
                    #endif
                }
            #if os(macOS)
                .frame(minWidth: 1000, minHeight: 700)
            #endif
        }
    }

    #if os(macOS)
    /// Opt in to SDK-managed Core ML cache warmup on macOS, and decide the fate of the
    /// warm-while-closed launch agent before `register()` can act on it.
    ///
    /// The build generates `<bundle id>.modelwarmup.plist` into the bundle (see
    /// `scripts/generate_modelwarmup_agent.sh`), and the SDK treats a bundled plist as the
    /// opt-in: `register()` would register the login item on first launch. The Mac App Store
    /// expects background items to follow an explicit user action, so the bundled plist is
    /// downgraded to "available" and ``AppSettings/warmWhileClosed`` is the actual switch.
    ///
    /// `disableBackgroundAgent()` is called only while the user has not opted in. Calling it
    /// unconditionally would erase the opt-in the user just made, since the SDK persists that
    /// state itself -- the opt-out has to be conditional, not a reset.
    ///
    /// In-app warming (`NSBackgroundActivityScheduler`) runs either way while the app is open.
    private static func registerModelWarmup(warmWhileClosed: Bool) {
        if !warmWhileClosed {
            ModelWarmup.disableBackgroundAgent()
        }
        ModelWarmup.register()
    }
    #endif
}
