import SwiftUI
import CoreML
import Argmax

struct SidebarView: View {
    @Binding var selectedFeature: PlaygroundFeature?

    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator
    @EnvironmentObject private var streamViewModel: StreamViewModel
    @EnvironmentObject private var sessionHistory: SessionHistoryManager
    @EnvironmentObject private var settings: AppSettings

    @State private var showDeleteModelAlert = false
    @State private var showDeleteSpeakerModelAlert = false
    @State private var showCustomVocabularySheet = false
    @State private var showTranscriptionConfig = false
    @State private var showDiarizationConfig = false
    @State private var customVocabularyInput = ""
    @State private var isEditingCustomVocabulary = false
    @State private var showCustomVocabularyErrorAlert = false
    @State private var customVocabularyErrorMessage = ""
    @State private var customVocabularyDetent: PresentationDetent = .medium

    private var isDeleteModelDisabled: Bool {
        let local = sdkCoordinator.modelStore.localModels.flatMap { $0.models }
        return local.isEmpty || !local.contains(settings.selectedModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if !os(macOS)
            VStack(alignment: .leading, spacing: 2) {
                Text("Playground")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("by Argmax")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .offset(x: 2, y: -2)
            }
            .padding(.bottom, 8)
            #endif

            // Model selection
            modelSelectorSection
                .padding(.bottom, 12)

            Divider()
                .padding(.bottom, 8)

            // Navigation
            navigationList

            Spacer()

            AppInfoFooter()
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal)
        .alert("Delete Model", isPresented: $showDeleteModelAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteModel() }
        } message: {
            Text("Are you sure you want to delete '\(settings.selectedModel)'?")
        }
        .alert("Delete Diarization Model", isPresented: $showDeleteSpeakerModelAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSpeakerModel() }
        } message: {
            Text("Are you sure you want to delete the \(settings.selectedDiarizationModel?.displayName ?? "diarization") model?")
        }
        .alert("Custom Vocabulary", isPresented: $showCustomVocabularyErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(customVocabularyErrorMessage)
        }
    }

    // MARK: - Model Selector

    private var modelSelectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            HStack {
                if sdkCoordinator.whisperKitModelState == .loaded && sdkCoordinator.isSpeakerKitLoading {
                    SpeakerModelStatusBadge(state: sdkCoordinator.speakerKitModelState)
                    Text(sdkCoordinator.speakerKitModelState.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ModelStatusBadge(state: sdkCoordinator.whisperKitModelState)
                    Text(sdkCoordinator.whisperKitModelState.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Link(destination: URL(string: "http://argmaxinc.com/#SDK")!) {
                        Image(systemName: "info.circle")
                            .font(.footnote)
                            .foregroundColor(.blue)
                    }
                    Text("Pro")
                        .font(.caption)
                }
            }

            // Transcription model
            HStack {
                Text("Transcription:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button { showTranscriptionConfig.toggle() } label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .popover(isPresented: $showTranscriptionConfig) {
                    TranscriptionConfigPopover()
                        .padding()
                        .frame(width: 320)
                }
                #else
                .sheet(isPresented: $showTranscriptionConfig) {
                    TranscriptionConfigPopover()
                        .padding()
                        .presentationDetents([.medium])
                        .presentationBackgroundInteraction(.enabled)
                }
                #endif
            }

            HStack(spacing: 8) {
                if !sdkCoordinator.availableModelNames.isEmpty {
                    let localModelNames = sdkCoordinator.modelStore.localModels.flatMap { $0.models }.map { $0.description }
                    Picker("", selection: $settings.selectedModel) {
                        ForEach(sdkCoordinator.availableModelNames, id: \.self) { model in
                            HStack {
                                let icon = localModelNames.contains(model) ? "checkmark.circle" : "arrow.down.circle.dotted"
                                Text("\(Image(systemName: icon)) \(model.components(separatedBy: "_").dropFirst().joined(separator: " "))").tag(model)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(sdkCoordinator.isModelConfigurationLocked)
                    .onChange(of: settings.selectedModel, initial: false) { _, newValue in
                        sdkCoordinator.modelDownloadFailed = false
                        Task { await sdkCoordinator.reset() }
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.5)
                }

                if sdkCoordinator.whisperKitModelState == .unloaded {
                    Button { showDeleteModelAlert = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .disabled(isDeleteModelDisabled)
                }

                #if os(macOS)
                Button {
                    NSWorkspace.shared.open(sdkCoordinator.modelStore.baseModelFolder())
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                #endif
            }

            if settings.supportsCustomVocabulary {
                HStack {
                    #if os(macOS)
                    Toggle(isOn: $settings.enableCustomVocabulary) {
                        Label("Custom Vocabulary", systemImage: "character.book.closed")
                    }
                    .toggleStyle(.checkbox)
                    .disabled(sdkCoordinator.isModelConfigurationLocked)
                    if settings.enableCustomVocabulary {
                        Spacer()
                        customVocabularyEditButton
                    }
                    #else
                    HStack {
                        Label("Custom Vocabulary", systemImage: "character.book.closed")
                        if settings.enableCustomVocabulary {
                            customVocabularyEditButton
                        }
                        Spacer()
                        Toggle("", isOn: $settings.enableCustomVocabulary)
                            .labelsHidden()
                            .disabled(sdkCoordinator.isModelConfigurationLocked)
                    }
                    #endif
                }
                .sheet(isPresented: $showCustomVocabularySheet) {
                    CustomVocabularySheet(
                        isPresented: $showCustomVocabularySheet,
                        words: $settings.customVocabularyWords,
                        input: $customVocabularyInput,
                        isEditing: $isEditingCustomVocabulary,
                        canUpdateVocabulary: { settings.supportsCustomVocabulary && settings.enableCustomVocabulary && sdkCoordinator.whisperKit != nil },
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
            }

            Divider()
                .padding(.vertical, 2)

            // Diarization model
            HStack {
                Text("Diarization:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if settings.selectedDiarizationModel?.isPyannote == true {
                    Button { showDiarizationConfig.toggle() } label: {
                        Image(systemName: "gearshape")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .popover(isPresented: $showDiarizationConfig) {
                        DiarizationConfigPopover()
                            .padding()
                            .frame(width: 320)
                    }
                    #else
                    .sheet(isPresented: $showDiarizationConfig) {
                        DiarizationConfigPopover()
                            .padding()
                            .presentationDetents([.medium])
                            .presentationBackgroundInteraction(.enabled)
                    }
                    #endif
                }
            }

            HStack(spacing: 8) {
                Picker("", selection: Binding(
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
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(sdkCoordinator.isModelConfigurationLocked)
                .onChange(of: settings.selectedDiarizationModelRaw, initial: false) { _, _ in
                    Task { @MainActor in
                        await sdkCoordinator.unloadSpeakerKit()
                        streamViewModel.enableStreamingDiarization = false
                    }
                }

                if sdkCoordinator.whisperKitModelState == .unloaded {
                    Button { showDeleteSpeakerModelAlert = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .disabled(settings.selectedDiarizationModel.map { sdkCoordinator.isDiarizationModelDownloaded($0) } != true)
                }

                #if os(macOS)
                Button {
                    if let model = settings.selectedDiarizationModel {
                        NSWorkspace.shared.open(sdkCoordinator.modelStore.transcriberFolder(repo: model.modelRepo))
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(settings.selectedDiarizationModel == nil)
                #endif
            }

            loadStateSection
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var loadStateSection: some View {

        if sdkCoordinator.isLoading {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    IndeterminateProgressBar()
                    Button {
                        cancelDownload(delete: sdkCoordinator.whisperKitModelState == .downloading)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                loadingStatusText
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        } else if sdkCoordinator.areModelsReady {
            Button {
                Task { await sdkCoordinator.reset() }
            } label: {
                Label("Unload Models", systemImage: "eject")
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .glassSecondaryButtonStyle()
        } else { // needs loading
            if sdkCoordinator.modelDownloadFailed {
                Text("Model download failed or was interrupted")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            Button {
                let redownload = sdkCoordinator.modelDownloadFailed
                sdkCoordinator.loadModel(settings.selectedModel, redownload: redownload, settings: settings)
            } label: {
                Text("Load Models")
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .glassProminentButtonStyle()
        }
    }

    private var customVocabularyEditButton: some View {
        Button {
            customVocabularyInput = settings.customVocabularyWords.joined(separator: "\n")
            isEditingCustomVocabulary = settings.customVocabularyWords.isEmpty
            customVocabularyDetent = settings.customVocabularyWords.isEmpty ? .large : .medium
            showCustomVocabularySheet = true
        } label: {
            Text("Edit")
                .font(.caption)
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var loadingStatusText: some View {
        if sdkCoordinator.isWhisperKitLoading {
            switch sdkCoordinator.whisperKitModelState {
            case .downloading:
                Text("Downloading transcription model...")
            case .prewarming:
                Text("Specializing transcription model for your device... This can take several minutes on first load.")
            case .loading:
                Text("Loading transcription model...")
            default:
                EmptyView()
            }
        } else if let modelName = settings.selectedDiarizationModel?.displayName {
            switch sdkCoordinator.speakerKitModelState {
            case .downloading:
                Text("Downloading \(modelName) model...")
            case .prewarming, .prewarmed:
                Text("Specializing \(modelName) model... May take longer on first load.")
            case .loading, .downloaded:
                Text("Loading \(modelName) model... May take longer on first load.")
            default:
                EmptyView()
            }
        }
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

    // MARK: - Actions

    private func deleteModel() {
        Task {
            do {
                try await sdkCoordinator.delete(modelName: settings.selectedModel)
                await sdkCoordinator.updateModelList()
                await sdkCoordinator.reset()
                if settings.enableCustomVocabulary {
                    try await sdkCoordinator.deleteCustomVocabularyModels()
                }
            } catch {
                Logging.error("Error deleting model: \(error)")
            }
        }
    }

    private func deleteSpeakerModel() {
        guard let model = settings.selectedDiarizationModel else { return }
        Task { @MainActor in
            await sdkCoordinator.unloadSpeakerKit()
            streamViewModel.enableStreamingDiarization = false
            let folder = sdkCoordinator.modelStore.transcriberFolder(repo: model.modelRepo)
            if FileManager.default.fileExists(atPath: folder.path) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private func cancelDownload(delete: Bool = false) {
        Task {
            sdkCoordinator.modelStore.cancelDownload()
            if delete {
                let repos = sdkCoordinator.modelStore.availableModelRepos()
                for repo in repos {
                    if sdkCoordinator.modelStore.modelExists(variant: settings.selectedModel, from: repo) {
                        try? await sdkCoordinator.modelStore.deleteModel(variant: settings.selectedModel, from: repo)
                        break
                    }
                }
            }
            await sdkCoordinator.reset()
            await sdkCoordinator.updateModelList()
        }
    }
}

// MARK: - Shared Config Helpers

private func computeUnitRow(_ label: String, selection: Binding<MLComputeUnits>) -> some View {
    HStack {
        Text(label)
            .font(.subheadline)
        Spacer()
        Picker("", selection: selection) {
            Text("CPU").tag(MLComputeUnits.cpuOnly)
            Text("GPU").tag(MLComputeUnits.cpuAndGPU)
            Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
        }
        .pickerStyle(.menu)
        .frame(width: 140)
    }
}

// MARK: - Transcription Config Popover

struct TranscriptionConfigPopover: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WhisperKit Settings")
                    .font(.title2)
                Spacer()
                Button { dismiss() } label: {
                    Label("Done", systemImage: "xmark.circle.fill")
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }

            Text("Compute Units")
                .font(.headline)

            computeUnitRow("Audio Encoder", selection: $settings.encoderComputeUnits)
            computeUnitRow("Text Decoder", selection: $settings.decoderComputeUnits)

            Text("Changes take effect on next model load.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Diarization Config Popover

struct DiarizationConfigPopover: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pyannote Settings")
                    .font(.title2)
                Spacer()
                Button { dismiss() } label: {
                    Label("Done", systemImage: "xmark.circle.fill")
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }

            Text("Compute Units")
                .font(.headline)

            computeUnitRow("Segmenter", selection: $settings.segmenterComputeUnits)
            computeUnitRow("Embedder", selection: $settings.embedderComputeUnits)

            Text("Changes take effect on next model load.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
