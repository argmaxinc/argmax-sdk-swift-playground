import SwiftUI
import Argmax

struct SettingsView: View {
    @Binding var isPresented: Bool
    let isStreamMode: Bool
    var onDone: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @State private var showRestoreConfirmation = false

    var body: some View {
        #if os(iOS)
        NavigationView {
            settingsContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if settings.hasNonDefaultSettings { restoreDefaultsButton }
                    }
                    ToolbarItem(placement: .topBarTrailing) { dismissButton }
                }
        }
        #else
        VStack(spacing: 0) {
            settingsHeader
            settingsContent
                .frame(minWidth: 520, minHeight: 540)
        }
        #endif
    }

    private var settingsHeader: some View {
        HStack {
            restoreDefaultsButton
            Spacer()
            Text("Settings").font(.title2)
            Spacer()
            dismissButton
        }
        .padding()
    }

    private var dismissButton: some View {
        Button {
            isPresented = false
            Task { @MainActor in onDone?() }
        } label: {
            Label("Done", systemImage: "xmark.circle.fill")
                .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    private var restoreDefaultsButton: some View {
        Button(role: .destructive) {
            showRestoreConfirmation = true
        } label: {
            Label("Restore Defaults", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.plain)
        .opacity(settings.hasNonDefaultSettings ? 1 : 0)
        .allowsHitTesting(settings.hasNonDefaultSettings)
    }

    private var restoreAlert: some View {
        EmptyView()
            .alert("Restore Defaults", isPresented: $showRestoreConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Restore", role: .destructive) { settings.restoreDefaults() }
            } message: {
                Text("All settings will be reset to their default values. Model selection and custom vocabulary will not be affected.")
            }
    }

    private var settingsContent: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DecodingOptionsSection()
                StreamSettingsSection(isStreamMode: isStreamMode)
                DiarizationSettingsSection(isStreamMode: isStreamMode)
            }
            .padding(16)
        }
        .background(restoreAlert)
        #else
        List {
            DecodingOptionsSection()
            StreamSettingsSection(isStreamMode: isStreamMode)
            DiarizationSettingsSection(isStreamMode: isStreamMode)
        }
        .navigationTitle("Settings")
        .background(restoreAlert)
        #endif
    }
}

// MARK: - macOS section container

#if os(macOS)
struct SettingsGroupBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        GroupBox(
            label: Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }
}
#endif

// MARK: - Decoding Options Section

struct DecodingOptionsSection: View {
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var settings: AppSettings

    @State private var concurrentWorkerCountLocal: Double = 0
    @State private var temperatureStartLocal: Double = 0
    @State private var fallbackCountLocal: Double = 0
    @State private var compressionCheckWindowLocal: Double = 0
    @State private var sampleLengthLocal: Double = 0

    private var availableLanguages: [String] {
        Constants.languages.map { $0.key }.sorted()
    }

    var body: some View {
        container
            .onAppear { syncFromSettings() }
            .onChange(of: settings.concurrentWorkerCount) { concurrentWorkerCountLocal = settings.concurrentWorkerCount }
            .onChange(of: settings.temperatureStart) { temperatureStartLocal = settings.temperatureStart }
            .onChange(of: settings.fallbackCount) { fallbackCountLocal = settings.fallbackCount }
            .onChange(of: settings.compressionCheckWindow) { compressionCheckWindowLocal = settings.compressionCheckWindow }
            .onChange(of: settings.sampleLength) { sampleLengthLocal = settings.sampleLength }
    }

    @ViewBuilder
    private var container: some View {
        #if os(macOS)
        SettingsGroupBox("Decoding Options") { rows }
        #else
        Section(header: Text("Decoding Options")) { rows }
        #endif
    }

    private func syncFromSettings() {
        concurrentWorkerCountLocal = settings.concurrentWorkerCount
        temperatureStartLocal = settings.temperatureStart
        fallbackCountLocal = settings.fallbackCount
        compressionCheckWindowLocal = settings.compressionCheckWindow
        sampleLengthLocal = settings.sampleLength
    }

    @ViewBuilder
    private var rows: some View {
        HStack {
            Text("Task")
            Spacer()
            Picker("", selection: $settings.selectedTask) {
                ForEach(DecodingTask.allCases, id: \.self) { task in
                    Text(task.description.capitalized).tag(task.description)
                }
            }
            .pickerStyle(.segmented)
        }

        HStack {
            LabeledContent {
                Picker("", selection: $settings.selectedLanguage) {
                    ForEach(availableLanguages, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!(sdkCoordinator.whisperKit?.modelVariant.isMultilingual ?? false))
            } label: {
                Label("Source Language", systemImage: "globe")
            }
        }

        toggleRow("Show Timestamps", isOn: $settings.enableTimestamps)
        toggleRow("Special Characters", isOn: $settings.enableSpecialCharacters)
        toggleRow("Decoder Preview", isOn: $settings.enableDecoderPreview)
        toggleRow("Decoding Stats", isOn: $settings.showNerdStats)
        toggleRow("Prompt Prefill", isOn: $settings.enablePromptPrefill)
        toggleRow("Cache Prefill", isOn: $settings.enableCachePrefill)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Chunking Strategy")
                Spacer()
                Picker("", selection: $settings.chunkingStrategy) {
                    Text("None").tag(ChunkingStrategy.none)
                    Text("VAD").tag(ChunkingStrategy.vad)
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Text("Workers:")
                Slider(value: $concurrentWorkerCountLocal, in: 0...32, step: 1) { editing in
                    if !editing { settings.concurrentWorkerCount = concurrentWorkerCountLocal }
                }
                Text(concurrentWorkerCountLocal.formatted(.number))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)

        sliderRow("Temperature", value: $temperatureStartLocal, range: 0...1, step: 0.1) {
            if !$0 { settings.temperatureStart = temperatureStartLocal }
        }
        sliderRow("Fallback Count", value: $fallbackCountLocal, range: 0...5, step: 1) {
            if !$0 { settings.fallbackCount = fallbackCountLocal }
        }
        sliderRow("Compression Tokens", value: $compressionCheckWindowLocal, range: 0...100, step: 5) {
            if !$0 { settings.compressionCheckWindow = compressionCheckWindowLocal }
        }
        sliderRow("Max Tokens/Loop", value: $sampleLengthLocal, range: 0...Double(Constants.maxTokenContext), step: 4) {
            if !$0 { settings.sampleLength = sampleLengthLocal }
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Toggle("", isOn: isOn)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, onEditingChanged: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(label)
            HStack {
                Slider(value: value, in: range, step: step, onEditingChanged: onEditingChanged)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(step < 1 ? 1 : 0))))
                    .frame(width: 44, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - Stream Settings Section

struct StreamSettingsSection: View {
    let isStreamMode: Bool
    @EnvironmentObject private var settings: AppSettings

    @State private var silenceThresholdLocal: Double = 0
    @State private var maxSilenceBufferLengthLocal: Double = 10
    @State private var minProcessIntervalPositionLocal: Double = 0
    @State private var transcribeIntervalLocal: Double = 0
    @State private var tokenConfirmationsNeededLocal: Double = 1

    static func minProcessIntervalToPosition(_ value: Double) -> Double {
        if value <= 2.0 { return value / 4.0 }
        return 0.5 + (value - 2.0) / 26.0
    }

    static func positionToMinProcessInterval(_ position: Double) -> Double {
        let clamped = min(max(position, 0.0), 1.0)
        if clamped <= 0.5 { return (clamped * 4.0 * 10.0).rounded() / 10.0 }
        return (2.0 + (clamped - 0.5) * 26.0).rounded()
    }

    var body: some View {
        container
            .onAppear { syncFromSettings() }
            .onChange(of: settings.silenceThreshold) { silenceThresholdLocal = settings.silenceThreshold }
            .onChange(of: settings.maxSilenceBufferLength) { maxSilenceBufferLengthLocal = settings.maxSilenceBufferLength }
            .onChange(of: settings.minProcessInterval) { minProcessIntervalPositionLocal = Self.minProcessIntervalToPosition(settings.minProcessInterval) }
            .onChange(of: settings.transcribeInterval) { transcribeIntervalLocal = settings.transcribeInterval }
            .onChange(of: settings.tokenConfirmationsNeeded) { tokenConfirmationsNeededLocal = settings.tokenConfirmationsNeeded }
    }

    @ViewBuilder
    private var container: some View {
        #if os(macOS)
        SettingsGroupBox("Stream Mode") { rows }
        #else
        Section(header: Text("Stream Mode")) { rows }
        #endif
    }

    private func syncFromSettings() {
        silenceThresholdLocal = settings.silenceThreshold
        maxSilenceBufferLengthLocal = settings.maxSilenceBufferLength
        minProcessIntervalPositionLocal = Self.minProcessIntervalToPosition(settings.minProcessInterval)
        transcribeIntervalLocal = settings.transcribeInterval
        tokenConfirmationsNeededLocal = settings.tokenConfirmationsNeeded
    }

    @ViewBuilder
    private var rows: some View {
        HStack {
            Picker("Mode", selection: $settings.transcriptionModeRaw) {
                ForEach(TranscriptionModeSelection.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
        }

        if settings.transcriptionModeRaw == TranscriptionModeSelection.voiceTriggered.rawValue {
            VStack(alignment: .center, spacing: 2) {
                Text("Silence Threshold")
                HStack {
                    Slider(value: $silenceThresholdLocal, in: 0...1, step: 0.05) { editing in
                        if !editing { settings.silenceThreshold = silenceThresholdLocal }
                    }
                    Text(silenceThresholdLocal.formatted(.number.precision(.fractionLength(1))))
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            VStack(alignment: .center, spacing: 2) {
                Text("Max Silence Buffer")
                HStack {
                    Slider(value: $maxSilenceBufferLengthLocal, in: 10...60, step: 1) { editing in
                        if !editing { settings.maxSilenceBufferLength = maxSilenceBufferLengthLocal }
                    }
                    Text(maxSilenceBufferLengthLocal.formatted(.number.precision(.fractionLength(0))))
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            VStack(alignment: .center, spacing: 2) {
                Text("Min Process Interval")
                HStack {
                    Slider(value: $minProcessIntervalPositionLocal, in: 0...1) { editing in
                        if !editing { settings.minProcessInterval = Self.positionToMinProcessInterval(minProcessIntervalPositionLocal) }
                    }
                    let displayVal = Self.positionToMinProcessInterval(minProcessIntervalPositionLocal)
                    Text(displayVal <= 2
                         ? displayVal.formatted(.number.precision(.fractionLength(1)))
                         : displayVal.formatted(.number.precision(.fractionLength(0))))
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }

        VStack(alignment: .center, spacing: 2) {
            Text("Transcribe Interval")
            HStack {
                Slider(value: $transcribeIntervalLocal, in: 0...30) { editing in
                    if !editing { settings.transcribeInterval = transcribeIntervalLocal }
                }
                Text(transcribeIntervalLocal.formatted(.number.precision(.fractionLength(1))))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)

        VStack(alignment: .center, spacing: 2) {
            Text("Token Confirmations")
            HStack {
                Slider(value: $tokenConfirmationsNeededLocal, in: 1...10, step: 1) { editing in
                    if !editing { settings.tokenConfirmationsNeeded = tokenConfirmationsNeededLocal }
                }
                Text(tokenConfirmationsNeededLocal.formatted(.number))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - Diarization Settings Section

struct DiarizationSettingsSection: View {
    let isStreamMode: Bool

    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var streamViewModel: StreamViewModel
    @EnvironmentObject private var settings: AppSettings

    @State private var minGapLocal: Double = 0

    private var sortformerModeDescription: String {
        switch SortformerModeSelection(rawValue: settings.sortformerModeRaw) {
        case .automatic:
            let resolved = isStreamMode ? SortformerModeSelection.realtime : .prerecorded
            return "Automatically uses \(resolved.rawValue) mode based on active tab"
        case .realtime:
            return "Optimized for low-latency streaming diarization"
        case .prerecorded, .none:
            return "Optimized for high-throughput diarization"
        }
    }

    var body: some View {
        container
            .onAppear { minGapLocal = settings.minActiveOffsetRaw == -1.0 ? 0 : settings.minActiveOffsetRaw }
            .onChange(of: settings.minActiveOffsetRaw) { minGapLocal = settings.minActiveOffsetRaw == -1.0 ? 0 : settings.minActiveOffsetRaw }
    }

    @ViewBuilder
    private var container: some View {
        #if os(macOS)
        SettingsGroupBox("Diarization") { rows }
        #else
        Section(header: Text("Diarization")) { rows }
        #endif
    }

    @ViewBuilder
    private var rows: some View {
        if !isStreamMode && settings.selectedDiarizationModel != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mode")
                Picker("", selection: $settings.diarizationModeRaw) {
                    Text("Off").tag(DiarizationMode.disabled.rawValue)
                    Text("Sequential").tag(DiarizationMode.sequential.rawValue)
                    Text("Concurrent").tag(DiarizationMode.concurrent.rawValue)
                }
                .pickerStyle(.segmented)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }

        if isStreamMode && sdkCoordinator.isSortformerLoaded {
            HStack {
                Text("Filter Unknown Speakers")
                Spacer()
                Toggle("", isOn: $settings.streamingDiarizationFilterUnknown)
            }
        }

        if !isStreamMode && settings.selectedDiarizationModel?.isPyannote == true {
            HStack {
                Text("Exclusive Reconciliation")
                Spacer()
                Toggle("", isOn: $settings.useExclusiveReconciliation)
            }
        }

        if settings.selectedDiarizationModel?.isPyannote == true {
            HStack {
                Text("Speaker Info Strategy")
                Spacer()
                Picker("", selection: $settings.speakerInfoStrategyRaw) {
                    ForEach(SpeakerInfoStrategy.allCases, id: \.stringValue) { strategy in
                        Text(strategy.displayName).tag(strategy.stringValue)
                    }
                }
                .pickerStyle(.segmented)
            }

        }

        if settings.selectedDiarizationModel?.isSortformer == true {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sortformer Mode")
                Picker("", selection: $settings.sortformerModeRaw) {
                    Text("Auto").tag(SortformerModeSelection.automatic.rawValue)
                    Text("Real-time").tag(SortformerModeSelection.realtime.rawValue)
                    Text("Pre-recorded").tag(SortformerModeSelection.prerecorded.rawValue)
                }
                .pickerStyle(.segmented)
                Text(sortformerModeDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Max Word Gap")
                HStack {
                    Slider(value: $settings.sortformerMaxWordGap, in: 0.0...1.0, step: 0.01)
                    Text(String(format: "%.2fs", settings.sortformerMaxWordGap))
                        .frame(width: 50)
                }
                Text("Maximum gap between consecutive words that keeps them in the same speaker segment.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Tolerance")
                HStack {
                    Slider(value: $settings.sortformerTolerance, in: 0.0...1.0, step: 0.01)
                    Text(String(format: "%.2fs", settings.sortformerTolerance))
                        .frame(width: 50)
                }
                Text("Time tolerance for matching words to diarization segments.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}
