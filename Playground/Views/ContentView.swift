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

    init(analyticsLogger: AnalyticsLogger = NoOpAnalyticsLogger()) {
        self.analyticsLogger = analyticsLogger
    }

    var body: some View {
        Group {
            if isTranscriptionFullscreen {
                fullscreenView
            } else {
                mainNavigation
            }
        }
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
            detailView
                .toolbar {
                    if selectedFeature == .transcribe || selectedFeature == .stream {
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
                            Button { isTranscriptionFullscreen = true } label: {
                                Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .keyboardShortcut("f", modifiers: .command)
                        }
                    }
                }
        }
        .navigationTitle("Argmax Playground")
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

    // MARK: - Fullscreen

    private var fullscreenView: some View {
        ZStack(alignment: .topTrailing) {
            #if os(iOS)
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Playground")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("by Argmax")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .offset(x: 2, y: -2)
                    }
                    Spacer()
                    Button { isTranscriptionFullscreen = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.top)

                detailView
            }
            #else
            detailView
            Button { isTranscriptionFullscreen = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.secondary)
                    .padding()
            }
            .buttonStyle(.plain)
            #endif
        }
    }

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
