import SwiftUI
import Argmax

/// A SwiftUI view that displays text with highlighted words matching a custom vocabulary.
/// Words whose `WordTiming` appears as a key in the vocabulary results are rendered bold blue.
struct HighlightedTextView: View {
    let prefixText: String
    let segments: [TranscriptionSegment]
    let customVocabularyResults: VocabularyResults
    let font: Font
    let foregroundColor: Color
    
    init(
        prefixText: String = "",
        segments: [TranscriptionSegment] = [],
        customVocabularyResults: VocabularyResults = [:],
        font: Font = .body,
        foregroundColor: Color = .primary
    ) {
        self.prefixText = prefixText
        self.segments = segments
        self.customVocabularyResults = customVocabularyResults
        self.font = font
        self.foregroundColor = foregroundColor
    }
    
    var body: some View {
        Text(
            Self.createHighlightedAttributedString(
                prefixText: prefixText,
                segments: segments,
                customVocabularyResults: customVocabularyResults,
                font: font,
                foregroundColor: foregroundColor
            )
        )
    }
    
    /// Creates an AttributedString with custom vocabulary words highlighted in bold blue.
    /// - Parameters:
    ///   - prefixText: Text to prepend (timestamps, speaker labels, etc.) that remains unhighlighted.
    ///   - segments: Segments whose words should be concatenated and scanned for highlights.
    ///   - customVocabularyResults: Map of words to highlight keyed by their `WordTiming`.
    ///   - font: Base font to use.
    ///   - foregroundColor: Base foreground color.
    /// - Returns: AttributedString with highlighted vocabulary words.
    static func createHighlightedAttributedString(
        prefixText: String = "",
        segments: [TranscriptionSegment] = [],
        customVocabularyResults: VocabularyResults = [:],
        font: Font,
        foregroundColor: Color
    ) -> AttributedString {
        var attributedString = AttributedString(prefixText)
        attributedString.font = font
        attributedString.foregroundColor = foregroundColor
        
        let words = segments.flatMap { $0.words ?? [] }
        
        if words.isEmpty {
            let fallbackText = segments.map(\.text).joined(separator: " ")
            if !fallbackText.isEmpty {
                appendSpacerIfNeeded(
                    nextText: fallbackText,
                    to: &attributedString,
                    font: font,
                    foregroundColor: foregroundColor
                )
                var fallback = AttributedString(fallbackText)
                fallback.font = font
                fallback.foregroundColor = foregroundColor
                attributedString.append(fallback)
            }
            return attributedString
        }
        
        let highlightKeys = Set(customVocabularyResults.keys)
        
        for wordTiming in words {
            let wordText = wordTiming.word
            guard !wordText.isEmpty else { continue }
            
            appendSpacerIfNeeded(
                nextText: wordText,
                to: &attributedString,
                font: font,
                foregroundColor: foregroundColor
            )
            
            var wordAttributed = AttributedString(wordText)
            
            if highlightKeys.contains(where: { highlightedWordTiming in
                return wordTiming.probability == highlightedWordTiming.probability
            }) {
                wordAttributed.font = font.bold()
                wordAttributed.foregroundColor = .blue
            } else {
                wordAttributed.font = font
                wordAttributed.foregroundColor = foregroundColor
            }
            attributedString.append(wordAttributed)
        }
        
        return attributedString
    }
    
    private static func appendSpacerIfNeeded(
        nextText: String,
        to attributedString: inout AttributedString,
        font: Font,
        foregroundColor: Color
    ) {
        guard let firstCharacter = nextText.first else { return }
        guard !firstCharacter.isWhitespace else { return }
        guard !firstCharacter.isPunctuation else { return }
        guard let lastCharacter = attributedString.characters.last else { return }
        guard !lastCharacter.isWhitespace else { return }
        
        var spacer = AttributedString(" ")
        spacer.font = font
        spacer.foregroundColor = foregroundColor
        attributedString.append(spacer)
    }
}

#Preview {
    let helloWord = WordTiming(word: "Hello", tokens: [], start: 0.0, end: 0.3, probability: 0.95)
    let specialWord = WordTiming(word: "special", tokens: [], start: 0.3, end: 0.6, probability: 0.92)
    let worldWord = WordTiming(word: "world", tokens: [], start: 0.6, end: 0.9, probability: 0.9)
    let sdkWord = WordTiming(word: "SDK", tokens: [], start: 1.0, end: 1.2, probability: 0.9)
    let developersWord = WordTiming(word: "developers", tokens: [], start: 1.2, end: 1.5, probability: 0.9)
    
    let vocabulary: VocabularyResults = [
        helloWord: [helloWord],
        specialWord: [specialWord],
        sdkWord: [sdkWord],
        developersWord: [developersWord]
    ]
    
    let greetingSegment = TranscriptionSegment(
        text: "Hello special world",
        words: [helloWord, specialWord, worldWord]
    )
    
    let sdkSegment = TranscriptionSegment(
        text: "Argmax SDK loved by developers",
        words: [
            WordTiming(word: "Argmax", tokens: [], start: 0.9, end: 1.0, probability: 0.9),
            sdkWord,
            WordTiming(word: "loved", tokens: [], start: 1.0, end: 1.1, probability: 0.9),
            WordTiming(word: "by", tokens: [], start: 1.1, end: 1.2, probability: 0.9),
            developersWord
        ]
    )
    
    VStack(alignment: .leading, spacing: 16) {
        HighlightedTextView(
            prefixText: "[00.00 → 02.50] ",
            segments: [greetingSegment],
            customVocabularyResults: vocabulary,
            font: .headline
        )
        
        HighlightedTextView(
            segments: [sdkSegment],
            customVocabularyResults: vocabulary,
            font: .body
        )
        
        HighlightedTextView(
            prefixText: "Preview text only",
            segments: [],
            customVocabularyResults: [:],
            font: .caption,
            foregroundColor: .secondary
        )
    }
    .padding()
}
