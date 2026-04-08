import SwiftUI
import UniformTypeIdentifiers
import Argmax

enum ExportFormat: String, CaseIterable, Identifiable {
    case srt = "SRT"
    case vtt = "VTT"
    case json = "JSON"
    case txt = "Plain Text"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .json: return "json"
        case .txt: return "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .srt: return .plainText
        case .vtt: return .plainText
        case .json: return .json
        case .txt: return .plainText
        }
    }
}

struct ExportSheet: View {
    @Binding var isPresented: Bool
    let segments: [TranscriptionSegment]
    let speakerSegments: [SpeakerSegment]?

    @State private var selectedFormat: ExportFormat = .txt
    @State private var includeSpeakerLabels = true
    @State private var includeTimestamps = true
    @State private var showFileExporter = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Transcription")
                .font(.headline)

            Picker("Format", selection: $selectedFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Include timestamps", isOn: $includeTimestamps)
            if let segments = speakerSegments, !segments.isEmpty {
                Toggle("Include speaker labels", isOn: $includeSpeakerLabels)
            }

            Divider()

            ScrollView {
                Text(generatePreview())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .glassSecondaryButtonStyle()
                Spacer()
                Button("Export") {
                    showFileExporter = true
                }
                .keyboardShortcut(.defaultAction)
                .glassProminentButtonStyle()
            }
        }
        .padding()
        .frame(maxHeight: .infinity, alignment: .top)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 350)
        #endif
        .fileExporter(
            isPresented: $showFileExporter,
            document: ExportDocument(content: generateExport()),
            contentType: selectedFormat.contentType,
            defaultFilename: "transcription.\(selectedFormat.fileExtension)"
        ) { result in
            if case .success = result {
                isPresented = false
            }
        }
    }

    private func generatePreview() -> String {
        let full = generateExport()
        if full.count > 2000 {
            return String(full.prefix(2000)) + "\n--- Preview truncated (full content will be exported) ---"
        }
        return full
    }

    private func generateExport() -> String {
        switch selectedFormat {
        case .srt: return ExportFormatters.toSRT(segments: segments, speakerSegments: speakerSegments, includeTimestamps: includeTimestamps, includeSpeakers: includeSpeakerLabels)
        case .vtt: return ExportFormatters.toVTT(segments: segments, speakerSegments: speakerSegments, includeTimestamps: includeTimestamps, includeSpeakers: includeSpeakerLabels)
        case .json: return ExportFormatters.toJSON(segments: segments, speakerSegments: speakerSegments, includeSpeakers: includeSpeakerLabels)
        case .txt: return ExportFormatters.toPlainText(segments: segments, speakerSegments: speakerSegments, includeTimestamps: includeTimestamps, includeSpeakers: includeSpeakerLabels)
        }
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }

    let content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        content = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    }
}

// MARK: - Pure Formatting Functions

enum ExportFormatters {
    static func toSRT(
        segments: [TranscriptionSegment],
        speakerSegments: [SpeakerSegment]?,
        includeTimestamps: Bool,
        includeSpeakers: Bool
    ) -> String {
        let items = if includeSpeakers, let segs = speakerSegments, !segs.isEmpty {
            speakerSegmentsToItems(segs)
        } else {
            transcriptionSegmentsToItems(segments)
        }

        return items.enumerated().map { index, item in
            let idx = index + 1
            let timeStr = includeTimestamps ? formatSRTTime(item.start) + " --> " + formatSRTTime(item.end) : ""
            let speaker = if includeSpeakers, let spk = item.speaker { "[\(spk)] " } else { "" }
            return includeTimestamps
                ? "\(idx)\n\(timeStr)\n\(speaker)\(item.text)\n"
                : "\(idx)\n\(speaker)\(item.text)\n"
        }.joined(separator: "\n")
    }

    static func toVTT(
        segments: [TranscriptionSegment],
        speakerSegments: [SpeakerSegment]?,
        includeTimestamps: Bool,
        includeSpeakers: Bool
    ) -> String {
        let items = if includeSpeakers, let segs = speakerSegments, !segs.isEmpty {
            speakerSegmentsToItems(segs)
        } else {
            transcriptionSegmentsToItems(segments)
        }

        var lines = ["WEBVTT", ""]
        for item in items {
            if includeTimestamps {
                lines.append(formatVTTTime(item.start) + " --> " + formatVTTTime(item.end))
            }
            let speaker = if includeSpeakers, let spk = item.speaker { "<v \(spk)>" } else { "" }
            lines.append("\(speaker)\(item.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func toJSON(
        segments: [TranscriptionSegment],
        speakerSegments: [SpeakerSegment]?,
        includeSpeakers: Bool
    ) -> String {
        var result: [[String: Any]] = []

        if includeSpeakers, let speakerSegs = speakerSegments, !speakerSegs.isEmpty {
            for segment in speakerSegs {
                let label = segment.speaker.speakerId.map { "Speaker \($0)" } ?? "Unknown"
                let start = segment.speakerWords.first?.wordTiming.start ?? 0
                let end = segment.speakerWords.last?.wordTiming.end ?? 0
                var dict: [String: Any] = [
                    "text": segment.text,
                    "start": start,
                    "end": end,
                    "speaker": label
                ]
                let words = segment.speakerWords.map(\.wordTiming)
                if !words.isEmpty {
                    dict["words"] = words.map { w in
                        ["word": w.word, "start": w.start, "end": w.end, "probability": w.probability]
                    }
                }
                result.append(dict)
            }
        } else {
            for segment in segments {
                var dict: [String: Any] = [
                    "text": segment.text,
                    "start": segment.start,
                    "end": segment.end
                ]
                if let words = segment.words {
                    dict["words"] = words.map { w in
                        ["word": w.word, "start": w.start, "end": w.end, "probability": w.probability]
                    }
                }
                result.append(dict)
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func toPlainText(
        segments: [TranscriptionSegment],
        speakerSegments: [SpeakerSegment]?,
        includeTimestamps: Bool,
        includeSpeakers: Bool
    ) -> String {
        if includeSpeakers, let speakers = speakerSegments, !speakers.isEmpty {
            return speakers.map { segment in
                let speakerLabel = SpeakerUI.label(for: segment.speaker.speakerId)
                let timestamp = includeTimestamps
                    ? "[\(String(format: "%.2f", segment.speakerWords.first?.wordTiming.start ?? 0)) -> \(String(format: "%.2f", segment.speakerWords.last?.wordTiming.end ?? 0))] "
                    : ""
                return "\(timestamp)\(speakerLabel): \(segment.text)"
            }.joined(separator: "\n")
        }

        return segments.map { segment in
            let timestamp = includeTimestamps
                ? "[\(String(format: "%.2f", segment.start)) -> \(String(format: "%.2f", segment.end))] "
                : ""
            return "\(timestamp)\(segment.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private struct ExportItem {
        let text: String
        let start: Float
        let end: Float
        let speaker: String?
    }

    private static func transcriptionSegmentsToItems(_ segments: [TranscriptionSegment]) -> [ExportItem] {
        segments.map { ExportItem(text: $0.text, start: $0.start, end: $0.end, speaker: nil) }
    }

    private static func speakerSegmentsToItems(_ segments: [SpeakerSegment]) -> [ExportItem] {
        segments.map { segment in
            let label = segment.speaker.speakerId.map { "Speaker \($0)" } ?? "Unknown"
            let start = segment.speakerWords.first?.wordTiming.start ?? 0
            let end = segment.speakerWords.last?.wordTiming.end ?? 0
            return ExportItem(text: segment.text, start: start, end: end, speaker: label)
        }
    }

    private static func formatSRTTime(_ seconds: Float) -> String {
        let total = Int(seconds)
        let ms = Int((seconds - Float(total)) * 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func formatVTTTime(_ seconds: Float) -> String {
        let total = Int(seconds)
        let ms = Int((seconds - Float(total)) * 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
