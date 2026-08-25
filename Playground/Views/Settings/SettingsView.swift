import SwiftUI
import Argmax
import CoreML
import Network

// MARK: - Settings destinations

/// Drill-in pages reachable from the Settings root: a flat root list of feature rows, each
/// navigating to one page that owns every option for that feature.
enum SettingsDestination: Hashable {
    case transcription
    case streaming
    case diarization
    case warmup
    case license
    case advanced
    case backgroundDownloadTest
    case remoteURLDownload
}

// MARK: - Root Settings

struct SettingsView: View {
    @Binding var isPresented: Bool
    let isStreamMode: Bool
    var onDone: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @State private var showRestoreConfirmation = false
    @State private var path: [SettingsDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            rootList
                .navigationTitle("Settings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .navigationDestination(for: SettingsDestination.self) { destination in
                    page(for: destination)
                        .settingsGrouped()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { dismissButton }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
    }

    private var rootList: some View {
        Form {
            // Model pages configure a loaded model, so an unloaded model's row is disabled
            // rather than leading to a page of no-op controls.
            Section("Models") {
                NavigationLink(value: SettingsDestination.transcription) {
                    SettingsRowLabel(
                        icon: "waveform", tint: .blue, title: "Transcription",
                        detail: isTranscriptionLoaded ? transcriptionDetail : "Not Loaded"
                    )
                }
                .disabled(!isTranscriptionLoaded)
                NavigationLink(value: SettingsDestination.streaming) {
                    SettingsRowLabel(
                        icon: "dot.radiowaves.left.and.right", tint: .red, title: "Streaming",
                        detail: isTranscriptionLoaded
                            ? TranscriptionModeSelection(rawValue: settings.transcriptionModeRaw)?.displayName
                            : "Not Loaded"
                    )
                }
                .disabled(!isTranscriptionLoaded)
                NavigationLink(value: SettingsDestination.diarization) {
                    SettingsRowLabel(
                        icon: "person.2.wave.2", tint: .purple, title: "Diarization",
                        detail: diarizationDetail
                    )
                }
                .disabled(!isDiarizationLoaded)
            }

            Section {
                NavigationLink(value: SettingsDestination.advanced) {
                    SettingsRowLabel(icon: "hammer", tint: .gray, title: "Advanced")
                }
            }

            Section {
                Button("Restore Defaults", role: .destructive) {
                    showRestoreConfirmation = true
                }
                .frame(maxWidth: .infinity)
                .disabled(!settings.hasNonDefaultSettings)
            }
        }
        .settingsGrouped()
        .alert("Restore Defaults", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) { settings.restoreDefaults() }
        } message: {
            Text("All settings will be reset to their default values. Model selection and custom vocabulary will not be affected.")
        }
    }

    @ViewBuilder
    private func page(for destination: SettingsDestination) -> some View {
        switch destination {
        case .transcription:
            TranscriptionSettingsPage()
        case .streaming:
            StreamingSettingsPage()
        case .diarization:
            DiarizationSettingsPage(isStreamMode: isStreamMode)
        case .warmup:
            WarmupSettingsPage()
        case .license:
            LicenseSettingsPage()
        case .advanced:
            AdvancedSettingsPage()
        case .backgroundDownloadTest:
            BackgroundDownloadTestPage()
        case .remoteURLDownload:
            RemoteURLDownloadPage()
        }
    }

    /// Selected transcription model family, e.g. "Whisper" / "Qwen3-ASR", shown as the row's
    /// trailing detail the way iOS Settings previews a page's key value on its root row.
    private var transcriptionDetail: String? {
        guard !settings.selectedModel.isEmpty else { return nil }
        return TranscriptionModelFamily(modelName: settings.selectedModel).displayName
    }

    /// A loaded transcriber gates both the Transcription and Streaming rows: streaming runs
    /// on the same transcription model.
    private var isTranscriptionLoaded: Bool {
        sdkCoordinator.whisperKitModelState == .loaded
    }

    private var isDiarizationLoaded: Bool {
        sdkCoordinator.speakerKitModelState == .loaded
    }

    private var diarizationDetail: String {
        guard let model = settings.selectedDiarizationModel else { return "Off" }
        return isDiarizationLoaded ? model.displayName : "Not Loaded"
    }

    private var dismissButton: some View {
        Button {
            isPresented = false
            Task { @MainActor in onDone?() }
        } label: {
            Text("Done").fontWeight(.semibold)
        }
        .keyboardShortcut(.cancelAction)
    }

}

// MARK: - Shared helpers

/// iOS-Settings-style row: tinted rounded-square icon, title, optional trailing detail.
struct SettingsRowLabel: View {
    let icon: String
    let tint: Color
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint))
            Text(title)
            Spacer()
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

extension View {
    /// System-Settings-style inset grouped form on macOS: grouped style (the default columnar
    /// style clips labels against the sheet edge) with switch toggles (the default checkboxes
    /// read as a dialog, not a settings pane). A no-op on iOS, where `Form` inside a
    /// `NavigationStack` is already grouped and toggles are already switches.
    @ViewBuilder
    func settingsGrouped() -> some View {
        #if os(macOS)
        self.formStyle(.grouped).toggleStyle(.switch)
        #else
        self
        #endif
    }
}

private func computeUnitRow(_ label: String, selection: Binding<MLComputeUnits>) -> some View {
    HStack {
        Text(label)
        Spacer()
        Picker("", selection: selection) {
            Text("CPU").tag(MLComputeUnits.cpuOnly)
            Text("GPU").tag(MLComputeUnits.cpuAndGPU)
            Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}


private func sliderRow(
    _ label: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    onEditingChanged: @escaping (Bool) -> Void
) -> some View {
    let fractionDigits = step < 0.1 ? 2 : (step < 1 ? 1 : 0)
    return VStack(alignment: .leading, spacing: 2) {
        HStack {
            Text(label)
            Spacer()
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(fractionDigits))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        Slider(value: value, in: range, step: step, onEditingChanged: onEditingChanged)
    }
    .padding(.vertical, 2)
}

/// "Reload Required?" prompt shared by pages whose settings only take effect at model load.
private struct ReloadRequiredAlert: ViewModifier {
    @Binding var isPresented: Bool
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator

    func body(content: Content) -> some View {
        content.alert("Reload Required?", isPresented: $isPresented) {
            Button("Reload Now") {
                guard !settings.selectedModel.isEmpty else { return }
                Task {
                    await sdkCoordinator.reset()
                    sdkCoordinator.requestLoadModels(modelName: settings.selectedModel, settings: settings)
                }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("This setting takes effect when the model loads. Reload now to apply the change?")
        }
    }
}

// MARK: - Info popover icon

/// Replaces inline explanation captions: an info icon that reveals the text in a floating
/// box -- on hover on macOS, on tap on iOS.
struct InfoPopoverIcon: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Button { isShowing.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        #if os(macOS)
        .onHover { isShowing = $0 }
        #endif
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            popoverContent
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        let body = Text(text)
            .font(.caption)
            .multilineTextAlignment(.leading)
            .padding(12)
            .frame(width: 280, alignment: .leading)
        #if os(iOS)
        body.presentationCompactAdaptation(.popover)
        #else
        body
        #endif
    }
}

// MARK: - Transcription page

/// Every transcription option in one place: transcriber-independent options first, then only the
/// a Model Specific section whose rows swap with the selected family, then
/// compute units. Options for families the
/// user hasn't selected are omitted entirely rather than shown disabled with a "Not loaded" tag.
struct TranscriptionSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator

    @State private var concurrentWorkerCountLocal: Double = 0
    @State private var temperatureStartLocal: Double = 0
    @State private var fallbackCountLocal: Double = 0
    @State private var compressionCheckWindowLocal: Double = 0
    @State private var sampleLengthLocal: Double = 0
    @State private var dictationSilenceThresholdLocal: Double = 0
    @State private var showReloadPrompt = false

    private var family: TranscriptionModelFamily {
        TranscriptionModelFamily(modelName: settings.selectedModel)
    }

    /// Whisper-family transcriber loaded: the Qwen load path nils `whisperKit` (the transcriber lives
    /// in `qwen` instead), so a non-nil `whisperKit` at `.loaded` means Whisper/Parakeet.
    private var isWhisperLoaded: Bool {
        sdkCoordinator.whisperKitModelState == .loaded && sdkCoordinator.whisperKit != nil
    }

    /// Qwen transcriber loaded: `.loaded` with a nil `whisperKit` means Qwen is the active transcriber.
    private var isQwenLoaded: Bool {
        sdkCoordinator.whisperKitModelState == .loaded && sdkCoordinator.whisperKit == nil
    }

    /// What `.auto` resolves to on this device (by physical memory), for the picker's info text.
    private var autoResolvedOptimizationName: String {
        ModelOptimizationMode.auto.resolved == .latencyOptimized
            ? "Latency Optimized" : "Memory Optimized"
    }

    var body: some View {
        Form {
            sharedSection
            modelSpecificSection
            computeUnitsSection
        }
        .navigationTitle("Transcription")
        .onAppear { syncFromSettings() }
        .onChange(of: settings.inverseTextNormalization) {
            if sdkCoordinator.whisperKitModelState == .loaded { showReloadPrompt = true }
        }
        .onChange(of: settings.qwenSpecDecode) {
            if isQwenLoaded { showReloadPrompt = true }
        }
        .onChange(of: settings.qwenOptimizationRaw) {
            if isQwenLoaded { showReloadPrompt = true }
        }
        .onChange(of: settings.encoderComputeUnits) {
            if isWhisperLoaded { showReloadPrompt = true }
        }
        .onChange(of: settings.decoderComputeUnits) {
            if isWhisperLoaded { showReloadPrompt = true }
        }
        .modifier(ReloadRequiredAlert(isPresented: $showReloadPrompt))
    }

    private func syncFromSettings() {
        concurrentWorkerCountLocal = settings.concurrentWorkerCount
        temperatureStartLocal = settings.temperatureStart
        fallbackCountLocal = settings.fallbackCount
        compressionCheckWindowLocal = settings.compressionCheckWindow
        sampleLengthLocal = settings.sampleLength
        dictationSilenceThresholdLocal = settings.dictationSilenceThreshold
    }

    private var sharedSection: some View {
        Section {
            HStack {
                Text("Chunking Strategy")
                Spacer()
                Picker("Chunking strategy", selection: $settings.chunkingStrategy) {
                    Text("None").tag(ChunkingStrategy.none)
                    Text("VAD").tag(ChunkingStrategy.vad)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            sliderRow("Workers", value: $concurrentWorkerCountLocal, range: 0...32, step: 1) {
                if !$0 { settings.concurrentWorkerCount = concurrentWorkerCountLocal }
            }

            Toggle("Inverse Text Normalization", isOn: $settings.inverseTextNormalization)
        } header: {
            Text("All Models")
        } footer: {
            Text("Inverse Text Normalization converts spoken numbers and dates to numerals. Applied when the model loads.")
        }
    }

    /// Options for the *selected* model's family only -- the header stays generic and the
    /// rows swap, so no family ever sees another family's knobs.
    private var modelSpecificSection: some View {
        Section {
            switch family {
            case .whisper: whisperRows
            case .parakeet: parakeetRows
            case .qwen: qwenRows
            }
        } header: {
            Text("Model Specific")
        } footer: {
            if family == .qwen {
                Text("Dictation Silence Threshold controls how much silence ends a dictation session. Lower is more responsive, higher tolerates longer pauses.")
            }
        }
    }

    @ViewBuilder
    private var whisperRows: some View {
        HStack {
            Text("Task")
            Spacer()
            Picker("Decoding task", selection: $settings.selectedTask) {
                ForEach(DecodingTask.allCases, id: \.self) { task in
                    Text(task.description.capitalized).tag(task.description)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }

        Toggle("Show Timestamps", isOn: $settings.enableTimestamps)
        Toggle("Special Characters", isOn: $settings.enableSpecialCharacters)
        Toggle("Decoder Preview", isOn: $settings.enableDecoderPreview)
        Toggle("Decoding Stats", isOn: $settings.showNerdStats)
        Toggle("Prompt Prefill", isOn: $settings.enablePromptPrefill)

        sliderRow("Temperature", value: $temperatureStartLocal, range: 0...1, step: 0.1) {
            if !$0 { settings.temperatureStart = temperatureStartLocal }
        }
        sliderRow("Fallback Count", value: $fallbackCountLocal, range: 0...5, step: 1) {
            if !$0 { settings.fallbackCount = fallbackCountLocal }
        }
        compressionTokensRow
        // Upper bound is the Whisper decoder's full token context (448). `Constants.maxTokenContext`
        // is deliberately half of that (224) since it doubles as the default sampling budget, so it
        // cannot be used as the ceiling here.
        sliderRow("Max Tokens/Loop", value: $sampleLengthLocal, range: 1...448, step: 1) {
            if !$0 { settings.sampleLength = sampleLengthLocal }
        }
    }

    @ViewBuilder
    private var parakeetRows: some View {
        Toggle("Special Characters", isOn: $settings.enableSpecialCharacters)
        Toggle("Decoder Preview", isOn: $settings.enableDecoderPreview)
        Toggle("Decoding Stats", isOn: $settings.showNerdStats)
    }

    @ViewBuilder
    private var qwenRows: some View {
        HStack {
            HStack(spacing: 4) {
                Text("Speculative Decoding")
                InfoPopoverIcon(text: "Draft-model speedup, applied when the model loads. Reload the model to apply a change.")
            }
            Spacer()
            Toggle("", isOn: $settings.qwenSpecDecode)
                .labelsHidden()
        }
        HStack {
            HStack(spacing: 4) {
                Text("Optimization")
                InfoPopoverIcon(text: "Memory/speed trade-off, applied when the model loads. Auto uses \(autoResolvedOptimizationName) on this device.")
            }
            Spacer()
            Picker("Optimization", selection: $settings.qwenOptimizationRaw) {
                Text("Auto").tag(ModelOptimizationMode.auto.rawValue)
                Text("Latency Optimized").tag(ModelOptimizationMode.latencyOptimized.rawValue)
                Text("Memory Optimized").tag(ModelOptimizationMode.memoryOptimized.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        sliderRow("Dictation Silence Threshold", value: $dictationSilenceThresholdLocal, range: 0...1, step: 0.05) {
            if !$0 { settings.dictationSilenceThreshold = dictationSilenceThresholdLocal }
        }
        compressionTokensRow
    }

    /// Whisper and Qwen both honor this; Parakeet does not.
    private var compressionTokensRow: some View {
        sliderRow("Compression Tokens", value: $compressionCheckWindowLocal, range: 0...100, step: 5) {
            if !$0 { settings.compressionCheckWindow = compressionCheckWindowLocal }
        }
    }

    private var computeUnitsSection: some View {
        Section {
            computeUnitRow("Audio Encoder", selection: $settings.encoderComputeUnits)
                .disabled(family == .qwen)
            computeUnitRow("Text Decoder", selection: $settings.decoderComputeUnits)
                .disabled(family == .qwen)
        } header: {
            Text("Compute Units")
        } footer: {
            Text(family == .qwen
                 ? "Neural Engine only — fixed for Qwen3-ASR."
                 : "Changes take effect on next model load.")
        }
    }
}

// MARK: - Streaming page

struct StreamingSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var silenceThresholdLocal: Double = 0
    @State private var maxSilenceBufferLengthLocal: Double = 10
    @State private var minProcessIntervalPositionLocal: Double = 0
    @State private var transcribeIntervalLocal: Double = 0

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
        Form {
            Section {
                Picker("Mode", selection: $settings.transcriptionModeRaw) {
                    ForEach(TranscriptionModeSelection.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)

                // Continuous (no step) to match the pre-redesign slider's granularity.
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Transcribe Interval")
                        Spacer()
                        Text(transcribeIntervalLocal.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $transcribeIntervalLocal, in: 0...30) { editing in
                        if !editing { settings.transcribeInterval = transcribeIntervalLocal }
                    }
                }
                .padding(.vertical, 2)
            }

            if settings.transcriptionModeRaw == TranscriptionModeSelection.voiceTriggered.rawValue {
                Section("Voice Trigger") {
                    sliderRow("Silence Threshold", value: $silenceThresholdLocal, range: 0...1, step: 0.05) {
                        if !$0 { settings.silenceThreshold = silenceThresholdLocal }
                    }
                    sliderRow("Max Silence Buffer", value: $maxSilenceBufferLengthLocal, range: 10...60, step: 1) {
                        if !$0 { settings.maxSilenceBufferLength = maxSilenceBufferLengthLocal }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Min Process Interval")
                            Spacer()
                            let displayVal = Self.positionToMinProcessInterval(minProcessIntervalPositionLocal)
                            Text(displayVal <= 2
                                 ? displayVal.formatted(.number.precision(.fractionLength(1)))
                                 : displayVal.formatted(.number.precision(.fractionLength(0))))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $minProcessIntervalPositionLocal, in: 0...1) { editing in
                            if !editing { settings.minProcessInterval = Self.positionToMinProcessInterval(minProcessIntervalPositionLocal) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Streaming")
        .onAppear { syncFromSettings() }
    }

    private func syncFromSettings() {
        silenceThresholdLocal = settings.silenceThreshold
        maxSilenceBufferLengthLocal = settings.maxSilenceBufferLength
        minProcessIntervalPositionLocal = Self.minProcessIntervalToPosition(settings.minProcessInterval)
        transcribeIntervalLocal = settings.transcribeInterval
    }
}

// MARK: - Diarization page

/// All SpeakerKit options on one page. Sections appear based on the *selected* diarization
/// model (Pyannote vs Sortformer) instead of splitting the two into separately-tagged
/// product sections.
struct DiarizationSettingsPage: View {
    let isStreamMode: Bool

    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var settings: AppSettings
    @State private var showReloadPrompt = false

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
        Form {
            generalSection
            if settings.selectedDiarizationModel?.isSortformer == true {
                sortformerSection
            }
            if settings.selectedDiarizationModel?.isPyannote == true {
                pyannoteComputeUnitsSection
            }
        }
        .navigationTitle("Diarization")
        .onChange(of: settings.segmenterComputeUnits) {
            if sdkCoordinator.speakerKitModelState == .loaded { showReloadPrompt = true }
        }
        .onChange(of: settings.embedderComputeUnits) {
            if sdkCoordinator.speakerKitModelState == .loaded { showReloadPrompt = true }
        }
        .modifier(ReloadRequiredAlert(isPresented: $showReloadPrompt))
    }

    @ViewBuilder
    private var generalSection: some View {
        Section {
            if !isStreamMode && settings.selectedDiarizationModel != nil {
                // Label above the segmented control: three segments need the full row
                // width, and a side label gets crushed to one character per line.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mode")
                    Picker("Diarization mode", selection: $settings.diarizationModeRaw) {
                        Text("Off").tag(DiarizationMode.disabled.rawValue)
                        Text("Sequential").tag(DiarizationMode.sequential.rawValue)
                        Text("Concurrent").tag(DiarizationMode.concurrent.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            if !isStreamMode && settings.selectedDiarizationModel?.isPyannote == true {
                Toggle("Exclusive Reconciliation", isOn: $settings.useExclusiveReconciliation)
            }

            if settings.selectedDiarizationModel != nil && settings.diarizationMode != .disabled {
                Toggle("Group Bubbles", isOn: $settings.groupSpeakerBubbles)
            }

            if settings.selectedDiarizationModel != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speaker Info Strategy")
                    Picker("Speaker info strategy", selection: $settings.speakerInfoStrategyRaw) {
                        ForEach(SpeakerInfoStrategy.allCases, id: \.stringValue) { strategy in
                            Text(strategy.displayName).tag(strategy.stringValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var sortformerSection: some View {
        Section {
            if isStreamMode {
                Toggle("Filter Unknown Speakers", isOn: $settings.streamingDiarizationFilterUnknown)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Sortformer Mode")
                    InfoPopoverIcon(text: sortformerModeDescription)
                }
                Picker("Sortformer mode", selection: $settings.sortformerModeRaw) {
                    Text("Auto").tag(SortformerModeSelection.automatic.rawValue)
                    Text("Real-time").tag(SortformerModeSelection.realtime.rawValue)
                    Text("Pre-recorded").tag(SortformerModeSelection.prerecorded.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    HStack(spacing: 4) {
                        Text("Max Word Gap")
                        InfoPopoverIcon(text: "Maximum gap between consecutive words that keeps them in the same speaker segment.")
                    }
                    Spacer()
                    Text(String(format: "%.2fs", settings.sortformerMaxWordGap))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.sortformerMaxWordGap, in: 0.0...1.0, step: 0.01)
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    HStack(spacing: 4) {
                        Text("Tolerance")
                        InfoPopoverIcon(text: "Time tolerance for matching words to diarization segments.")
                    }
                    Spacer()
                    Text(String(format: "%.2fs", settings.sortformerTolerance))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.sortformerTolerance, in: 0.0...1.0, step: 0.01)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Sortformer")
        }
    }

    private var pyannoteComputeUnitsSection: some View {
        Section {
            computeUnitRow("Segmenter", selection: $settings.segmenterComputeUnits)
            computeUnitRow("Embedder", selection: $settings.embedderComputeUnits)
        } header: {
            Text("Pyannote Compute Units")
        } footer: {
            Text("Changes take effect on next model load.")
        }
    }
}

// MARK: - License page

/// License status plus re-authentication with a different `ax_` API key. The key is used once
/// to obtain a fresh license and is never persisted by the app; the license tokens the SDK
/// creates with it live in the keychain and outlast the key (and app restarts).
struct LicenseSettingsPage: View {
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator

    @State private var info: LicenseInfo?
    @State private var newKey = ""
    @State private var isReauthenticating = false
    @State private var reauthResult: String?
    @State private var showResetConfirmation = false
    @State private var didReset = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Mirrors `ArgmaxConfig`'s preconditions ("ax_" prefix, and specifically not an "axst_"
    /// SwiftPM token) so an invalid paste can never reach the crashing precondition.
    private var keyIsPlausible: Bool {
        newKey.hasPrefix("ax_") && newKey.count > 3
    }

    var body: some View {
        Form {
            statusSection
            reauthenticateSection
            resetSection
        }
        .navigationTitle("License")
        .task { info = await ArgmaxSDK.licenseInfo() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { info = await ArgmaxSDK.licenseInfo() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Pro Access") {
                if let info {
                    Text(info.proAccess ? "Valid" : "Invalid")
                        .foregroundStyle(info.proAccess ? .green : .red)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Subscription", value: info?.proAccess == true ? info?.subscriptionType ?? "—" : "—")
            LabeledContent("Features", value: info?.features?.joined(separator: ", ") ?? "—")
            LabeledContent("License Expires", value: info?.licenseTokenExpiresAt.map { Self.dateFormatter.string(from: $0) } ?? "—")
            LabeledContent("Last Validated", value: info?.lastSuccessfulLicense.map { Self.dateFormatter.string(from: $0) } ?? "—")
        }
    }

    private var reauthenticateSection: some View {
        Section {
            SecureField("ax_…", text: $newKey)
                .disableAutocorrection(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            if !newKey.isEmpty && !keyIsPlausible {
                Text(newKey.hasPrefix("axst_")
                     ? "That is a SwiftPM access token. API keys start with “ax_”."
                     : "API keys start with “ax_”.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                reauthenticate()
            } label: {
                if isReauthenticating {
                    ProgressView()
                } else {
                    Text("Re-authenticate")
                }
            }
            .disabled(!keyIsPlausible || isReauthenticating)

            if let reauthResult {
                Text(reauthResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Re-authenticate")
        } footer: {
            Text("Replaces this device's license with one created from the key's account. "
                + "The key is used once and not stored; the license it creates is kept by the SDK "
                + "in the keychain and remains active across launches until it expires or you "
                + "re-authenticate again.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset License", role: .destructive) { showResetConfirmation = true }
                .confirmationDialog("Remove this device's license?", isPresented: $showResetConfirmation) {
                    Button("Reset License", role: .destructive) { resetLicense() }
                }
            if didReset {
                Text("License cleared. The next app launch will re-authenticate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetLicense() {
        Task { @MainActor in
            await ArgmaxSDK.reset(includingLicense: true)
            info = nil
            didReset = true
        }
    }

    private func reauthenticate() {
        isReauthenticating = true
        reauthResult = nil
        let key = newKey
        Task { @MainActor in
            let refreshed = await sdkCoordinator.reauthenticate(apiKey: key)
            info = refreshed
            reauthResult = refreshed.proAccess
                ? "License refreshed — Pro access is active."
                : "Re-authentication finished, but the license does not grant Pro access. Check the key and network."
            newKey = ""
            isReauthenticating = false
        }
    }
}

// MARK: - Warmup page

/// Warmup diagnostics for the SDK-managed background warmup: scheduler status, the
/// testing-schedule switch, on-demand warming, and the run history.
///
/// Shared by both platforms because the warmup model is the same one; only the rows that
/// describe a platform's delivery mechanism differ. iOS shows Background App Refresh (the
/// usual reason a `BGProcessingTask` never fires); macOS shows the warm-while-closed launch
/// agent, which has no iOS equivalent.
///
struct WarmupSettingsPage: View {
    /// The schedules the page offers. The SDK's `.repeating` carries an interval and a
    /// charging flag; we surface two fixed debug cadences rather than a free slider so
    /// each option maps to exactly one `WarmupSchedule` value.
    private enum ScheduleOption: String, CaseIterable, Identifiable {
        case daily = "Daily (default)"
        case immediate = "Immediate once"
        case everyThreeMinutes = "Every 3 min, no charger"
        case everyFifteenMinutes = "Every 15 min, no charger"

        var id: String { rawValue }

        var schedule: WarmupSchedule {
            switch self {
            case .daily: return .daily
            case .immediate: return .immediateOnce
            // The interval is the request's earliest date -- iOS still picks the actual
            // moment, so expect single-digit-minute latitude, not a metronome.
            case .everyThreeMinutes: return .repeating(interval: 3 * 60, requiresCharging: false)
            case .everyFifteenMinutes: return .repeating(interval: 15 * 60, requiresCharging: false)
            }
        }

        init(schedule: WarmupSchedule) {
            switch schedule {
            case .immediateOnce: self = .immediate
            case .repeating(let interval, _): self = interval <= 3 * 60 ? .everyThreeMinutes : .everyFifteenMinutes
            case .daily: self = .daily
            @unknown default: self = .daily
            }
        }
    }

    @EnvironmentObject private var settings: AppSettings
    @State private var option: ScheduleOption
    @State private var runs: [WarmupRunRecord] = []
    @State private var nextScheduled: Date?
    @State private var warming = false
    @State private var showClearConfirm = false
    #if os(macOS)
    @State private var agentStatus: WarmupAgentStatus = .notFound
    @State private var agentBusy = false
    @State private var agentError: String?
    #endif

    init() {
        // Reading is all init does -- navigationDestination can construct this view
        // speculatively, so side effects (the launchd status query and any re-arm)
        // wait for onAppear.
        _option = State(initialValue: ScheduleOption(schedule: ModelWarmup.currentSchedule()))
    }

    var body: some View {
        Form {
            statusSection
            #if os(macOS)
            warmWhileClosedSection
            #endif
            scheduleSection
            actionsSection
            historySection
        }
        .navigationTitle("Model Warmup")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear {
            refresh()
            #if os(macOS)
            // The agent's cadence persists across relaunches while the in-process scheduler
            // reverts to .daily. When the agent is enabled, its schedule is the truth for
            // what runs while the app is closed -- re-arm in-process and move the picker to
            // match (the onChange re-arm this triggers is idempotent).
            if ModelWarmup.backgroundAgentStatus() == .enabled {
                let agentSchedule = ModelWarmup.backgroundAgentSchedule()
                if agentSchedule != ModelWarmup.currentSchedule() {
                    ModelWarmup.setSchedule(agentSchedule)
                }
                let agentOption = ScheduleOption(schedule: agentSchedule)
                if option != agentOption { option = agentOption }
            }
            #endif
        }
        .onChange(of: option) { _, newValue in
            ModelWarmup.setSchedule(newValue.schedule)
            // Resubmission is async; give it a beat before re-querying the
            // authoritative next-eligible date.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                nextScheduled = await ModelWarmup.nextScheduledWarmup()
            }
            #if os(macOS)
            // `setSchedule` is per-launch and in-process only. The agent keeps its own
            // persisted cadence (the app is not running when it fires), so a registered
            // agent has to be told separately or it keeps the cadence it was enabled with.
            if settings.warmWhileClosed {
                Task { @MainActor in
                    agentStatus = (try? await ModelWarmup.enableBackgroundAgent(schedule: newValue.schedule))
                        ?? ModelWarmup.backgroundAgentStatus()
                }
            }
            #endif
        }
    }

    private var statusSection: some View {
        Section("Scheduler status") {
            // Authoritative on iOS (straight from BGTaskScheduler's pending requests); an
            // estimate on macOS, where NSBackgroundActivityScheduler picks the moment.
            LabeledContent("Next eligible") {
                if let nextScheduled {
                    Text(nextScheduled, format: .dateTime.month().day().hour().minute())
                } else {
                    Text("No request pending")
                        .foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            // User-disabled Background App Refresh is the most common reason a scheduled
            // task never fires, so call it out before the user blames the SDK.
            LabeledContent("Background App Refresh") {
                switch UIApplication.shared.backgroundRefreshStatus {
                case .available:  Text("On").foregroundStyle(.green)
                case .denied:     Text("Off — enable in Settings").foregroundStyle(.red)
                case .restricted: Text("Restricted").foregroundStyle(.orange)
                @unknown default: Text("Unknown").foregroundStyle(.secondary)
                }
            }
            #endif
        }
    }

    #if os(macOS)
    /// The warm-while-closed launch agent. Registering one adds the app to Login Items &
    /// Extensions, so it stays behind an explicit switch rather than the SDK's
    /// ship-the-plist auto-enable (see `Playground.registerModelWarmup`).
    private var warmWhileClosedSection: some View {
        Section {
            Toggle("Warm while app is closed", isOn: Binding(
                get: { settings.warmWhileClosed },
                set: { setWarmWhileClosed($0) }
            ))
            .disabled(agentBusy)

            LabeledContent("Login item") {
                switch agentStatus {
                case .enabled:
                    Text("Enabled").foregroundStyle(.green)
                case .requiresApproval:
                    // Only the user can undo this one, so offer the deep link rather than
                    // a retry that cannot succeed.
                    Button("Turned off — open Login Items") {
                        ModelWarmup.openLoginItemsSettings()
                    }
                    .foregroundStyle(.orange)
                case .notRegistered:
                    Text("Not registered").foregroundStyle(.secondary)
                case .notFound:
                    Text("Not registered yet").foregroundStyle(.secondary)
                @unknown default:
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }

            if let agentError {
                Text(agentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Warm while closed")
        } footer: {
            Text("Runs Playground headless about once an hour to check whether a warm is due, "
                + "following the warmup schedule (daily by default). It appears in System Settings > "
                + "General > Login Items & Extensions, runs only while you are logged in and awake, "
                + "and skips on battery. Warming while the app is open needs no login item.")
        }
    }

    private func setWarmWhileClosed(_ enabled: Bool) {
        agentBusy = true
        agentError = nil
        Task { @MainActor in
            if enabled {
                do {
                    // Persist only on success: a failed registration must not leave a switch
                    // claiming the agent is on.
                    agentStatus = try await ModelWarmup.enableBackgroundAgent(schedule: option.schedule)
                    settings.warmWhileClosed = true
                } catch {
                    agentError = error.localizedDescription
                    settings.warmWhileClosed = false
                    agentStatus = ModelWarmup.backgroundAgentStatus()
                }
            } else {
                ModelWarmup.disableBackgroundAgent()
                settings.warmWhileClosed = false
                agentStatus = ModelWarmup.backgroundAgentStatus()
            }
            agentBusy = false
        }
    }
    #endif

    private var scheduleSection: some View {
        Section {
            Picker("Schedule", selection: $option) {
                ForEach(ScheduleOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Background schedule")
        } footer: {
            #if os(iOS)
            Text("Daily waits for iOS to pick an overnight charging window. "
                + "Custom schedules apply immediately and reset to Daily on relaunch. "
                + "Background the app to let a scheduled task fire — iOS never runs it while the app is foregrounded.")
            #else
            Text("Daily runs once roughly every 20 hours. Custom schedules apply immediately and "
                + "reset to Daily on relaunch. While the app is open macOS schedules in-process; "
                + "the login item above is what covers the app-closed case, and it keeps this "
                + "cadence across launches.")
            #endif
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                warming = true
                Task {
                    _ = try? await ModelWarmup.warmNow()
                    warming = false
                    refresh()
                }
            } label: {
                if warming {
                    ProgressView()
                } else {
                    Label("Warm now (foreground)", systemImage: "flame.fill")
                }
            }
            .disabled(warming)

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear history & ledger", systemImage: "trash")
            }
            .confirmationDialog("Clear warmup history & ledger?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    ModelWarmup.clearHistory()
                    refresh()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var historySection: some View {
        Section("History (\(runs.count))") {
            if runs.isEmpty {
                Text(emptyHistoryHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(runs) { run in
                WarmupRunRow(run: run)
            }
        }
    }

    private var emptyHistoryHint: String {
        // "Background the app" has no macOS meaning: the in-process scheduler runs while
        // the app is open, and the agent only fires while the app is closed.
        #if os(iOS)
        var hint = "No warmup runs recorded yet. Load a model once, then background the app on a charger."
        #else
        var hint = "No warmup runs recorded yet. Load a model once, then leave the app running."
        #endif
        hint += " Or pick a debug schedule above."
        #if os(macOS)
        hint += " Agent runs (app closed) appear here after the next launch."
        #endif
        return hint
    }

    private func refresh() {
        runs = ModelWarmup.history()
        Task { @MainActor in
            nextScheduled = await ModelWarmup.nextScheduledWarmup()
        }
        #if os(macOS)
        // Re-read rather than trust the last value: the user can turn the login item off in
        // System Settings at any time, and the app is not notified.
        agentStatus = ModelWarmup.backgroundAgentStatus()
        #endif
    }
}

/// Compact label for the SDK's active warmup schedule, used as the Settings root row detail.
private func warmupScheduleLabel(_ schedule: WarmupSchedule) -> String {
    switch schedule {
    case .daily:
        return "Daily"
    case .immediateOnce:
        return "Once"
    case .repeating(let interval, let requiresCharging):
        let minutes = max(1, Int(interval / 60))
        return "Repeat \(minutes)min\(requiresCharging ? ", charging" : "")"
    @unknown default:
        return "Custom"
    }
}

/// One row per `WarmupRunRecord` in the warmup page's history section.
private struct WarmupRunRow: View {
    let run: WarmupRunRecord

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    // One icon per trigger: agent runs (app closed) must be distinguishable from
    // manual warmNow() taps, or an unexpected agent cadence reads as user activity.
    private var triggerIcon: (name: String, color: Color) {
        switch run.trigger {
        case .background: return ("moon.zzz.fill", .indigo)
        case .agent: return ("moon.stars.fill", .purple)
        case .osUpdate: return ("arrow.triangle.2.circlepath", .teal)
        case .manual: return ("hand.tap.fill", .blue)
        @unknown default: return ("questionmark.circle.fill", .secondary)
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                detailRow("Fired", Self.dateFormatter.string(from: run.firedAt))
                detailRow("Started", Self.dateFormatter.string(from: run.startedAt))
                detailRow("Finished", Self.dateFormatter.string(from: run.finishedAt))
                if let days = run.daysSinceLastSuccess {
                    detailRow("Since last success", String(format: "%.1f days", days))
                }
                // A version change is the usual explanation for a cold cache, so surface it
                // next to `didSpecialize` rather than making the reader correlate the two.
                if let os = run.previousOSVersion {
                    detailRow("Previous OS", os)
                }
                if let sdk = run.previousSDKVersion {
                    detailRow("Previous SDK", sdk)
                }
                if run.models.isEmpty {
                    Divider()
                    Text("Nothing to warm — no model used recently enough to be selected.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Divider()
                    ForEach(Array(run.models.enumerated()), id: \.offset) { _, model in
                        modelDetail(model)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: run.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(run.success ? .green : .orange)
                        .font(.caption)
                    Text(Self.dateFormatter.string(from: run.startedAt))
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: triggerIcon.name)
                        .font(.caption2)
                        .foregroundStyle(triggerIcon.color)
                    if run.taskExpired {
                        Text("expired")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(String(format: "%.1fs", run.finishedAt.timeIntervalSince(run.startedAt)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(run.models.isEmpty
                     ? "(nothing to warm)"
                     : run.models.map(\.modelName).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text("\(label):")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func modelDetail(_ model: WarmupRunRecord.ModelOutcome) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: Self.iconName(for: model.outcome))
                    .foregroundStyle(Self.iconColor(for: model.outcome))
                    .font(.caption2)
                Text(model.modelName)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.1fs", model.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(model.category.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // `didSpecialize` is the signal that matters: false means the OS cache was
                // already warm (the feature working), true means this run paid the recompile.
                if model.didSpecialize {
                    Text("specialized")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if case .skipped(let reason) = model.outcome {
                    Text("skipped: \(reason.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "slowest %.1fs", model.slowestComponentDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func iconName(for outcome: WarmupRunRecord.ModelOutcome.Outcome) -> String {
        switch outcome {
        case .warmed:  return "checkmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .failed:  return "xmark.circle.fill"
        @unknown default: return "questionmark.circle.fill"
        }
    }

    static func iconColor(for outcome: WarmupRunRecord.ModelOutcome.Outcome) -> Color {
        switch outcome {
        case .warmed:  return .green
        case .skipped: return .yellow
        case .failed:  return .red
        @unknown default: return .secondary
        }
    }
}

// MARK: - Advanced page

/// Advanced area: license status, warmup diagnostics, and the developer tools.
struct AdvancedSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsDestination.license) {
                    SettingsRowLabel(icon: "checkmark.seal", tint: .green, title: "License")
                }
                NavigationLink(value: SettingsDestination.warmup) {
                    SettingsRowLabel(
                        icon: "flame", tint: .orange, title: "Model Warmup",
                        detail: warmupScheduleLabel(ModelWarmup.currentSchedule())
                    )
                }
            }

            Section {
                NavigationLink(value: SettingsDestination.backgroundDownloadTest) {
                    SettingsRowLabel(icon: "arrow.down.circle", tint: .gray, title: "Background Download Test")
                }
                NavigationLink(value: SettingsDestination.remoteURLDownload) {
                    SettingsRowLabel(icon: "link", tint: .gray, title: "Remote URL Download")
                }
                Toggle("Capture Replay Traces", isOn: $settings.captureReplayTraces)
            } header: {
                Text("Developer Tools")
            } footer: {
                Text("Records a JSON replay trace for every session, shareable from a session's detail page.")
            }
        }
        .navigationTitle("Advanced")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Developer tools

/// Settings page that drives the BackgroundDownloader test harness:
/// start a download, close the app, watch the OS continue it. Also surfaces the
/// per-download network-type restriction (Wi-Fi-only) and a persisted log of
/// background events so the user can inspect what happened across app relaunches.
struct BackgroundDownloadTestPage: View {
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var settings: AppSettings

    /// Persisted "Wi-Fi only" toggle. Translates to `disabledNetworkTypes: [.cellular]`.
    @AppStorage("bgDownloadWifiOnly") private var wifiOnly: Bool = false
    /// "Online" verify toggle -- when on, the Verify button does HEAD requests against
    /// upstream and populates `updateStatus` (etag-based update detection). Persists across
    /// launches so the user's preference sticks.
    @AppStorage("bgVerifyOnline") private var verifyOnline: Bool = false
    @State private var isLogExpanded: Bool = false

    private var disabledNetworkTypes: [NWInterface.InterfaceType]? {
        wifiOnly ? [.cellular] : nil
    }

    var body: some View {
        Form {
            Section {
                activeInterfaceRow

                Toggle(isOn: $wifiOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi only")
                        Text("Disables cellular for new and active downloads.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } footer: {
                Text("Test background download capability by closing the app after starting the test.")
            }

            Section {
                if sdkCoordinator.backgroundDownloadTestActive {
                    activeView
                } else {
                    idleView
                }
                verifyRow
            }

            Section {
                eventLogView
            }
        }
        .navigationTitle("Background Download Test")
        .onAppear {
            sdkCoordinator.checkForPausedDownloads()
            // Re-read the live network path so the "Active network" badge isn't stale (the
            // SDK monitor only pushes updates on path changes, not on subscribe).
            sdkCoordinator.refreshNetworkSnapshot()
        }
        .onChange(of: wifiOnly) { _, newValue in
            // Apply restriction change to whatever the current download is -- handles
            // the "tighten/lift mid-flight" path. No-op when there's no active download.
            sdkCoordinator.setBackgroundDownloadRestriction(newValue ? [.cellular] : nil)
        }
    }

    @ViewBuilder
    private var activeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: sdkCoordinator.backgroundDownloadProgress)
            HStack {
                Text(sdkCoordinator.backgroundDownloadTestStatus)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(sdkCoordinator.backgroundDownloadProgress * 100))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            HStack {
                // Without an explicit ButtonStyle, SwiftUI's List row promotes a tap on the
                // row to every contained Button -- pressing Pause would also fire Cancel &
                // Delete (deleteProgress: true) and wipe progress. `.bordered` (matching
                // the section's other action rows) makes each button an isolated hit target.
                Button("Pause") {
                    sdkCoordinator.cancelBackgroundDownloadTest(deleteProgress: false)
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Button("Cancel & Delete") {
                    sdkCoordinator.cancelBackgroundDownloadTest(deleteProgress: true)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }

    @ViewBuilder
    private var idleView: some View {
        if !sdkCoordinator.backgroundDownloadTestStatus.isEmpty {
            Text(sdkCoordinator.backgroundDownloadTestStatus)
                .font(.caption)
                .foregroundColor(statusColor)
        }

        if sdkCoordinator.hasPausedDownload, let pausedModel = sdkCoordinator.pausedDownloadModel {
            VStack(spacing: 8) {
                Text("Paused download: \(pausedModel)")
                    .font(.caption)
                    .foregroundColor(.orange)

                HStack(spacing: 8) {
                    Button { Task { await sdkCoordinator.resumeBackgroundDownload() } } label: {
                        Label("Resume", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        Task {
                            await sdkCoordinator.startFreshBackgroundDownload(
                                modelName: settings.selectedModel,
                                disabledNetworkTypes: disabledNetworkTypes
                            )
                        }
                    } label: {
                        Label("Start Fresh", systemImage: "arrow.counterclockwise.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.selectedModel.isEmpty)

                    Button { sdkCoordinator.resetAllDownloadState() } label: {
                        Label("Clear All", systemImage: "trash.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        } else {
            HStack(spacing: 8) {
                Button {
                    Task {
                        await sdkCoordinator.scheduleBackgroundDownloadTest(
                            modelName: settings.selectedModel,
                            disabledNetworkTypes: disabledNetworkTypes
                        )
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(settings.selectedModel.isEmpty)

                Button { sdkCoordinator.resetAllDownloadState() } label: {
                    Label("Clear All", systemImage: "trash.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }

    /// Read-only "Verify Download" affordance. Tries the active download first (in-flight /
    /// paused); falls back to the persisted ``DownloadCacheEntry`` for the selected model
    /// (works after the active record is cleaned up). The "online" toggle below opts in to
    /// HEAD-based verification + ETag comparison for upstream-update detection.
    @ViewBuilder
    private var verifyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task {
                        await sdkCoordinator.verifyCurrentBackgroundDownload(
                            modelVariant: settings.selectedModel,
                            offlineMode: !verifyOnline
                        )
                    }
                } label: {
                    Label("Verify Download", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(sdkCoordinator.hasCurrentBackgroundDownloadId == false && settings.selectedModel.isEmpty)

                Toggle("Online", isOn: $verifyOnline)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                Text("Online")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(verifyOnline
                 ? "Read-only file-size + ETag check against upstream HEAD. Detects 'update available'."
                 : "Read-only file-size check vs cached/active reference. No network. Fails on paused/in-flight downloads."
            )
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var eventLogView: some View {
        DisclosureGroup(isExpanded: $isLogExpanded) {
            if sdkCoordinator.backgroundEvents.isEmpty {
                Text("No background events yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sdkCoordinator.backgroundEvents.prefix(50)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                            Text(event.message)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }

                    Button(role: .destructive) {
                        sdkCoordinator.clearBackgroundEvents()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
        } label: {
            HStack {
                Label("Background Event Log", systemImage: "clock.arrow.circlepath")
                Spacer()
                Text("\(sdkCoordinator.backgroundEvents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    /// One-line snapshot of the active network path, surfaced from the SDK's
    /// `NetworkMonitor`. Color-coded so a glance tells you whether a Wi-Fi-only
    /// restriction is currently satisfied or about to gate the download.
    @ViewBuilder
    private var activeInterfaceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: pathIconName)
                .foregroundColor(pathIconColor)
                .imageScale(.medium)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Active network")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(activeInterfaceLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(pathIconColor)
            }
            Spacer()
            if wifiOnly {
                Text(restrictionSatisfied ? "Allowed" : "Blocked")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (restrictionSatisfied ? Color.green : Color.red).opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundColor(restrictionSatisfied ? .green : .red)
            }
        }
        .padding(.vertical, 2)
    }

    private var activeInterfaceLabel: String {
        guard sdkCoordinator.isNetworkSatisfied else { return "Not connected" }
        let names = sdkCoordinator.activeNetworkInterfaces.compactMap { interfaceName($0) }
        return names.isEmpty ? "Connected" : names.joined(separator: " + ")
    }

    private func interfaceName(_ type: NWInterface.InterfaceType) -> String? {
        switch type {
            case .wifi: return "Wi-Fi"
            case .cellular: return "Cellular"
            case .wiredEthernet: return "Ethernet"
            case .loopback: return "Loopback"
            case .other: return nil // not user-meaningful; hide
            @unknown default: return nil
        }
    }

    private var pathIconName: String {
        guard sdkCoordinator.isNetworkSatisfied else { return "wifi.slash" }
        if sdkCoordinator.activeNetworkInterfaces.contains(.wifi) { return "wifi" }
        if sdkCoordinator.activeNetworkInterfaces.contains(.cellular) { return "antenna.radiowaves.left.and.right" }
        if sdkCoordinator.activeNetworkInterfaces.contains(.wiredEthernet) { return "cable.connector" }
        return "network"
    }

    private var pathIconColor: Color {
        guard sdkCoordinator.isNetworkSatisfied else { return .red }
        return restrictionSatisfied ? .primary : .orange
    }

    /// Whether the active path satisfies the current Wi-Fi-only restriction. When the
    /// toggle is off, every path satisfies (no restriction). When on, only Wi-Fi /
    /// Ethernet count -- cellular-only is "Blocked" and queues the download in
    /// `.pausedByNetwork` until Wi-Fi returns.
    private var restrictionSatisfied: Bool {
        guard wifiOnly else { return true }
        guard sdkCoordinator.isNetworkSatisfied else { return false }
        return sdkCoordinator.activeNetworkInterfaces.contains(.wifi)
            || sdkCoordinator.activeNetworkInterfaces.contains(.wiredEthernet)
    }

    private var statusColor: Color {
        if sdkCoordinator.backgroundDownloadTestStatus.contains("✅") { return .green }
        if sdkCoordinator.backgroundDownloadTestStatus.contains("❌") { return .red }
        return .secondary
    }
}

/// Verification harness for `ModelStore.downloadAndExtractInBackgroundAndWait(remoteURL:)`
/// against a real presigned URL. Pastes-in URL -> tap Download & Extract -> load via the normal
/// UI. No explicit `downloadKey`/`namespace` -- the SDK derives them from the URL path
/// (`<...>/<org>/<repo>/<variant>.aar` -> `(<variant>, <org>/<repo>)`), so a downloaded archive
/// lands in the same store location the normal model-loading UI resolves.
struct RemoteURLDownloadPage: View {
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @State private var urlString: String = ""
    @State private var status: Status = .idle("Idle")
    @State private var extractedPath: String = ""
    @State private var isWorking: Bool = false

    /// Typed alternative to parsing emoji from a display string: `statusColor` reads the
    /// `case`, not the rendered text, so changing the label never silently changes the color.
    enum Status: Equatable {
        case idle(String)
        case working(String)
        case success(String)
        case failure(String)

        var label: String {
            switch self {
            case .idle(let s), .working(let s): return s
            case .success(let s): return "✓ \(s)"
            case .failure(let s): return "✗ \(s)"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                content
            }
        }
        .navigationTitle("Remote URL Download")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Presigned / signed URL pointing at .aar", text: $urlString, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            HStack {
                Button(isWorking ? "Downloading..." : "Download & Extract") {
                    Task { await runDownloadAndExtract() }
                }
                .disabled(isWorking || urlString.isEmpty)

                Spacer()

                if isWorking {
                    ProgressView()
                }
            }

            Text(status.label)
                .font(.callout)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.leading)

            if !extractedPath.isEmpty {
                Text("Extracted: \(extractedPath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch status {
        case .success: return .green
        case .failure: return .red
        default: return .secondary
        }
    }

    private func runDownloadAndExtract() async {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = .failure("Invalid URL")
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            status = .working("Downloading...")
            let folder = try await sdkCoordinator.modelStore.downloadAndExtractInBackgroundAndWait(
                remoteURL: url,
                destinationRoot: sdkCoordinator.modelStore.baseModelFolder()
            )
            extractedPath = folder.path
            status = .success("Extracted to \(folder.lastPathComponent). Refresh model list to load.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}
