import Argmax
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
#if canImport(ArgmaxSecrets)
import ArgmaxSecrets
#endif
import AppKit
#endif
#if os(macOS)
/// Lets tab views open the embedded Settings pane without owning ContentView's state.
/// Tab toolbars need the Settings button *after* their own items to match iOS ordering.
private struct OpenSettingsActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openPlaygroundSettings: () -> Void {
        get { self[OpenSettingsActionKey.self] }
        set { self[OpenSettingsActionKey.self] = newValue }
    }
}
#endif

/// Slim routing shell for the Playground app.
/// All feature-specific logic lives in dedicated tab views.
struct ContentView: View {
    @EnvironmentObject private var streamViewModel: StreamViewModel
    @EnvironmentObject private var transcribeViewModel: TranscribeViewModel
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    private let analyticsLogger: AnalyticsLogger

    #if os(macOS)
    @State private var selectedFeature: PlaygroundFeature? = .transcribe
    #else
    @State private var selectedFeature: PlaygroundFeature? = nil
    #endif
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isTranscriptionFullscreen = false
    #if os(macOS)
    // On iOS the sidebar header owns the settings button; macOS hides that header, so the
    // window toolbar provides the entry point instead.
    @State private var showSettings = false
    #endif

    init(analyticsLogger: AnalyticsLogger = NoOpAnalyticsLogger()) {
        self.analyticsLogger = analyticsLogger
    }

    var body: some View {
        // `mainNavigation` is now always the root. On iOS the focus mode lifts into a
        // `.fullScreenCover` modifier; on macOS we hide the sidebar via `columnVisibility`
        // instead of swapping in a hand-rolled overlay. See `focusModeCover` and the toolbar
        // button in `mainNavigation` for the entry points.
        mainNavigation
            #if os(iOS)
            .fullScreenCover(isPresented: $isTranscriptionFullscreen) { focusModeCover }
            #endif
        .onAppear {
            #if os(macOS)
            if selectedFeature == nil { selectedFeature = .transcribe }
            #endif
            syncSortformerMode()
        }
        .onChange(of: selectedFeature) { _, newFeature in
            syncSortformerMode()
            if let feature = newFeature {
                if feature == .stream && sdkCoordinator.loadedDiarizationModel == .sortformer {
                    streamViewModel.enableStreamingDiarization = true
                } else {
                    streamViewModel.enableStreamingDiarization = false
                }
            }
        }
        .onChange(of: sdkCoordinator.loadedDiarizationModel) { _, newModel in
            if newModel == .sortformer && selectedFeature == .stream {
                streamViewModel.enableStreamingDiarization = true
            } else {
                streamViewModel.enableStreamingDiarization = false
            }
        }
        .onChange(of: settings.sortformerModeRaw) { _, _ in
            Task { @MainActor in syncSortformerMode() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if os(iOS)
            if newPhase == .active {
                Task { await streamViewModel.liveActivityManager.handleAppEnteredForeground() }
            }
            #endif
        }
        #if os(iOS)
        .onChange(of: sdkCoordinator.pipelineRows) { _, rows in
            let isSessionActive = streamViewModel.isStreaming || transcribeViewModel.isTranscribing
            Task {
                await streamViewModel.liveActivityManager.handleModelStateChange(
                    pipelineRows: rows,
                    isSessionActive: isSessionActive
                )
            }
        }
        #endif
        .task {
            await sdkCoordinator.updateModelList()
            if !sdkCoordinator.availableModelNames.contains(settings.selectedModel) {
                if let first = sdkCoordinator.modelStore.availableModels.flatMap({ $0.models }).first {
                    settings.selectedModel = first
                }
            }
        }
    }

    // MARK: - Main Navigation

    private var mainNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selectedFeature: $selectedFeature
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 350)
        } detail: {
            detailPane
                #if os(macOS)
                .environment(\.openPlaygroundSettings, { showSettings = true })
                #endif
                .toolbar {
                    #if os(macOS)
                    // The transcribe/stream tabs place their own Settings button last (matching
                    // iOS ordering); this one covers History and the empty selection. Hidden
                    // while Settings occupies the detail column -- Done is the way back.
                    if !showSettings && selectedFeature != .transcribe && selectedFeature != .stream {
                        ToolbarItem {
                            Button {
                                showSettings = true
                            } label: {
                                Label("Settings", systemImage: "slider.horizontal.3")
                            }
                            .keyboardShortcut(",", modifiers: .command)
                        }
                    }
                    #endif
                    if (selectedFeature == .transcribe || selectedFeature == .stream) && !isShowingEmbeddedSettings {
                        ToolbarItem {
                            Button {
                                let text = copyableText()
                                #if os(iOS)
                                UIPasteboard.general.string = text
                                #elseif os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                #endif
                            } label: {
                                Label("Copy Text", systemImage: "doc.on.doc")
                            }
                        }
                        ToolbarItem {
                            Button {
                                #if os(iOS)
                                isTranscriptionFullscreen = true
                                #elseif os(macOS)
                                withAnimation {
                                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                                }
                                #endif
                            } label: {
                                Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .keyboardShortcut("f", modifiers: .command)
                        }
                    }
                }
        }
        .navigationTitle("Argmax Playground")
    }

    /// Detail column content. On macOS the toolbar settings button swaps Settings into the detail
    /// column in place of the selected feature (no modal); iOS presents Settings as a
    /// sheet from the sidebar header instead.
    @ViewBuilder
    private var detailPane: some View {
        #if os(macOS)
        if showSettings {
            SettingsView(isPresented: $showSettings, isStreamMode: selectedFeature == .stream)
        } else {
            detailView
        }
        #else
        detailView
        #endif
    }

    /// Whether the detail column is currently showing embedded Settings (macOS only), which
    /// hides the transcription-specific toolbar items.
    private var isShowingEmbeddedSettings: Bool {
        #if os(macOS)
        return showSettings
        #else
        return false
        #endif
    }

    // MARK: - Detail Routing

    @ViewBuilder
    private var detailView: some View {
        switch selectedFeature {
        case .transcribe:
            TranscribeTabView()
        case .stream:
            StreamTabView()
        case .history:
            HistoryView()
        case nil:
            VStack {
                Image(systemName: "waveform")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("Select a feature from the sidebar")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Focus Mode (iOS)

    #if os(iOS)
    private var focusModeCover: some View {
        NavigationStack {
            detailView
                // Tells the tab views to collapse their trailing icons into one overflow menu so
                // the branded label below keeps the leading slot.
                .environment(\.isFocusMode, true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Playground")
                                .font(.headline)
                            Text("by Argmax")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isTranscriptionFullscreen = false } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        .accessibilityLabel("Exit focus mode")
                    }
                }
        }
    }
    #endif

    // MARK: - Helpers

    private func syncSortformerMode() {
        guard settings.selectedDiarizationModel == .some(.sortformer) else { return }
        let userMode = SortformerModeSelection(rawValue: settings.sortformerModeRaw) ?? .automatic
        let effectiveMode: SortformerModeSelection
        switch userMode {
        case .automatic:
            effectiveMode = selectedFeature == .stream ? .realtime : .prerecorded
        case .realtime, .prerecorded:
            effectiveMode = userMode
        }
        // Sortformer mode is applied at load and on feature switches; before the model is
        // loaded there is nothing to configure (and the SDK would just throw).
        guard sdkCoordinator.isSortformerLoaded else { return }
        do {
            try sdkCoordinator.configureSortformerMode(effectiveMode)
        } catch {
            Logging.error("Failed to configure Sortformer mode: \(error)")
        }
    }

    private func copyableText() -> String {
        switch selectedFeature {
        case .stream:
            var parts: [String] = []
            if let device = streamViewModel.deviceResult {
                let segs = device.confirmedSegments + device.hypothesisSegments
                let text = TranscriptionUtilities.formatSegments(segs, withTimestamps: true).joined(separator: " ")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append("Device: " + text)
                }
            }
            if let system = streamViewModel.systemResult {
                let segs = system.confirmedSegments + system.hypothesisSegments
                let text = TranscriptionUtilities.formatSegments(segs, withTimestamps: true).joined(separator: " ")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append("System: " + text)
                }
            }
            return parts.joined(separator: "\n")
        case .transcribe:
            return TranscriptionUtilities.formatSegments(
                transcribeViewModel.confirmedSegments + transcribeViewModel.unconfirmedSegments,
                withTimestamps: true
            ).joined(separator: "\n")
        default:
            return ""
        }
    }

}

#Preview {
    #if os(macOS)
    let sdkCoordinator = ArgmaxSDKCoordinator(keyProvider: ObfuscatedKeyProvider(mask: 12))
    let processDiscoverer = AudioProcessDiscoverer()
    let deviceDiscoverer = AudioDeviceDiscoverer()
    let streamViewModel = StreamViewModel(
        sdkCoordinator: sdkCoordinator,
        audioProcessDiscoverer: processDiscoverer,
        audioDeviceDiscoverer: deviceDiscoverer
    )
    let settings = AppSettings()
    let transcribeViewModel = TranscribeViewModel(sdkCoordinator: sdkCoordinator, settings: settings)
    let sessionHistory = SessionHistoryManager()
    ContentView()
        .frame(width: 800, height: 500)
        .environmentObject(streamViewModel)
        .environmentObject(transcribeViewModel)
        .environmentObject(processDiscoverer)
        .environmentObject(deviceDiscoverer)
        .environmentObject(sdkCoordinator)
        .environmentObject(sessionHistory)
        .environmentObject(settings)
    #else
    let sdkCoordinator = ArgmaxSDKCoordinator(keyProvider: ObfuscatedKeyProvider(mask: 12))
    let deviceDiscoverer = AudioDeviceDiscoverer()
    let liveActivityManager = LiveActivityManager()
    let settings = AppSettings()
    let streamViewModel = StreamViewModel(
        sdkCoordinator: sdkCoordinator,
        audioDeviceDiscoverer: deviceDiscoverer,
        liveActivityManager: liveActivityManager
    )
    let transcribeViewModel = TranscribeViewModel(sdkCoordinator: sdkCoordinator, settings: settings)
    let sessionHistory = SessionHistoryManager()
    ContentView()
        .environmentObject(streamViewModel)
        .environmentObject(transcribeViewModel)
        .environmentObject(deviceDiscoverer)
        .environmentObject(sdkCoordinator)
        .environmentObject(sessionHistory)
        .environmentObject(settings)
    #endif
}
