import SwiftUI
import Foundation

struct CustomVocabularySheet: View {
    @Binding var isPresented: Bool
    @Binding var words: [String]
    @Binding var input: String
    @Binding var isEditing: Bool
    @EnvironmentObject private var sdkCoordinator: ArgmaxSDKCoordinator

    let canUpdateVocabulary: () -> Bool
    let onError: (String) -> Void

    @FocusState private var textEditorFocused: Bool

    
    private var hasExistingVocabulary: Bool { !words.isEmpty }

    /// `true` when Qwen is the active transcriber (vocabulary injection, no model download needed).
    private var isQwenMode: Bool {
        sdkCoordinator.qwen != nil
    }

    /// Parses user input for custom vocabulary by cleaning and formatting the words.
    ///
    /// - Parameter input: The raw user input string with comma- or line-separated words
    /// - Returns: An array of trimmed, non-empty vocabulary words
    func parseCustomVocabulary(_ input: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        return input
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `true` when the user has a custom-vocabulary model selected, a transcription model is
    /// loaded, and the CTC graph isn't paired with it -- the SDK pairs custom vocabulary with
    /// Parakeet transcription models. Qwen never shows this warning (no model pairing needed).
    private var customVocabUnsupported: Bool {
        guard !isQwenMode else { return false }
        guard sdkCoordinator.pipelineSelection.customVocabularyModel != nil else { return false }
        guard sdkCoordinator.whisperKitModelState == .loaded else { return false }
        return sdkCoordinator.whisperKit?.customVocabularyModelState != .loaded
    }

    var body: some View {
        let isEditingMode = hasExistingVocabulary ? isEditing : true
        let listHeight = min(CGFloat(max(words.count, 1)) * 44, 320)

        VStack(spacing: 20) {
            Text("Set Custom Vocabulary")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(isQwenMode
                 ? "Enter words or phrases separated by commas or line breaks. Words are injected as prompt context — no extra model download required."
                 : "Enter words or phrases separated by commas or line breaks. Requires loading a parakeet model with custom vocabulary enabled.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            if customVocabUnsupported {
                Label(
                    "The loaded transcription model doesn't support custom vocabulary. Unload and switch to a Parakeet model to apply these words.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            if hasExistingVocabulary {
                Picker("", selection: $isEditing) {
                    Text("View").tag(false)
                    Text("Edit").tag(true)
                }
                .pickerStyle(.segmented)
            }

            if isEditingMode {
                TextEditor(text: $input)
                    .font(.body)
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    .focused($textEditorFocused)
                    .onAppear {
                        DispatchQueue.main.async { textEditorFocused = true }
                    }
                    .onChange(of: isEditing) { _, editing in
                        if editing {
                            DispatchQueue.main.async { textEditorFocused = true }
                        } else {
                            textEditorFocused = false
                        }
                    }
            } else {
                if words.isEmpty {
                    Text("No custom vocabulary set yet.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .center, spacing: 0) {
                            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                                Text(word)
                                    .font(.body)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 6)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: 420)
                    .frame(height: listHeight)
                    .frame(maxWidth: .infinity)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                if isEditingMode {
                    Button("Cancel") {
                        isPresented = false
                        isEditing = hasExistingVocabulary ? false : true
                        textEditorFocused = false
                    }
                    .glassSecondaryButtonStyle()
                    .frame(maxWidth: .infinity)

                    Button("Save") {
                        let newWords = parseCustomVocabulary(input)
                        words = newWords
                        input = newWords.joined(separator: "\n")
                        isPresented = false
                        isEditing = newWords.isEmpty ? true : false
                        textEditorFocused = false

                        guard canUpdateVocabulary() else { return }

                        Task {
                            do {
                                try sdkCoordinator.updateCustomVocabulary(words: newWords)
                            } catch {
                                await MainActor.run {
                                    let message = error.localizedDescription.isEmpty ? "Vocabulary saved but could not be applied to the running model. It will take effect on next model load." : error.localizedDescription
                                    onError(message)
                                }
                            }
                        }
                    }
                    .glassProminentButtonStyle()
                    .frame(maxWidth: .infinity)
                } else {
                    Button("Done") {
                        isPresented = false
                        isEditing = false
                    }
                    .glassProminentButtonStyle()
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .onDisappear {
            textEditorFocused = false
        }
    }
}
