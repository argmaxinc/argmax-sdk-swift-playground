import SwiftUI
import Argmax

/// A SwiftUI view that displays text with highlighted words matching a custom vocabulary
/// Words that match the vocabulary are displayed in bold blue
struct HighlightedTextView: View {
    let text: String
    let customVocabularyResults: [WordTiming: [WordTiming]]
    let font: Font
    let foregroundColor: Color
    
    init(
        text: String,
        customVocabularyResults: [WordTiming: [WordTiming]],
        font: Font = .body,
        foregroundColor: Color = .primary
    ) {
        self.text = text
        self.customVocabularyResults = customVocabularyResults
        self.font = font
        self.foregroundColor = foregroundColor
    }
    
    var body: some View {
        if customVocabularyResults.isEmpty {
            Text(text)
                .font(font)
                .foregroundColor(foregroundColor)
        } else {
            Text(Self.createHighlightedAttributedString(
                text: text,
                customVocabularyResults: customVocabularyResults,
                font: font,
                foregroundColor: foregroundColor
            ))
        }
    }
    
    /// Creates an AttributedString with custom vocabulary words highlighted in bold blue
    /// - Parameters:
    ///   - text: The text to process
    ///   - customVocabularyResults: Map of vocabulary matches keyed by their associated `WordTiming`
    ///   - font: Base font to use
    ///   - foregroundColor: Base foreground color
    /// - Returns: AttributedString with highlighted vocabulary words
    static func createHighlightedAttributedString(
        text: String,
        customVocabularyResults: [WordTiming: [WordTiming]],
        font: Font,
        foregroundColor: Color
    ) -> AttributedString {
        var attributedString = AttributedString(text)

        // Set base font and color
        attributedString.font = font
        attributedString.foregroundColor = foregroundColor

        guard !customVocabularyResults.isEmpty else { return attributedString }

        let vocabularyWords = sanitizedVocabularyWords(from: customVocabularyResults)
        guard !vocabularyWords.isEmpty else { return attributedString }

        // Sort vocabulary by length (longest first) to match longer phrases before shorter ones
        let sortedVocabulary = vocabularyWords.sorted { $0.count > $1.count }

        // Use a set for O(1) overlap checking instead of array
        var highlightedPositions = Set<Int>()

        for phrase in sortedVocabulary {
            // Find all occurrences using native String search
            var searchRange = text.startIndex..<text.endIndex

            while let range = text.range(of: phrase, range: searchRange) {
                // Convert String indices to character positions
                let startPos = text.distance(from: text.startIndex, to: range.lowerBound)
                let endPos = text.distance(from: text.startIndex, to: range.upperBound)

                let isOverlapping = (startPos..<endPos).contains { highlightedPositions.contains($0) }

                if !isOverlapping {
                    let attrStartIndex = attributedString.index(attributedString.startIndex, offsetByCharacters: startPos)
                    let attrEndIndex = attributedString.index(attributedString.startIndex, offsetByCharacters: endPos)
                    let attrRange = attrStartIndex..<attrEndIndex

                    // Highlight this phrase and mark positions as highlited
                    attributedString[attrRange].font = font.bold()
                    attributedString[attrRange].foregroundColor = .blue
                    for pos in startPos..<endPos {
                        highlightedPositions.insert(pos)
                    }
                }

                // Move search range past this occurrence
                searchRange = range.upperBound..<text.endIndex
            }
        }

        return attributedString
    }

    private static func sanitizedVocabularyWords(from results: [WordTiming: [WordTiming]]) -> [String] {
        let trimmingCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return results.keys.compactMap { timing in
            let trimmed = timing.word.trimmingCharacters(in: trimmingCharacters)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

#Preview {
    let helloWord = WordTiming(word: " hello,", tokens: [], start: 0.0, end: 0.3, probability: 0.95)
    let specialWords = WordTiming(word: "special words", tokens: [], start: 0.4, end: 0.9, probability: 0.92)
    let argmaxWord = WordTiming(word: "Argmax Pro SDK", tokens: [], start: 0.0, end: 0.0, probability: 0.9)
    let developerWord = WordTiming(word: "developers", tokens: [], start: 0.0, end: 0.0, probability: 0.9)
    let johnWord = WordTiming(word: "John Smith", tokens: [], start: 0.0, end: 0.0, probability: 0.9)
    let janeWord = WordTiming(word: "Jane Doe", tokens: [], start: 0.0, end: 0.0, probability: 0.9)
    let apiWord = WordTiming(word: "API Gateway", tokens: [], start: 0.0, end: 0.0, probability: 0.9)

    let previewVocabulary: [WordTiming: [WordTiming]] = [
        helloWord: [helloWord],
        specialWords: [specialWords],
        argmaxWord: [argmaxWord],
        developerWord: [developerWord],
        johnWord: [johnWord],
        janeWord: [janeWord],
        apiWord: [apiWord]
    ]

    VStack(alignment: .leading, spacing: 16) {
        HighlightedTextView(
            text: "Hello world, this is a test message with some special words.",
            customVocabularyResults: previewVocabulary,
            font: .headline
        )
        
        HighlightedTextView(
            text: "The Argmax Pro SDK loved by many developers.",
            customVocabularyResults: previewVocabulary,
            font: .body
        )
        
        HighlightedTextView(
            text: "John Smith and Jane Doe attended the meeting about the API Gateway.",
            customVocabularyResults: previewVocabulary,
            font: .caption,
            foregroundColor: .secondary
        )
    }
    .padding()
}
