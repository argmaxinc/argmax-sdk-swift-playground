import SwiftUI
import Argmax

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A SwiftUI view that displays text with highlighted words matching a custom vocabulary.
/// Words whose `WordTiming` appears as a key in the vocabulary results are rendered bold blue.
/// For Qwen (keyword injection), pass `keywordHighlights` instead; simple case-insensitive
/// word matching is used and only applies when `customVocabularyResults` is empty.
/// When `itnHighlight` is true, tokens that look like ITN outputs (numbers, dates, etc.)
/// are underlined; hovering shows a tooltip with the estimated pre-normalization text.
struct HighlightedTextView: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.prefixText == rhs.prefixText &&
        lhs.segments == rhs.segments &&
        lhs.customVocabularyResults == rhs.customVocabularyResults &&
        lhs.keywordHighlights == rhs.keywordHighlights &&
        lhs.itnHighlight == rhs.itnHighlight &&
        lhs.font == rhs.font &&
        lhs.foregroundColor == rhs.foregroundColor
    }
    let prefixText: String
    let segments: [TranscriptionSegment]
    let customVocabularyResults: VocabularyResults
    let keywordHighlights: [String]
    let itnHighlight: Bool
    let font: Font
    let foregroundColor: Color

    init(
        prefixText: String = "",
        segments: [TranscriptionSegment] = [],
        customVocabularyResults: VocabularyResults = [:],
        keywordHighlights: [String] = [],
        itnHighlight: Bool = false,
        font: Font = .body,
        foregroundColor: Color = .primary
    ) {
        self.prefixText = prefixText
        self.segments = segments
        self.customVocabularyResults = customVocabularyResults
        self.keywordHighlights = keywordHighlights
        self.itnHighlight = itnHighlight
        self.font = font
        self.foregroundColor = foregroundColor
    }

    var body: some View {
        let attrStr = Self.createHighlightedAttributedString(
            prefixText: prefixText,
            segments: segments,
            customVocabularyResults: customVocabularyResults,
            keywordHighlights: keywordHighlights,
            itnHighlight: itnHighlight,
            font: font,
            foregroundColor: foregroundColor
        )
        let helpText = itnHighlight ? Self.itnHelpText(for: segments) : ""
        Text(attrStr).help(helpText)
    }


    /// Creates an AttributedString with custom vocabulary words highlighted in bold blue.
    /// - Parameters:
    ///   - prefixText: Text to prepend (timestamps, speaker labels, etc.) that remains unhighlighted.
    ///   - segments: Segments whose words should be concatenated and scanned for highlights.
    ///   - customVocabularyResults: Map of words to highlight keyed by their `WordTiming` (Parakeet path).
    ///   - keywordHighlights: Plain word list for simple case-insensitive matching (Qwen path).
    ///     Only applied when `customVocabularyResults` is empty.
    ///   - itnHighlight: When true, underline tokens that look like ITN outputs (numbers, dates, etc.).
    ///   - font: Base font to use.
    ///   - foregroundColor: Base foreground color.
    /// - Returns: AttributedString with highlighted vocabulary words.
    @MainActor static func createHighlightedAttributedString(
        prefixText: String = "",
        segments: [TranscriptionSegment] = [],
        customVocabularyResults: VocabularyResults = [:],
        keywordHighlights: [String] = [],
        itnHighlight: Bool = false,
        font: Font,
        foregroundColor: Color
    ) -> AttributedString {
        var attributedString = AttributedString(prefixText)
        attributedString.font = font
        attributedString.foregroundColor = foregroundColor

        let words = segments.flatMap { $0.words ?? [] }

        // Normalize keywords once. Only active when customVocabularyResults is empty so the
        // Parakeet exact-replacement path is never affected.
        let normalizedKeywords: Set<String> = customVocabularyResults.isEmpty && !keywordHighlights.isEmpty
            ? Set(keywordHighlights.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            : []

        if words.isEmpty {
            let fallbackText = segments.map(\.text).joined(separator: " ")
            if !fallbackText.isEmpty {
                if normalizedKeywords.isEmpty && !itnHighlight {
                    var fallback = AttributedString(fallbackText)
                    fallback.font = font
                    fallback.foregroundColor = foregroundColor
                    attributedString.append(fallback)
                } else {
                    appendKeywordHighlighted(
                        text: fallbackText,
                        keywords: normalizedKeywords,
                        itnHighlight: itnHighlight,
                        to: &attributedString,
                        font: font,
                        foregroundColor: foregroundColor
                    )
                }
            }
            return attributedString
        }

        // `customVocabularyResults` keys are the inserted (boosted) words that actually replaced
        // original transcript words -- only those specific occurrences should be highlighted. A
        // word that appears in the base transcript and merely happens to match a custom vocabulary
        // entry (no replacement occurred) is NOT a key and must stay unhighlighted.
        //
        // Identify the overridden occurrence by word text + time-range overlap rather than full
        // `WordTiming` equality. The vocabulary result's key carries its own start/end (aligned
        // separately to the global timeline) and probability, which don't stay byte-identical to
        // the displayed segment word -- especially while streaming, where timings and probabilities
        // are refined as words move from hypothesis to confirmed. Full-struct equality drops the
        // highlight the moment any of those volatile fields drift, even though the override stands.
        // Time-range overlap tolerates that drift while still pinpointing the exact occurrence:
        // distinct occurrences of the same word never overlap in time, so a coincidental base word
        // (which has no key at its position) never matches.
        var overrideRangesByWord: [String: [(start: Float, end: Float)]] = [:]
        for key in customVocabularyResults.keys {
            let keyText = key.word.trimmingCharacters(in: .whitespaces)
            guard !keyText.isEmpty else { continue }
            overrideRangesByWord[keyText, default: []].append((key.start, key.end))
        }

        // Pre-compute which word indices are covered by multi-word keyword phrase matches.
        // Single-word keywords are checked inline; phrases require a sliding-window pass first.
        var phraseMatchedIndices = Set<Int>()
        let keywordPhrases = normalizedKeywords.filter { $0.contains(" ") }
        if !keywordPhrases.isEmpty {
            for phraseStr in keywordPhrases {
                let phraseTokens = phraseStr.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                let n = phraseTokens.count
                guard n > 1 else { continue }
                for i in 0..<words.count {
                    guard i + n <= words.count else { break }
                    let candidate = words[i..<(i + n)].map {
                        $0.word.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)).lowercased()
                    }.joined(separator: " ")
                    if candidate == phraseStr {
                        for j in i..<(i + n) { phraseMatchedIndices.insert(j) }
                    }
                }
            }
        }
        let keywordSingleWords = Set(normalizedKeywords.filter { !$0.contains(" ") })

        for (wordIndex, wordTiming) in words.enumerated() {
            let wordText = wordTiming.word
            guard !wordText.isEmpty else { continue }

            appendSpacerIfNeeded(
                nextText: wordText,
                to: &attributedString,
                font: font,
                foregroundColor: foregroundColor
            )

            var wordAttributed = AttributedString(wordText)

            let trimmedWord = wordText.trimmingCharacters(in: .whitespaces)
            let strippedWord = trimmedWord.trimmingCharacters(in: .punctuationCharacters)

            let isOverride = overrideRangesByWord[trimmedWord]?.contains { range in
                range.start <= wordTiming.end && wordTiming.start <= range.end
            } ?? false
            let isKeyword = !normalizedKeywords.isEmpty && (
                phraseMatchedIndices.contains(wordIndex) ||
                (!strippedWord.isEmpty && keywordSingleWords.contains(strippedWord.lowercased()))
            )
            let isITN = itnHighlight && looksLikeITNOutput(strippedWord)

            if isOverride || isKeyword {
                wordAttributed.font = font.bold()
                wordAttributed.foregroundColor = .blue
            } else {
                wordAttributed.font = font
                wordAttributed.foregroundColor = foregroundColor
            }
            if isITN {
                wordAttributed.underlineStyle = Text.LineStyle(pattern: .solid)
            }
            attributedString.append(wordAttributed)
        }

        // Disable CoreText hyphenation to avoid expensive CFStringGetHyphenationLocationBeforeIndex
        // calls during layout measurement. Without this, the system locale enables hyphenation
        // by default, causing significant overhead every time the scroll view re-measures text.
        let platform = Self.makePlatformAttributed(attributedString)
        return (try? AttributedString(platform, including: \.swiftUI)) ?? attributedString
    }

    /// Appends `text` to `attributedString` token-by-token, applying bold blue to keyword matches
    /// (including multi-word phrases) and underline to ITN-detected tokens.
    /// Used for both the Qwen no-word-timing path and the ITN-only path.
    private static func appendKeywordHighlighted(
        text: String,
        keywords: Set<String>,  // lowercased, may include multi-word phrases
        itnHighlight: Bool,
        to attributedString: inout AttributedString,
        font: Font,
        foregroundColor: Color
    ) {
        // Separate phrases (sorted longest-first for greedy matching) from single words
        let phrases = keywords.filter { $0.contains(" ") }.sorted { $0.count > $1.count }
        let singleWords = Set(keywords.filter { !$0.contains(" ") })

        var pos = text.startIndex

        while pos < text.endIndex {
            if text[pos].isWhitespace {
                let wsStart = pos
                while pos < text.endIndex && text[pos].isWhitespace {
                    pos = text.index(after: pos)
                }
                var ws = AttributedString(String(text[wsStart..<pos]))
                ws.font = font
                ws.foregroundColor = foregroundColor
                attributedString.append(ws)
                continue
            }

            var phraseMatched = false
            for phrase in phrases {
                guard text.distance(from: pos, to: text.endIndex) >= phrase.count else { continue }
                guard let candidateEnd = text.index(pos, offsetBy: phrase.count, limitedBy: text.endIndex) else { continue }
                guard String(text[pos..<candidateEnd]).lowercased() == phrase else { continue }
                // Require a word boundary after the phrase
                let afterOk = candidateEnd == text.endIndex
                    || text[candidateEnd].isWhitespace
                    || text[candidateEnd].isPunctuation
                guard afterOk else { continue }

                var part = AttributedString(String(text[pos..<candidateEnd]))
                part.font = font.bold()
                part.foregroundColor = .blue
                attributedString.append(part)
                pos = candidateEnd
                phraseMatched = true
                break
            }
            if phraseMatched { continue }

            // Extract next word up to whitespace
            let wordStart = pos
            while pos < text.endIndex && !text[pos].isWhitespace {
                pos = text.index(after: pos)
            }
            let token = String(text[wordStart..<pos])
            let stripped = token.trimmingCharacters(in: .punctuationCharacters).lowercased()

            let isKeyword = !stripped.isEmpty && singleWords.contains(stripped)
            let isITN = itnHighlight && looksLikeITNOutput(stripped)

            var part = AttributedString(token)
            if isKeyword {
                part.font = font.bold()
                part.foregroundColor = .blue
            } else {
                part.font = font
                part.foregroundColor = foregroundColor
            }
            if isITN {
                part.underlineStyle = Text.LineStyle(pattern: .solid)
            }
            attributedString.append(part)
        }
    }

    // MARK: - ITN detection

    /// Shared spell-out formatter (main-thread use only, matching the render pass).
    private static let spellOutFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale.current
        return f
    }()


    /// Returns true if `word` looks like an ITN output (a number, date, time, currency, ordinal, etc.).
    /// Only tokens that would have been in textual form before ITN match these patterns.
    /// Compiled once: this runs per token per render, and recompiling nine regexes
    /// each time dominated the highlight pass.
    private static let itnPatterns: [NSRegularExpression] = [
            #"^\d+$"#,                                     // integers: 23, 1000
            #"^\d{1,3}(,\d{3})+$"#,                        // formatted: 1,000,000
            #"^\d+\.\d+$"#,                                // decimals: 3.14
            #"^\d+%$"#,                                     // percentages: 50%
            #"^[\$€£¥₹]\d"#,                               // currency: $50, €100
            #"^\d+(st|nd|rd|th)$"#,                        // ordinals: 1st, 23rd
            #"^\d{1,4}[/\-]\d{1,2}([/\-]\d{2,4})?$"#,     // dates: 12/25, 12/25/2024
            #"^\d{1,2}:\d{2}(:\d{2})?( ?[AaPp][Mm])?$"#,  // times: 3:30, 12:00 PM
            #"^\d{3}[-.]?\d{3}[-.]?\d{4}$"#,               // phone: 555-555-5555
        ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static func looksLikeITNOutput(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let range = NSRange(word.startIndex..., in: word)
        return itnPatterns.contains { $0.firstMatch(in: word, range: range) != nil }
    }

    /// Generates a tooltip string summarising the ITN tokens found in `segments` and their
    /// estimated pre-normalization spoken forms. Returns "" when no ITN tokens are detected.
    private static func itnHelpText(for segments: [TranscriptionSegment]) -> String {
        let words = segments.flatMap { $0.words ?? [] }
        var mappings: [(normalized: String, original: String)] = []

        func process(token: String) {
            let stripped = token.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            guard !stripped.isEmpty, looksLikeITNOutput(stripped) else { return }
            if let original = estimateOriginalText(stripped) {
                mappings.append((stripped, original))
            }
        }

        if words.isEmpty {
            for token in segments.map(\.text).joined(separator: " ").components(separatedBy: .whitespaces) {
                process(token: token)
            }
        } else {
            for w in words { process(token: w.word) }
        }

        guard !mappings.isEmpty else { return "" }
        return "Before ITN: " + mappings.map { "\($0.original) -> \($0.normalized)" }.joined(separator: ", ")
    }

    /// Attempts to reverse an ITN output token back to its spoken form.
    /// Returns nil when no reliable estimate can be made.
    private static func estimateOriginalText(_ word: String) -> String? {
        let spellOut = Self.spellOutFormatter

        // Ordinals: "23rd" -> "twenty-third"
        if word.range(of: #"^\d+(st|nd|rd|th)$"#, options: .regularExpression) != nil {
            let numStr = word.replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "",
                                                    options: .regularExpression)
            if let n = Int(numStr), let spelled = spellOut.string(from: NSNumber(value: n)) {
                return spelled
            }
        }

        // Percentages: "50%" -> "fifty percent"
        if word.hasSuffix("%"), let n = Double(word.dropLast()) {
            if let spelled = spellOut.string(from: NSNumber(value: n)) {
                return spelled + " percent"
            }
        }

        // Currency: "$50" -> "fifty dollars" (locale-independent approximation)
        let currencySymbols = CharacterSet(charactersIn: "$€£¥₹")
        if let first = word.unicodeScalars.first, currencySymbols.contains(first) {
            let stripped = String(word.dropFirst())
            if let n = Double(stripped.replacingOccurrences(of: ",", with: "")),
               let spelled = spellOut.string(from: NSNumber(value: n)) {
                return spelled
            }
        }

        // Formatted integers with commas: "1,000" -> "one thousand"
        let noCommas = word.replacingOccurrences(of: ",", with: "")
        if word.contains(","), let n = Int(noCommas),
           let spelled = spellOut.string(from: NSNumber(value: n)) {
            return spelled
        }

        // Pure integers
        if let n = Int(word), let spelled = spellOut.string(from: NSNumber(value: n)) {
            return spelled
        }

        // Decimals
        if let n = Double(word), let spelled = spellOut.string(from: NSNumber(value: n)) {
            return spelled
        }

        return nil
    }

    /// Converts an `AttributedString` to an `NSAttributedString` with hyphenation disabled.
    @MainActor
    static func makePlatformAttributed(_ base: AttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(base))
        let noHyphen = NSMutableParagraphStyle()
        noHyphen.hyphenationFactor = 0.0
        mutable.addAttribute(.paragraphStyle, value: noHyphen,
                             range: NSRange(location: 0, length: mutable.length))
        return mutable
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
    let numWord = WordTiming(word: "23", tokens: [], start: 1.5, end: 1.7, probability: 0.9)
    let pctWord = WordTiming(word: "50%", tokens: [], start: 1.7, end: 1.9, probability: 0.9)

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
        text: "Argmax SDK loved by 23 developers, 50% are happy",
        words: [
            WordTiming(word: "Argmax", tokens: [], start: 0.9, end: 1.0, probability: 0.9),
            sdkWord,
            WordTiming(word: "loved", tokens: [], start: 1.0, end: 1.1, probability: 0.9),
            WordTiming(word: "by", tokens: [], start: 1.1, end: 1.2, probability: 0.9),
            numWord,
            developersWord,
            WordTiming(word: ",", tokens: [], start: 1.9, end: 1.9, probability: 0.9),
            pctWord,
            WordTiming(word: "are", tokens: [], start: 1.9, end: 2.0, probability: 0.9),
            WordTiming(word: "happy", tokens: [], start: 2.0, end: 2.2, probability: 0.9),
        ]
    )

    VStack(alignment: .leading, spacing: 16) {
        Text("Vocab highlighting + ITN underline:").font(.caption).foregroundStyle(.secondary)
        HighlightedTextView(
            prefixText: "[00.00 -> 02.50] ",
            segments: [greetingSegment],
            customVocabularyResults: vocabulary,
            itnHighlight: true,
            font: .headline
        )

        HighlightedTextView(
            segments: [sdkSegment],
            customVocabularyResults: vocabulary,
            itnHighlight: true,
            font: .body
        )

        Text("Keyword (Qwen) + multi-word phrase:").font(.caption).foregroundStyle(.secondary)
        HighlightedTextView(
            segments: [TranscriptionSegment(text: "Apple Watch runs on watchOS 11")],
            keywordHighlights: ["Apple Watch", "watchOS"],
            itnHighlight: true,
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
