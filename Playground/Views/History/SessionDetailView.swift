import SwiftUI
import Argmax
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

struct SessionDetailView: View {
    let record: SessionRecord
    let allSessions: [SessionRecord]
    let onBack: () -> Void

    @State private var showExportSheet = false
    @State private var viewMode: TabMode = .transcription
    @State private var showComparePicker = false
    @State private var compareTarget: SessionRecord?
    @StateObject private var audioPlayer = AudioPlayer()

    private var hasSpeakerData: Bool {
        record.hasSpeakerData
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack {
                    Button { onBack() } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    if let audioURL = record.audioFileURL {
                        #if os(macOS)
                        Button { saveAudioWithPanel() } label: {
                            Label("Save Audio", systemImage: "arrow.down.doc.fill")
                        }
                        .buttonStyle(.borderless)
                        #else
                        ShareLink(item: audioURL) {
                            Label("Save Audio", systemImage: "arrow.down.doc.fill")
                        }
                        .buttonStyle(.borderless)
                        #endif
                    }

                    #if os(macOS)
                    if allSessions.count >= 2 {
                        if compareTarget != nil {
                            Button {
                                withAnimation { compareTarget = nil }
                            } label: {
                                Label("Close Compare", systemImage: "xmark.rectangle")
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Button { showComparePicker = true } label: {
                                Label("Compare", systemImage: "rectangle.split.2x1")
                            }
                            .buttonStyle(.borderless)
                            .popover(isPresented: $showComparePicker) {
                                compareSessionPicker
                            }
                        }
                    }
                    #endif

                    Button { showExportSheet = true } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }

                Text(record.displayTitle)
                    .font(.headline)
                Text(record.settings.diffDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

            Divider()

            // Audio playback if available
            if let audioURL = record.audioFileURL {
                AudioPlaybackView(audioURL: audioURL, segments: record.segments, player: audioPlayer)
                    .padding(.horizontal)
                    .padding(.top, 8)
                Divider()
            }

            // Timing summary
            timingSummarySection

            if let target = compareTarget {
                // Inline side-by-side compare
                SessionCompareView(left: record, right: target) {
                    withAnimation { compareTarget = nil }
                }
            } else {
                // Normal detail view
                sessionTranscriptView
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(
                isPresented: $showExportSheet,
                segments: record.segments,
                speakerSegments: record.speakerSegments
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
    }

    @ViewBuilder
    private var sessionTranscriptView: some View {
        if hasSpeakerData {
            Picker("View", selection: $viewMode) {
                Text("Transcription").tag(TabMode.transcription)
                Text("Speakers").tag(TabMode.diarize)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if viewMode == .diarize {
                    let displaySegments = record.displaySpeakerSegments
                    ForEach(Array(displaySegments.enumerated()), id: \.element.id) { index, segment in
                        Button {
                            seekAndPlay(to: TimeInterval(segment.startTime))
                        } label: {
                            DiarizedSegmentLabel(
                                segment: segment,
                                showHeader: index == 0 || displaySegments[index - 1].speakerId != segment.speakerId,
                                isActive: isSegmentActive(start: segment.startTime, end: segment.endTime)
                            )
                            .equatable()
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                } else {
                    ForEach(Array(record.segments.enumerated()), id: \.offset) { _, segment in
                        Button {
                            seekAndPlay(to: TimeInterval(segment.start))
                        } label: {
                            TranscriptionSegmentLabel(
                                segment: segment,
                                isActive: isSegmentActive(start: segment.start, end: segment.end)
                            )
                            .equatable()
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .textSelection(.enabled)
    }

    private func seekAndPlay(to time: TimeInterval) {
        audioPlayer.seek(to: time)
        if !audioPlayer.isPlaying {
            audioPlayer.play()
        }
    }

    private func isSegmentActive(start: Float, end: Float) -> Bool {
        guard audioPlayer.isPlaying || audioPlayer.currentTime > 0 else { return false }
        let t = Float(audioPlayer.currentTime)
        return t >= start && t < end
    }

    @ViewBuilder
    private var timingSummarySection: some View {
        if record.mode != .stream,
           record.transcriptionTimings != nil || record.diarizationTimings != nil || (record.diarizationDurationMs ?? 0) > 0 {
            PerformanceStripView(
                timings: record.transcriptionTimings,
                diarizationTimings: record.diarizationTimings,
                diarizationDurationMs: record.diarizationDurationMs
            )
            .padding(.vertical, 4)
            Divider()
        }
    }

    #if os(macOS)
    private func saveAudioWithPanel() {
        guard let sourceURL = record.audioFileURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.wav]
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        }
    }
    #endif

    private var compareSessionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare with...")
                .font(.headline)
                .padding(.bottom, 4)
            List(allSessions.filter { $0.id != record.id }) { other in
                Button {
                    showComparePicker = false
                    withAnimation { compareTarget = other }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(other.displayTitle)
                            .font(.body)
                        Text(other.settings.diffDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .padding()
        .frame(width: 380, height: 300)
    }

}

// MARK: - Equatable label views

private struct DiarizedSegmentLabel: View, Equatable {
    let segment: DisplaySpeakerSegment
    let showHeader: Bool
    let isActive: Bool

    // DisplaySpeakerSegment doesn't conform to Equatable — compare content fields directly
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isActive == rhs.isActive &&
        lhs.showHeader == rhs.showHeader &&
        lhs.segment.speakerId == rhs.segment.speakerId &&
        lhs.segment.text == rhs.segment.text &&
        lhs.segment.startTime == rhs.segment.startTime &&
        lhs.segment.endTime == rhs.segment.endTime
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if showHeader {
                    Text(SpeakerUI.label(for: segment.speakerId))
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("[\(String(format: "%.2f", segment.startTime)) -> \(String(format: "%.2f", segment.endTime))]")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(segment.text)
                    .font(.body)
                    .padding(8)
                    .background(isActive
                                 ? SpeakerUI.color(for: segment.speakerId).opacity(0.85)
                                 : SpeakerUI.color(for: segment.speakerId))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundColor(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isActive ? Color.white : Color.clear, lineWidth: 2)
                    )
            }
            Spacer()
        }
    }
}

private struct TranscriptionSegmentLabel: View, Equatable {
    let segment: TranscriptionSegment
    let isActive: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isActive == rhs.isActive && lhs.segment == rhs.segment
    }

    var body: some View {
        HStack {
            Text("[\(String(format: "%.2f", segment.start)) -> \(String(format: "%.2f", segment.end))]")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(segment.text)
                .font(.body)
                .foregroundColor(isActive ? .accentColor : .primary)
        }
    }
}
