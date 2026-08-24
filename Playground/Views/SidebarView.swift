import SwiftUI
import CoreML
import Argmax

struct SidebarView: View {
    @Binding var selectedFeature: PlaygroundFeature?

    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var streamViewModel: StreamViewModel
    @EnvironmentObject private var sessionHistory: SessionHistoryManager
    @EnvironmentObject private var settings: AppSettings

    @State private var showCustomVocabularySheet = false
    @State private var customVocabularyInput = ""
    @State private var isEditingCustomVocabulary = false
    @State private var showCustomVocabularyErrorAlert = false
    @State private var customVocabularyErrorMessage = ""
    @State private var customVocabularyDetent: PresentationDetent = .medium
    @State private var pendingPipelineDelete: DownloadRole?
    @State private var showLanguageInfo = false
    #if !os(macOS)
    // macOS reaches Settings through the window toolbar (embedded in the detail column).
    @State private var showSettings = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if !os(macOS)
            HStack(alignment: .top) {
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
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings")
            }
            .padding(.bottom, 8)
            #endif

            modelSelectorSection
                .padding(.bottom, 12)

            Divider()
                .padding(.bottom, 8)

            navigationList

            Spacer()

            AppInfoFooter()
        }
        // `alignment: .top` keeps content anchored to the top edge as it grows. The default
        // `.center` for `.frame(maxHeight: .infinity)` makes the VStack vertically center inside
        // its frame -- adding rows then pushes the top edge upward (behind the macOS title bar).
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal)
        .alert("Custom Vocabulary", isPresented: $showCustomVocabularyErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(customVocabularyErrorMessage)
        }
        .alert(
            "Wi-Fi Not Available",
            isPresented: Binding(
                get: { sdkCoordinator.pendingCellularDecision != nil },
                set: { if !$0 { sdkCoordinator.pendingCellularDecision = nil } }
            )
        ) {
            Button("Wait for Wi-Fi") {
                sdkCoordinator.resolveCellularDecision(useCellular: false, settings: settings)
            }
            Button("Download on Cellular") {
                sdkCoordinator.resolveCellularDecision(useCellular: true, settings: settings)
            }
            Button("Cancel", role: .cancel) {
                sdkCoordinator.pendingCellularDecision = nil
            }
        } message: {
            Text("Downloading models on cellular may use significant data. You can wait for Wi-Fi -- the download will start automatically when it's available.")
        }
        .alert(
            "Delete Model",
            isPresented: Binding(
                get: { pendingPipelineDelete != nil },
                set: { if !$0 { pendingPipelineDelete = nil } }
            ),
            presenting: pendingPipelineDelete
        ) { role in
            Button("Delete", role: .destructive) {
                Task { await sdkCoordinator.deletePipeline(role) }
                pendingPipelineDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingPipelineDelete = nil }
        } message: { role in
            Text("Remove the \(sdkCoordinator.pipelineRows.first(where: { $0.role == role })?.pipelineName.lowercased() ?? "selected") model from this device?")
        }
        .sheet(isPresented: $showCustomVocabularySheet) {
            CustomVocabularySheet(
                isPresented: $showCustomVocabularySheet,
                words: $settings.customVocabularyWords,
                input: $customVocabularyInput,
                isEditing: $isEditingCustomVocabulary,
                canUpdateVocabulary: {
                    if sdkCoordinator.qwen != nil { return true }
                    return settings.selectedCustomVocabularyModel != nil && sdkCoordinator.whisperKit != nil
                },
                onError: { msg in
                    customVocabularyErrorMessage = msg
                    showCustomVocabularyErrorAlert = true
                }
            )
            #if os(iOS)
            .presentationDetents([.medium, .large], selection: $customVocabularyDetent)
            .presentationDragIndicator(.visible)
            #endif
        }
        .task {
            // Row building verifies each model on disk synchronously; yield once so the
            // first frame commits before that work occupies the main actor.
            await Task.yield()
            syncPipelines()
        }
        .onChange(of: settings.selectedModel) { _, _ in syncPipelines() }
        .onChange(of: settings.selectedDiarizationModelRaw) { _, _ in syncPipelines() }
        .onChange(of: settings.selectedCustomVocabularyModelRaw) { _, _ in syncPipelines() }
        #if !os(macOS)
        .sheet(isPresented: $showSettings) {
            SettingsView(isPresented: $showSettings, isStreamMode: selectedFeature == .stream)
        }
        #endif
    }

    /// `true` when the selected transcription model's family can pair with a custom-vocabulary
    /// model (Parakeet only). Whisper and Qwen reject the pairing, so the selector is disabled and
    /// the companion model is omitted from the pipeline for them.
    private var customVocabSupported: Bool {
        TranscriptionModelFamily(modelName: settings.selectedModel).supportsCustomVocabulary
    }

    private func syncPipelines() {
        sdkCoordinator.syncPipelineRows(
            transcriptionModel: settings.selectedModel,
            diarizationModel: settings.selectedDiarizationModel,
            customVocabularyModel: customVocabSupported ? settings.selectedCustomVocabularyModel : nil
        )
    }

    private func openCustomVocabularyEditor() {
        customVocabularyInput = settings.customVocabularyWords.joined(separator: "\n")
        isEditingCustomVocabulary = settings.customVocabularyWords.isEmpty
        customVocabularyDetent = settings.customVocabularyWords.isEmpty ? .large : .medium
        showCustomVocabularySheet = true
    }

    private func openFolder(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: - Model Selector

    private var modelSelectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            proHeader
            ModelsPanel(
                rows: sdkCoordinator.pipelineRows,
                coordinator: sdkCoordinator,
                onOpenFolder: { openFolder($0) },
                onDelete: { pendingPipelineDelete = $0 },
                onRetry: { sdkCoordinator.retryPipeline($0, settings: settings) },
                onRepair: { sdkCoordinator.repairContentMismatch($0, settings: settings) },
                selectorFor: { role in selector(for: role) },
                belowStatusFor: { role in role == .transcription ? AnyView(languageSelector) : AnyView(EmptyView()) }
            )
            loadStateSection
                .padding(.top, 4)
        }
    }

    private var proHeader: some View {
        HStack {
            Spacer()
            HStack(spacing: 4) {
                Link(destination: URL(string: "https://argmaxinc.com/#SDK")!) {
                    Image(systemName: "info.circle")
                        .font(.footnote)
                        .foregroundColor(.blue)
                }
                Text("Pro")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func selector(for role: DownloadRole) -> AnyView {
        switch role {
        case .transcription: return AnyView(transcriptionSelector)
        case .diarization: return AnyView(diarizationSelector)
        case .customVocabulary: return AnyView(customVocabSelector)
        }
    }

    @ViewBuilder
    private var transcriptionSelector: some View {
        if !sdkCoordinator.availableModelNames.isEmpty {
            let allNames = sdkCoordinator.availableModelNames.filter(sdkCoordinator.isRecognizedTranscriptionModel)
            let families: [(title: String, names: [String])] = [
                ("Qwen",     allNames.filter { TranscriptionModelFamily(modelName: $0) == .qwen }),
                ("Parakeet", allNames.filter { TranscriptionModelFamily(modelName: $0) == .parakeet }),
                ("Whisper",  allNames.filter { TranscriptionModelFamily(modelName: $0) == .whisper }),
            ]
            Picker("Transcription model", selection: $settings.selectedModel) {
                ForEach(families.filter { !$0.names.isEmpty }, id: \.title) { family in
                    Section(family.title) {
                        ForEach(family.names, id: \.self) { model in
                            let icon = sdkCoordinator.isTranscriptionModelDownloaded(model) ? "checkmark.circle" : "arrow.down.circle.dotted"
                            Text("\(Image(systemName: icon)) \(sdkCoordinator.pickerTranscriptionModelName(model))").tag(model)
                        }
                    }
                }
            }
            // Reset a stale persisted selection (e.g. a variant no longer in the filtered
            // list) so the picker never shows a blank entry. `.task(id:)` runs it on appear
            // and whenever the list changes, off the body pass -- writing a @Published from
            // inside body is a SwiftUI violation.
            .task(id: allNames) {
                if !allNames.contains(settings.selectedModel), let first = allNames.first {
                    settings.selectedModel = first
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(sdkCoordinator.isModelConfigurationLocked)
            .onChange(of: settings.selectedModel, initial: false) { _, _ in
                sdkCoordinator.modelDownloadFailed = false
                Task { await sdkCoordinator.reset() }
            }
        } else {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.5)
        }
    }

    /// Language controls shown beneath the transcription model's status line, indented under it.
    /// An info button linking to the model docs is always available; the picker appears once a
    /// model is loaded, with options read from the loaded model
    /// (`ArgmaxSDKCoordinator.loadedModelLanguageInfo`) rather than the model name.
    @ViewBuilder
    private var languageSelector: some View {
        if let info = sdkCoordinator.loadedModelLanguageInfo {
            let names = settings.supportedLanguageNames(for: info)
            let offersDetect = settings.offersDetectLanguage(family: info.family, supportedNames: names)
            // Non-hinting families (Parakeet) auto-detect only: "Detect language" is pinned and
            // selected, and the supported languages are listed below as browse-only.
            let languagesSelectable = info.family.supportsLanguageHinting
            HStack(spacing: 6) {
                languageBranchIcon
                LanguageMenuButton(
                    selection: $settings.selectedLanguage,
                    pinnedOption: offersDetect ? AppSettings.detectLanguageOption : nil,
                    languages: names,
                    languagesSelectable: languagesSelectable,
                    isDisabled: false
                )
                languageInfoButton(note: languageNoteString(family: info.family, offersDetect: offersDetect))
            }
            .padding(.leading, 8)
            // Re-normalize whenever the resolved language set changes (codes for Whisper/Parakeet,
            // explicit names for Qwen), so the selection stays valid across model switches.
            .task(id: names) {
                settings.normalizeSelectedLanguage(family: info.family, supportedNames: names)
            }
        } else {
            // No model loaded yet: surface the info affordance so users can learn about language
            // support before the model's supported languages are known.
            HStack(spacing: 6) {
                languageBranchIcon
                Text("Language")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                languageInfoButton(note: nil)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
        }
    }

    /// The "└" connector that visually nests the language row under the model picker.
    private var languageBranchIcon: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    /// Info button whose popover carries the model-family language guidance (`note`) plus a link to
    /// the model docs. `note` is `nil` before a model loads.
    private func languageInfoButton(note: String?) -> some View {
        Button { showLanguageInfo = true } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showLanguageInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(note ?? "Language support depends on the transcription model. Some models support language hinting while others automatically detect the language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("View Language Support", destination: URL(string: "https://app.argmaxinc.com/docs/models")!)
                    .font(.caption)
            }
            .padding()
            .frame(width: 260)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            #endif
        }
    }

    /// Model-family language guidance surfaced in the info popover: families that can't be hinted
    /// (Parakeet) treat the list as auto-detected languages; families that can (Whisper) hint.
    private func languageNoteString(family: TranscriptionModelFamily, offersDetect: Bool) -> String? {
        if !family.supportsLanguageHinting {
            return "Auto-detects language. Supported languages are listed in the menu."
        } else if offersDetect {
            return "Pick a language or choose Detect Language."
        }
        return nil
    }

    @ViewBuilder
    private var diarizationSelector: some View {
        Picker("Diarization model", selection: Binding(
            get: { settings.selectedDiarizationModel },
            set: { settings.selectedDiarizationModelRaw = $0?.rawValue ?? "none" }
        )) {
            Text("None").tag(Optional<DiarizationModelSelection>.none)
            ForEach(DiarizationModelSelection.allCases, id: \.self) { model in
                let downloaded = sdkCoordinator.isDiarizationModelDownloaded(model)
                let icon = downloaded ? "checkmark.circle" : "arrow.down.circle.dotted"
                Text("\(Image(systemName: icon)) \(model.displayName)").tag(Optional(model))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(sdkCoordinator.isModelConfigurationLocked)
        .onChange(of: settings.selectedDiarizationModelRaw, initial: false) { _, _ in
            Task { @MainActor in
                await sdkCoordinator.unloadSpeakerKit()
                streamViewModel.enableStreamingDiarization = false
            }
        }
    }

    @ViewBuilder
    private var customVocabSelector: some View {
        HStack(spacing: 8) {
            let isQwen = TranscriptionModelFamily(modelName: settings.selectedModel) == .qwen
            if isQwen {
                // Qwen powers its own vocabulary; nothing to select here.
                Picker("Custom vocabulary model", selection: .constant(0)) {
                    Text(sdkCoordinator.pickerTranscriptionModelName(settings.selectedModel)).tag(0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(true)
            } else {
                Picker("Custom vocabulary model", selection: Binding(
                    // Whisper can't pair with a CV model; display "None" rather than a greyed
                    // stale selection. The persisted choice is retained for Parakeet reselection.
                    get: { customVocabSupported ? settings.selectedCustomVocabularyModel : nil },
                    set: { settings.selectedCustomVocabularyModelRaw = $0?.rawValue ?? "none" }
                )) {
                    Text("None").tag(Optional<CustomVocabularyModelSelection>.none)
                    ForEach(CustomVocabularyModelSelection.allCases, id: \.self) { model in
                        let downloaded = sdkCoordinator.isCustomVocabularyModelDownloaded(model)
                        let icon = downloaded ? "checkmark.circle" : "arrow.down.circle.dotted"
                        Text("\(Image(systemName: icon)) \(model.displayName)").tag(Optional(model))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(sdkCoordinator.isModelConfigurationLocked || !customVocabSupported)
            }

            let showEditButton: Bool = {
                if sdkCoordinator.qwen != nil { return true }
                return customVocabSupported && settings.selectedCustomVocabularyModel != nil
            }()
            if showEditButton {
                Button { openCustomVocabularyEditor() } label: {
                    Text("Edit")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var loadStateSection: some View {
        if sdkCoordinator.allPipelinesLoaded {
            Button {
                Task { await sdkCoordinator.reset() }
            } label: {
                Label("Unload Models", systemImage: "eject")
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .glassSecondaryButtonStyle()
        } else if sdkCoordinator.hasActionableRow {
            // Stay visible whenever a row needs user input (paused, incomplete, failed, not
            // downloaded, downloaded-but-not-loaded). `prepare` handles per-role smartly -- resumes
            // paused, fills incomplete, loads already-downloaded, skips in-flight.
            Button {
                // Model load is decoupled from warmup scheduling: this only loads. Warmup
                // scheduling lives in Settings > Model Warmup.
                sdkCoordinator.requestLoadModels(modelName: settings.selectedModel, redownload: false, settings: settings)
            } label: {
                Text("Load Models")
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .glassProminentButtonStyle()
        }
        // Otherwise (everything in-flight: downloading/specializing/loading/waitingForWifi) the
        // panel above already shows per-pipeline progress; no global button.
    }

    // MARK: - Navigation

    private var navigationList: some View {
        List(PlaygroundFeature.allCases, selection: $selectedFeature) { feature in
            HStack(spacing: 10) {
                Image(systemName: feature.icon)
                    .frame(width: 20)
                Text(feature.rawValue)
                    .font(.system(.title3))
                    .bold()
                Spacer()
                if feature == .history && !sessionHistory.sessions.isEmpty {
                    Text("\(sessionHistory.sessions.count)")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.secondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tag(feature)
        }
    }
}

// MARK: - App Info Footer

struct AppInfoFooter: View {
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                Text("App Version: \(version) (\(build))")
                Text("Device Model: \(WhisperKit.deviceName())")
                #if os(iOS)
                Text("OS Version: \(UIDevice.current.systemVersion)")
                #elseif os(macOS)
                Text("OS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
                #endif
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary)

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("SDK Version: \(ArgmaxSDK.sdkVersion)")
                    .foregroundColor(.secondary)
                Link("Get access to Argmax SDK", destination: URL(string: "https://argmaxinc.com/#SDK")!)
                    .foregroundColor(.blue)
            }
            .font(.system(.caption2, design: .monospaced))
        }
        .padding(.vertical, 6)
    }
}


// MARK: - Models Panel

/// Per-pipeline panel in the sidebar. One row per `ModelPipelineRow` -- each row owns its model
/// selector (picker / toggle) AND its live status (red/yellow/green dot, variant name + on-disk
/// size, determinate download bar, contextual controls: gear/folder/trash/pause/resume/cancel/
/// retry/repair). Disabled rows (e.g. diarization = None) render the header + selector only.
struct ModelsPanel: View {
    let rows: [ModelPipelineRow]
    let coordinator: ArgmaxSDKCoordinator
    let onOpenFolder: (URL) -> Void
    let onDelete: (DownloadRole) -> Void
    let onRetry: (DownloadRole) -> Void
    let onRepair: (DownloadRole) -> Void
    let selectorFor: (DownloadRole) -> AnyView
    /// Content rendered below the row's status line (e.g. the language picker for the transcription
    /// row). Kept separate from the selector so it appears beneath the "variant · Downloaded · size".
    let belowStatusFor: (DownloadRole) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                ModelPipelineRowView(
                    row: row,
                    coordinator: coordinator,
                    selector: selectorFor(row.role),
                    belowStatus: belowStatusFor(row.role),
                    onOpenFolder: onOpenFolder,
                    onDelete: onDelete,
                    onRetry: onRetry,
                    onRepair: onRepair
                )
                .id(row.id)
            }
            // No panel-level specializing banner -- its conditional appearance shifted the whole
            // sidebar. The per-row status text already says "Specializing...".
        }
    }
}

private struct ModelPipelineRowView: View {
    let row: ModelPipelineRow
    let coordinator: ArgmaxSDKCoordinator
    let selector: AnyView
    let belowStatus: AnyView
    let onOpenFolder: (URL) -> Void
    let onDelete: (DownloadRole) -> Void
    let onRetry: (DownloadRole) -> Void
    let onRepair: (DownloadRole) -> Void

    @State private var dotScale: CGFloat = 1.0

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
    private func formatted(_ bytes: Int64) -> String { Self.byteFormatter.string(fromByteCount: bytes) }
    private func formattedMB(_ bytes: Int64) -> String { "\(bytes / 1_000_000) MB" }

    private var statusColor: Color {
        switch row.state {
        case .notDownloaded: return .secondary
        case .downloading, .waitingForWifi, .paused: return .blue
        case .downloaded, .specializing, .loading: return .yellow
        case .verifying: return .blue
        case .unverified: return .secondary
        case .incomplete: return .red
        case .loaded: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch row.state {
        case .notDownloaded:
            return "Not downloaded"
        case .downloading:
            // total > 0 is rendered by statusView's width-reserving layout, never via this string.
            return "Downloading..."
        case .waitingForWifi:
            return "Waiting for Wi-Fi"
        case .paused(let fraction):
            return "Paused · \(Int(fraction * 100))%"
        case .downloaded:
            return row.sizeOnDisk.map { "Downloaded · \(formatted($0))" } ?? "Downloaded"
        case .unverified:
            return row.sizeOnDisk.map { "Found on disk · \(formatted($0))" } ?? "Found on disk"
        case .verifying:
            return row.sizeOnDisk.map { "Verifying · \(formatted($0))..." } ?? "Verifying..."
        case .incomplete:
            return row.sizeOnDisk.map { "Incomplete · \(formatted($0))" } ?? "Incomplete download"
        case .specializing:
            return "Specializing..."
        case .loading:
            return "Loading..."
        case .loaded:
            return row.sizeOnDisk.map { "Loaded · \(formatted($0))" } ?? "Loaded"
        case .failed(let message):
            // Content-mismatch failures get a tighter label that surfaces the file count
            // rather than the SDK's raw error string (which lists per-file SHA-256 details
            // intended for logs, not UI). The Repair button next to it does the surgical re-fetch.
            if coordinator.hasContentMismatch(row.role) {
                let count = coordinator.contentMismatchFiles[row.role]?.count ?? 0
                return count == 1 ? "Content corrupt · 1 file" : "Content corrupt · \(count) files"
            }
            return message
        }
    }

    private var statusTextColor: Color {
        switch row.state {
        case .incomplete, .failed: return .red
        default: return .secondary
        }
    }

    private var showsBar: Bool {
        switch row.state {
        case .downloading, .specializing, .loading, .verifying: return true
        default: return false
        }
    }
    private var isIndeterminate: Bool {
        switch row.state {
        case .specializing, .loading, .verifying: return true
        default: return false
        }
    }
    private var barFraction: Double {
        if case .downloading(let fraction, _, _) = row.state { return fraction }
        return 0
    }
    private var isNotDownloaded: Bool { row.state == .notDownloaded }

    private var dotShouldPulse: Bool {
        switch row.state {
        case .specializing, .loading: return true
        default: return false
        }
    }

    /// The dot is hollow when there's nothing on disk (or the row is disabled -- selector reachable
    /// but no live model behind it); filled otherwise.
    private var dotIsHollow: Bool { !row.isEnabled || isNotDownloaded }

    /// Status text view for the row's current state. The downloading case gets special treatment:
    /// a hidden `total` text reserves its width for the entire download so the `done` counter can
    /// grow into it without causing the row to reflow on every byte-progress update.
    @ViewBuilder
    private var statusView: some View {
        if case .downloading(let fraction, let done, let total) = row.state, total > 0 {
            HStack(spacing: 0) {
                ZStack(alignment: .trailing) {
                    Text(formattedMB(total)).hidden()
                    Text(formattedMB(done))
                }
                Text(" / \(formattedMB(total)) · \(Int(fraction * 100))%")
            }
        } else {
            AnimatedStatusText(base: statusText, isIndeterminate: isIndeterminate)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotIsHollow ? Color.clear : statusColor)
                    .overlay(Circle().strokeBorder(row.isEnabled ? statusColor : Color.secondary, lineWidth: dotIsHollow ? 1.5 : 0))
                    .frame(width: 9, height: 9)
                    .scaleEffect(dotScale)
                    .accessibilityHidden(true)
                    .onAppear {
                        guard dotShouldPulse else { return }
                        withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                            dotScale = 1.6
                        }
                    }
                    .onChange(of: dotShouldPulse) { _, shouldPulse in
                        if shouldPulse {
                            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                                dotScale = 1.6
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.25)) { dotScale = 1.0 }
                        }
                    }
                Image(systemName: row.iconName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(row.pipelineName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 4)
                controls
            }

            selector

            if row.isEnabled {
                HStack(spacing: 4) {
                    Text(row.modelName)
                        .lineLimit(1)
                    Text("·")
                    statusView
                        .foregroundColor(statusTextColor)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundColor(.secondary)

                // Fixed-height bar slot so the row doesn't reflow as the bar appears/disappears.
                // `Color.clear` baseline guarantees the ZStack always reports 4pt -- otherwise an
                // empty conditional collapses to zero on some layouts. The progress views use
                // SwiftUI's standard `ProgressView` (no `GeometryReader`, which doesn't propose a
                // size and can perturb the parent's layout).
                //
                // On iOS we skip the indeterminate bar entirely -- `ProgressView()` with `.linear`
                // doesn't animate, and the automatic (circular) style is too tall for this 4pt
                // slot. The cycling-dots animation in the status text above signals progress
                // instead. The slot stays in the tree (`Color.clear`) so the row geometry stays
                // identical whether or not a bar is drawn.
                ZStack {
                    Color.clear
                    if showsBar {
                        if isIndeterminate {
                            #if !os(iOS)
                            ProgressView()
                                .progressViewStyle(.linear)
                            #endif
                        } else {
                            ProgressView(value: barFraction)
                                .progressViewStyle(.linear)
                                .transaction { $0.animation = nil }
                        }
                    }
                }
                .frame(height: 4)
            }

            // Rendered below the status line (e.g. the language picker for the transcription row).
            belowStatus
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.caption) }
            .buttonStyle(.borderless)
    }

    private var retryButton: some View {
        Button("Retry") { onRetry(row.role) }
            .font(.caption2)
            .buttonStyle(.borderless)
    }

    /// Targeted re-fetch of only the files flagged as content-corrupt by the SHA-256 gate
    /// (distinct from `retryButton`, which wipes the whole model). Visible only when the
    /// coordinator has recorded a mismatch for this role.
    private var repairButton: some View {
        Button("Repair") { onRepair(row.role) }
            .font(.caption2)
            .buttonStyle(.borderless)
            .tint(.orange)
    }

    @ViewBuilder
    private func folderButton() -> some View {
        #if os(macOS)
        if let url = row.folderURL { iconButton("folder") { onOpenFolder(url) } }
        #endif
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if row.isEnabled {
                DeviceTierButton(
                    role: row.role,
                    modelName: row.modelName,
                    isOnDisk: row.folderURL != nil
                )
                // Recreate (and re-evaluate) when the selected variant or its on-disk state changes.
                .id("\(row.modelName)-\(row.folderURL != nil)")
            }
            if row.isEnabled {
                switch row.state {
                case .downloading:
                    iconButton("pause.circle") { coordinator.pauseModelDownload(row.role) }
                    iconButton("xmark.circle") { coordinator.cancelModelDownload(row.role, deleteProgress: true) }
                case .waitingForWifi:
                    Button("Use cellular") { coordinator.setBackgroundDownloadRestriction(nil, role: row.role) }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    iconButton("xmark.circle") { coordinator.cancelModelDownload(row.role, deleteProgress: true) }
                case .paused:
                    iconButton("play.circle") { coordinator.resumeModelDownload(row.role) }
                    iconButton("xmark.circle") { coordinator.cancelModelDownload(row.role, deleteProgress: true) }
                case .incomplete, .failed:
                    if coordinator.hasContentMismatch(row.role) {
                        repairButton
                    }
                    retryButton
                    folderButton()
                    if row.folderURL != nil { iconButton("trash") { onDelete(row.role) } }
                case .downloaded, .loaded, .unverified:
                    folderButton()
                    iconButton("trash") { onDelete(row.role) }
                case .notDownloaded, .specializing, .loading, .verifying:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Animated status text

/// Replaces the trailing ellipsis on indeterminate-state status strings ("Specializing...",
/// "Loading...", "Verifying...") with a ping-pong dot cycle: . -> .. -> ... -> .. -> .
/// Non-indeterminate states pass through unchanged.
private struct AnimatedStatusText: View {
    let base: String
    let isIndeterminate: Bool

    // 4-phase ping-pong at 0.4 s/phase -> full cycle in 1.6 s.
    private static let phaseSeconds: Double = 0.4
    private static let dotCounts = [1, 2, 3, 2]

    var body: some View {
        if isIndeterminate, let stripped = stripTrailingEllipsis(base) {
            TimelineView(.periodic(from: .now, by: Self.phaseSeconds)) { context in
                let phase = Int(
                    context.date.timeIntervalSinceReferenceDate / Self.phaseSeconds
                ) % Self.dotCounts.count
                Text(stripped + String(repeating: ".", count: Self.dotCounts[phase]))
                    .monospacedDigit()
            }
        } else {
            Text(base)
        }
    }

    /// Returns the prefix without its trailing "..." marker, or `nil` if the string doesn't
    /// end with one (in which case there's nothing to animate).
    private func stripTrailingEllipsis(_ s: String) -> String? {
        guard s.hasSuffix("...") else { return nil }
        return String(s.dropLast(3))
    }
}

// MARK: - Language Menu

/// Source-language dropdown that optionally pins "Detect language" at the top (always visible) and
/// lists the model's languages beneath it in a fresh `ScrollView` (which always starts at the top),
/// avoiding a plain `.menu` `Picker`'s auto-scroll-to-selection in long lists.
///
/// When `languagesSelectable` is `false` (families that only auto-detect, e.g. Parakeet), the
/// listed languages are shown greyed and non-tappable -- they reinforce that detection covers those
/// languages while "Detect language" stays the pinned, selected choice.
struct LanguageMenuButton: View {
    @Binding var selection: String
    /// Pinned, always-selectable option shown above the divider (typically the detect sentinel), or
    /// `nil` when the model has no detect option (e.g. a single-language Whisper `.en`).
    let pinnedOption: String?
    /// The model's supported languages, listed (and scrollable) below the pinned option.
    let languages: [String]
    /// Whether the listed languages can be selected. `false` renders them browse-only.
    var languagesSelectable: Bool = true
    let isDisabled: Bool

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text(selection.capitalized)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            // Match the "Transcription"/"Diarization" pipeline-label font.
            .font(.caption)
            .fontWeight(.medium)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // Plain style so the collapsed control's background blends with the enclosing sidebar
        // rather than showing the tinted fill that `.bordered` adds; the chevron signals it's a menu.
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                if let pinnedOption {
                    optionRow(pinnedOption, selectable: true)
                    Divider()
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(languages, id: \.self) { optionRow($0, selectable: languagesSelectable) }
                    }
                }
                .frame(maxHeight: 520)
            }
            .frame(width: 240)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            #endif
        }
    }

    private func optionRow(_ option: String, selectable: Bool) -> some View {
        Button {
            guard selectable else { return }
            selection = option
            isPresented = false
        } label: {
            HStack {
                Text(option.capitalized)
                    .foregroundStyle(selectable ? .primary : .secondary)
                Spacer()
                if option == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
    }
}
