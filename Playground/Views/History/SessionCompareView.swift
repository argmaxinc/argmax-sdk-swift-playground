import SwiftUI
import Argmax

struct SessionCompareView: View {
    let left: SessionRecord
    let right: SessionRecord
    let onBack: () -> Void

    @State private var viewMode: TabMode = .transcription

    private var eitherHasSpeakerData: Bool {
        left.hasSpeakerData || right.hasSpeakerData
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsDiff
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            if eitherHasSpeakerData {
                Picker("View", selection: $viewMode) {
                    Text("Transcription").tag(TabMode.transcription)
                    Text("Speakers").tag(TabMode.diarize)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .padding(.vertical, 6)
            }

            HStack(alignment: .top, spacing: 0) {
                transcriptColumn(record: left, label: "A")
                Divider()
                transcriptColumn(record: right, label: "B")
            }
        }
    }

    // MARK: - Settings & Performance Comparison

    private var settingsDiff: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings Comparison")
                .font(.subheadline)
                .bold()

            settingDiffRow("Model", left: left.settings.whisperKitModel, right: right.settings.whisperKitModel)
            settingDiffRow("Diarization", left: left.settings.diarizationModel, right: right.settings.diarizationModel)

            if left.settings.sortformerMode != "" || right.settings.sortformerMode != "" {
                settingDiffRow("Mode", left: left.settings.sortformerMode, right: right.settings.sortformerMode)
            }

            settingDiffRow("Strategy", left: left.settings.speakerInfoStrategy, right: right.settings.speakerInfoStrategy)
            settingDiffRow("Duration", left: left.displayDuration, right: right.displayDuration)

            if hasAnyPerformanceData {
                Divider()
                Text("Transcription Performance")
                    .font(.subheadline)
                    .bold()

                if let lt = left.transcriptionTimings, let rt = right.transcriptionTimings {
                    timingDiffRow("tok/s", left: lt.tokensPerSecond, right: rt.tokensPerSecond, higherIsBetter: true)
                    timingDiffRow("RTF", left: lt.realTimeFactor, right: rt.realTimeFactor, higherIsBetter: false)
                    timingDiffRow("Speed", left: lt.speedFactor, right: rt.speedFactor, higherIsBetter: true)
                    timingDiffRow("Audio Proc (ms)", left: lt.audioProcessing * 1000, right: rt.audioProcessing * 1000, higherIsBetter: false)
                    timingDiffRow("Encoding (ms)", left: lt.encoding * 1000, right: rt.encoding * 1000, higherIsBetter: false)
                    timingDiffRow("Decoding (ms)", left: lt.decodingLoop * 1000, right: rt.decodingLoop * 1000, higherIsBetter: false)
                    timingDiffRow("Pipeline (s)", left: lt.fullPipeline, right: rt.fullPipeline, higherIsBetter: false)
                }

                if hasAnyDiarizationData {
                    Divider()
                    Text("Diarization Performance")
                        .font(.subheadline)
                        .bold()

                    diarizationPerformanceRows
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    @ViewBuilder
    private var diarizationPerformanceRows: some View {
        if let ld = left.diarizationTimings, let rd = right.diarizationTimings {
            if ld.segmenterTime > 0 || rd.segmenterTime > 0 {
                timingDiffRow("Segmenter (ms)", left: ld.segmenterTime, right: rd.segmenterTime, higherIsBetter: false)
            }
            if ld.embedderTime > 0 || rd.embedderTime > 0 {
                timingDiffRow("Embedder (ms)", left: ld.embedderTime, right: rd.embedderTime, higherIsBetter: false)
            }
            if ld.clusteringTime > 0 || rd.clusteringTime > 0 {
                timingDiffRow("Clustering (ms)", left: ld.clusteringTime, right: rd.clusteringTime, higherIsBetter: false)
            }
            timingDiffRow("Diarize Total (s)", left: ld.fullPipeline / 1000.0, right: rd.fullPipeline / 1000.0, higherIsBetter: false)
        } else if #available(macOS 15, iOS 18, *),
                  let leftSD = left.streamingDiarizationTimings as? StreamingDiarizationTimings,
                  let rightSD = right.streamingDiarizationTimings as? StreamingDiarizationTimings,
                  leftSD.fullPipeline > 0 || rightSD.fullPipeline > 0 {
            if leftSD.melSpectrogramTime > 0 || rightSD.melSpectrogramTime > 0 {
                timingDiffRow("Mel Spec (ms)", left: leftSD.melSpectrogramTime, right: rightSD.melSpectrogramTime, higherIsBetter: false)
            }
            if leftSD.preEncoderTime > 0 || rightSD.preEncoderTime > 0 {
                timingDiffRow("Pre-Encoder (ms)", left: leftSD.preEncoderTime, right: rightSD.preEncoderTime, higherIsBetter: false)
            }
            if leftSD.fullEncoderTime > 0 || rightSD.fullEncoderTime > 0 {
                timingDiffRow("Encoder (ms)", left: leftSD.fullEncoderTime, right: rightSD.fullEncoderTime, higherIsBetter: false)
            }
            timingDiffRow("Diarize Total (ms)", left: leftSD.fullPipeline, right: rightSD.fullPipeline, higherIsBetter: false)
        } else {
            let leftDur = left.diarizationTimings?.fullPipeline ?? left.diarizationDurationMs ?? 0
            let rightDur = right.diarizationTimings?.fullPipeline ?? right.diarizationDurationMs ?? 0
            if leftDur > 0 || rightDur > 0 {
                timingDiffRow("Diarize Total (s)", left: leftDur / 1000.0, right: rightDur / 1000.0, higherIsBetter: false)
            }
        }
    }

    private var hasAnyPerformanceData: Bool {
        (left.transcriptionTimings != nil && right.transcriptionTimings != nil) ||
        hasAnyDiarizationData
    }

    private var hasAnyDiarizationData: Bool {
        (left.diarizationTimings != nil && right.diarizationTimings != nil) ||
        (left.streamingDiarizationTimings != nil && right.streamingDiarizationTimings != nil) ||
        ((left.diarizationDurationMs ?? 0) > 0 && (right.diarizationDurationMs ?? 0) > 0)
    }

    // MARK: - Row Helpers

    private func settingDiffRow(_ label: String, left: String, right: String) -> some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(left)
                .foregroundColor(left != right ? .orange : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(right)
                .foregroundColor(left != right ? .orange : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timingDiffRow(_ label: String, left: Double, right: Double, higherIsBetter: Bool) -> some View {
        let diff = right - left
        let leftIsBetter = higherIsBetter ? left > right : left < right
        return HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .trailing)
            Text(String(format: "%.2f", left))
                .foregroundColor(leftIsBetter ? .green : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.2f", right))
                .foregroundColor(!leftIsBetter ? .green : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%+.2f", diff))
                .foregroundColor(diff == 0 ? .secondary : (higherIsBetter == (diff > 0) ? .green : .red))
                .frame(width: 60, alignment: .trailing)
        }
    }

    // MARK: - Transcript Columns

    private func transcriptColumn(record: SessionRecord, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Session \(label)")
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(record.displayTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if viewMode == .diarize {
                        speakerContent(for: record)
                    } else {
                        ForEach(Array(record.segments.enumerated()), id: \.offset) { _, segment in
                            Text(segment.text)
                                .font(.body)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func speakerContent(for record: SessionRecord) -> some View {
        let displaySegments = record.displaySpeakerSegments
        if displaySegments.isEmpty {
            Text("No speaker data")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(8)
        } else {
            ForEach(Array(displaySegments.enumerated()), id: \.element.id) { index, segment in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if index == 0 || displaySegments[index - 1].speakerId != segment.speakerId {
                            Text(SpeakerUI.label(for: segment.speakerId))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        Text(segment.text)
                            .font(.body)
                            .padding(6)
                            .background(SpeakerUI.color(for: segment.speakerId))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
            }
        }
    }

}
