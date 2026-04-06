import SwiftUI
import Argmax

struct StreamDiarizationEntry: Equatable {
    let label: String
    let speakers: Int?
    /// Stored as `Any?` for pre-macOS 15 / iOS 18 compatibility; actual type is `StreamingDiarizationTimings`.
    private let _diarizationTimingsBox: Any?

    @available(macOS 15, iOS 18, *)
    var diarizationTimings: StreamingDiarizationTimings? { _diarizationTimingsBox as? StreamingDiarizationTimings }

    init(label: String, speakers: Int?, diarizationTimings: Any? = nil) {
        self.label = label
        self.speakers = speakers
        self._diarizationTimingsBox = diarizationTimings
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.label == rhs.label, lhs.speakers == rhs.speakers else { return false }
        if #available(macOS 15, iOS 18, *) {
            return lhs.diarizationTimings?.fullPipeline == rhs.diarizationTimings?.fullPipeline
        }
        return true
    }
}

struct PerformanceStripView: View {
    let timings: TranscriptionTimings?
    let diarizationTimings: PyannoteDiarizationTimings?
    /// Stored as `Any?` for pre-macOS 15 / iOS 18 compatibility; actual type is `StreamingDiarizationTimings`.
    private let _streamingDiarizationTimingsBox: Any?
    let diarizationDurationMs: Double?
    let diarizationSpeakerCount: Int?
    let diarizationAudioDuration: Double?
    let tokensPerSecond: Double?
    let realTimeFactor: Double?
    let speedFactor: Double?
    let encodingRuns: Int?
    let decodingLoops: Int?
    let totalPipelineTime: Double?
    let lagFixedWordsCount: Int?
    let streamBreakdown: [StreamDiarizationEntry]?
    let isActive: Bool

    @available(macOS 15, iOS 18, *)
    private var streamingDiarizationTimings: StreamingDiarizationTimings? {
        _streamingDiarizationTimingsBox as? StreamingDiarizationTimings
    }

    @State private var isExpanded = false

    init(
        timings: TranscriptionTimings?,
        diarizationTimings: PyannoteDiarizationTimings? = nil,
        streamingDiarizationTimings: Any? = nil,
        diarizationDurationMs: Double? = nil,
        diarizationSpeakerCount: Int? = nil,
        diarizationAudioDuration: Double? = nil
    ) {
        self.timings = timings
        self.diarizationTimings = diarizationTimings
        self._streamingDiarizationTimingsBox = streamingDiarizationTimings
        self.diarizationDurationMs = diarizationDurationMs
        self.diarizationSpeakerCount = diarizationSpeakerCount
        self.diarizationAudioDuration = diarizationAudioDuration
        self.tokensPerSecond = nil
        self.realTimeFactor = nil
        self.speedFactor = nil
        self.encodingRuns = nil
        self.decodingLoops = nil
        self.totalPipelineTime = nil
        self.lagFixedWordsCount = nil
        self.streamBreakdown = nil
        self.isActive = false
    }

    init(
        tokensPerSecond: Double,
        realTimeFactor: Double? = nil,
        speedFactor: Double? = nil,
        encodingRuns: Int,
        decodingLoops: Int,
        totalPipelineTime: Double = 0,
        diarizationTimings: PyannoteDiarizationTimings? = nil,
        streamingDiarizationTimings: Any? = nil,
        diarizationDurationMs: Double? = nil,
        diarizationSpeakerCount: Int? = nil,
        diarizationAudioDuration: Double? = nil,
        lagFixedWordsCount: Int? = nil,
        streamBreakdown: [StreamDiarizationEntry]? = nil,
        isActive: Bool = false
    ) {
        self.timings = nil
        self.diarizationTimings = diarizationTimings
        self._streamingDiarizationTimingsBox = streamingDiarizationTimings
        self.diarizationDurationMs = diarizationDurationMs
        self.diarizationSpeakerCount = diarizationSpeakerCount
        self.diarizationAudioDuration = diarizationAudioDuration
        self.tokensPerSecond = tokensPerSecond
        self.realTimeFactor = realTimeFactor
        self.speedFactor = speedFactor
        self.encodingRuns = encodingRuns
        self.decodingLoops = decodingLoops
        self.totalPipelineTime = totalPipelineTime > 0 ? totalPipelineTime : nil
        self.lagFixedWordsCount = lagFixedWordsCount
        self.streamBreakdown = streamBreakdown
        self.isActive = isActive
    }

    private var effectiveTPS: Double { timings?.tokensPerSecond ?? tokensPerSecond ?? 0 }
    private var effectiveSpeed: Double { timings?.speedFactor ?? speedFactor ?? 0 }
    private var effectiveEncodingRuns: Int { timings.map { Int($0.totalEncodingRuns) } ?? encodingRuns ?? 0 }
    private var effectiveDecodingLoops: Int { timings.map { Int($0.totalDecodingLoops) } ?? decodingLoops ?? 0 }
    private var effectivePipelineTime: Double? { timings?.fullPipeline ?? totalPipelineTime }

    private var hasTranscriptionData: Bool { effectiveTPS > 0 }
    private var hasDiarizationData: Bool {
        if diarizationTimings != nil { return true }
        if #available(macOS 15, iOS 18, *), (streamingDiarizationTimings?.fullPipeline ?? 0) > 0 { return true }
        if (diarizationDurationMs ?? 0) > 0 { return true }
        if (diarizationSpeakerCount ?? 0) > 0 { return true }
        if (lagFixedWordsCount ?? 0) > 0 { return true }
        return streamBreakdown != nil
    }
    private var hasData: Bool { hasTranscriptionData || hasDiarizationData || isActive }

    private var effectiveSpeakerCount: Int? {
        if let count = diarizationTimings?.numberOfSpeakers { return count }
        if #available(macOS 15, iOS 18, *), let count = streamingDiarizationTimings?.numberOfSpeakers { return count }
        return diarizationSpeakerCount
    }

    private var effectiveAudioDuration: Double? {
        if let d = diarizationTimings, d.inputAudioSeconds > 0 { return d.inputAudioSeconds }
        if #available(macOS 15, iOS 18, *), let sd = streamingDiarizationTimings, sd.inputAudioSeconds > 0 { return sd.inputAudioSeconds }
        return diarizationAudioDuration
    }

    private var diarizationSpeedFactor: Double? {
        if let d = diarizationTimings, d.inputAudioSeconds > 0, d.fullPipeline > 0 {
            return d.inputAudioSeconds / (d.fullPipeline / 1000.0)
        }
        if #available(macOS 15, iOS 18, *), let sd = streamingDiarizationTimings, sd.inputAudioSeconds > 0, sd.fullPipeline > 0 {
            return sd.inputAudioSeconds / (sd.fullPipeline / 1000.0)
        }
        if let dur = diarizationDurationMs, dur > 0, let audio = effectiveAudioDuration, audio > 0 {
            return audio / (dur / 1000.0)
        }
        return nil
    }

    var body: some View {
        if hasData {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    collapsedRow
                }
                .buttonStyle(.plain)

                if isExpanded {
                    expandedContent
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .glassBackground(cornerRadius: 6)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Collapsed

    private var collapsedRow: some View {
        #if os(macOS)
        collapsedRowFull
        #else
        collapsedRowCompact
        #endif
    }

    private var collapsedRowFull: some View {
        HStack(spacing: 8) {
            if hasTranscriptionData {
                metric(String(format: "%.0f", effectiveTPS), caption: "tok/s")
                if effectiveSpeed > 0 {
                    metric(String(format: "%.1fx", effectiveSpeed), caption: "speed")
                }
                if let effectivePipelineTime {
                    metric(String(format: "%.2fs", effectivePipelineTime), caption: "total")
                }
            } else if isActive && !hasDiarizationData {
                Text("—").foregroundColor(.secondary)
                Text("tok/s").foregroundColor(.secondary)
            }
            if hasDiarizationData {
                if hasTranscriptionData {
                    Text("|").foregroundColor(.secondary.opacity(0.4))
                }
                if let diarizationTimings {
                    metric(String(format: "%.2fs", diarizationTimings.fullPipeline / 1000.0), caption: "diarize")
                } else if #available(macOS 15, iOS 18, *), let sd = streamingDiarizationTimings, sd.fullPipeline > 0 {
                    metric(String(format: "%.0fms", sd.fullPipeline), caption: "diarize")
                } else if let diarizationDurationMs, diarizationDurationMs > 0 {
                    metric(String(format: "%.2fs", diarizationDurationMs / 1000.0), caption: "diarize")
                }
                streamCollapsedSpeakers
                if let diarizationSpeedFactor, diarizationSpeedFactor > 0 {
                    metric(String(format: "%.1fx", diarizationSpeedFactor), caption: "speed")
                }
            }
            chevron(isExpanded)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(height: 22)
    }

    private var collapsedRowCompact: some View {
        HStack(spacing: 6) {
            if hasTranscriptionData {
                if effectiveSpeed > 0 {
                    metric(String(format: "%.1fx", effectiveSpeed), caption: "speed")
                }
                if let effectivePipelineTime {
                    metric(String(format: "%.2fs", effectivePipelineTime), caption: "total")
                }
            } else if isActive && !hasDiarizationData {
                Text("—").foregroundColor(.secondary)
                Text("tok/s").foregroundColor(.secondary)
            }
            if hasDiarizationData {
                if hasTranscriptionData {
                    Text("|").foregroundColor(.secondary.opacity(0.4))
                }
                streamCollapsedSpeakers
                if let diarizationSpeedFactor, diarizationSpeedFactor > 0 {
                    metric(String(format: "%.1fx", diarizationSpeedFactor), caption: "speed")
                }
            }
            Spacer(minLength: 0)
            chevron(isExpanded)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(height: 22)
    }

    // MARK: - Expanded

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .center, spacing: 3) {
            if hasTranscriptionData {
                sectionLabel("Transcription")
                if let t = timings {
                    pipelineBreakdown(t)
                }
                HStack(spacing: 16) {
                    if let t = timings {
                        badge("1st Token", value: String(format: "%.2fs", t.firstTokenTime - t.pipelineStart))
                        Divider().frame(height: 24)
                    }
                    badge("Enc Runs", value: "\(effectiveEncodingRuns)")
                    badge("Dec Loops", value: "\(effectiveDecodingLoops)")
                    if effectiveSpeed > 0 {
                        Divider().frame(height: 24)
                        badge("Speed", value: String(format: "%.1fx", effectiveSpeed))
                    }
                }
                .padding(.top, 6)
            }

            if hasDiarizationData {
                if hasTranscriptionData {
                    Divider().padding(.vertical, 2)
                }
                sectionLabel("Diarization Timings")

                if let d = diarizationTimings {
                    diarizationBreakdown(d)
                } else if #available(macOS 15, iOS 18, *), let sd = streamingDiarizationTimings, sd.fullPipeline > 0 {
                    streamingDiarizationBreakdown(sd)
                } else if let dur = diarizationDurationMs, dur > 0 {
                    diarizationFallbackBreakdown(dur)
                } else if let streams = streamBreakdown, !streams.isEmpty {
                    if #available(macOS 15, iOS 18, *) {
                        streamBreakdownGrid(streams)
                    }
                } else {
                    HStack(spacing: 8) {
                        if let spk = effectiveSpeakerCount, spk > 0 { badge("Speakers", value: "\(spk)") }
                        if let lag = lagFixedWordsCount, lag > 0 { badge("Lagged Words Fixed", value: "\(lag)") }
                    }
                    .padding(.top, 3)
                }
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - Breakdowns

    @ViewBuilder
    private func pipelineBreakdown(_ t: TranscriptionTimings) -> some View {
        timingRow("Audio Proc", ms: t.audioProcessing * 1000)
        timingRow("Encoding", ms: t.encoding * 1000)
        timingRow("Decoding", ms: t.decodingLoop * 1000)
        timingRow("Pipeline", ms: t.fullPipeline * 1000)
    }

    @ViewBuilder
    private func diarizationBreakdown(_ d: PyannoteDiarizationTimings) -> some View {
        if d.modelLoading > 0 { timingRow("Loading", ms: d.modelLoading) }
        if d.segmenterTime > 0 { timingRow("Segmenter", ms: d.segmenterTime) }
        if d.embedderTime > 0 { timingRow("Embedder", ms: d.embedderTime) }
        if d.clusteringTime > 0 { timingRow("Clustering", ms: d.clusteringTime) }
        timingRow("Total Runtime", ms: d.fullPipeline)

        diarizationBadges(
            speakers: d.numberOfSpeakers,
            chunks: d.numberOfChunks,
            embeddings: d.numberOfEmbeddings > 0 ? d.numberOfEmbeddings : nil,
            segmenterWorkers: d.numberOfSegmenterWorkers > 0 ? d.numberOfSegmenterWorkers : nil,
            embedderWorkers: d.numberOfEmbedderWorkers > 0 ? d.numberOfEmbedderWorkers : nil,
            audioDuration: d.inputAudioSeconds > 0 ? d.inputAudioSeconds : nil,
            avgPerChunk: d.numberOfChunks > 0 ? d.fullPipeline / Double(d.numberOfChunks) : nil,
            speedFactor: d.inputAudioSeconds > 0 && d.fullPipeline > 0 ? d.inputAudioSeconds / (d.fullPipeline / 1000.0) : nil
        )
    }

    @available(macOS 15, iOS 18, *)
    @ViewBuilder
    private func streamingDiarizationBreakdown(_ sd: StreamingDiarizationTimings) -> some View {
        if sd.modelLoading > 0 { timingRow("Loading", ms: sd.modelLoading) }
        timingRow("Mel Spec", ms: sd.melSpectrogramTime)
        timingRow("Pre-Enc", ms: sd.preEncoderTime)
        timingRow("Encoder", ms: sd.fullEncoderTime)
        timingRow("Total Inference", ms: sd.totalInferenceTime)
        timingRow("Total Runtime", ms: sd.fullPipeline)

        diarizationBadges(
            speakers: sd.numberOfSpeakers,
            chunks: sd.numberOfChunks,
            embeddings: nil,
            segmenterWorkers: nil,
            embedderWorkers: nil,
            audioDuration: sd.inputAudioSeconds > 0 ? sd.inputAudioSeconds : nil,
            avgPerChunk: sd.numberOfChunks > 0 ? sd.totalInferenceTime / Double(sd.numberOfChunks) : nil,
            speedFactor: sd.inputAudioSeconds > 0 && sd.fullPipeline > 0 ? sd.inputAudioSeconds / (sd.fullPipeline / 1000.0) : nil
        )

    }

    @ViewBuilder
    private func diarizationFallbackBreakdown(_ durationMs: Double) -> some View {
        timingRow("Total Runtime", ms: durationMs)

        diarizationBadges(
            speakers: effectiveSpeakerCount ?? 0,
            chunks: nil,
            embeddings: nil,
            segmenterWorkers: nil,
            embedderWorkers: nil,
            audioDuration: effectiveAudioDuration,
            avgPerChunk: nil,
            speedFactor: (effectiveAudioDuration ?? 0) > 0 && durationMs > 0 ? (effectiveAudioDuration! / (durationMs / 1000.0)) : nil
        )
    }

    @ViewBuilder
    private func diarizationBadges(speakers: Int, chunks: Int?, embeddings: Int?, segmenterWorkers: Int?, embedderWorkers: Int?, audioDuration: Double?, avgPerChunk: Double?, speedFactor: Double?) -> some View {
        HStack(spacing: 8) {
            if speakers > 0 { badge("Speakers", value: "\(speakers)") }
            if let speedFactor, speedFactor > 0 { badge("Speed", value: String(format: "%.1fx", speedFactor)) }
            if let chunks, chunks > 0 { badge("Chunks", value: "\(chunks)") }
            if let embeddings { badge("Embeddings", value: "\(embeddings)") }
            if let segmenterWorkers { badge("Seg Workers", value: "\(segmenterWorkers)") }
            if let embedderWorkers { badge("Emb Workers", value: "\(embedderWorkers)") }
            if let avgPerChunk, avgPerChunk > 0 { badge("Avg/Chunk", value: String(format: "%.1fms", avgPerChunk)) }
            if let audioDuration, audioDuration > 0 { badge("Audio", value: String(format: "%.1fs", audioDuration)) }
        }
        .padding(.top, 3)
    }

    @ViewBuilder
    private var streamCollapsedSpeakers: some View {
        if let streams = streamBreakdown {
            if streams.isEmpty {
                Text("—").foregroundColor(.secondary)
                Text("spk detected").foregroundColor(.secondary)
            } else if streams.count > 1 {
                ForEach(streams.indices, id: \.self) { i in
                    if i > 0 { Text("|").foregroundColor(.secondary.opacity(0.4)) }
                    HStack(spacing: 2) {
                        Text("\(streams[i].label):").foregroundColor(.secondary)
                        Text("\(streams[i].speakers ?? 0)").bold()
                        Text("spk detected").foregroundColor(.secondary)
                    }
                }
            } else {
                metric("\(streams[0].speakers ?? 0)", caption: "spk detected")
            }
        } else if let spk = effectiveSpeakerCount, spk > 0 {
            metric("\(spk)", caption: "spk")
        }
    }

    @available(macOS 15, iOS 18, *)
    @ViewBuilder
    private func streamBreakdownGrid(_ streams: [StreamDiarizationEntry]) -> some View {
        let streamsWithTimings = streams.filter { $0.diarizationTimings != nil }
        if !streamsWithTimings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(streamsWithTimings.indices, id: \.self) { i in
                    let entry = streamsWithTimings[i]
                    let sd = entry.diarizationTimings!
                    if streamsWithTimings.count > 1 {
                        if i > 0 { Spacer().frame(height: 4) }
                        sectionLabel(entry.label)
                    }
                    if sd.modelLoading > 0 { timingRow("Loading", ms: sd.modelLoading) }
                    timingRow("Mel Spec", ms: sd.melSpectrogramTime)
                    timingRow("Pre-Enc", ms: sd.preEncoderTime)
                    timingRow("Encoder", ms: sd.fullEncoderTime)
                    timingRow("Total Inference", ms: sd.totalInferenceTime)
                    timingRow("Total Runtime", ms: sd.fullPipeline)
                }
            }
            .padding(.top, 3)
        }
    }

    // MARK: - Helpers

    private func timingRow(_ label: String, ms: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 95, alignment: .leading)
            Text(String(format: "%.1f ms", ms))
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(.caption2, design: .monospaced))
    }

    private func metric(_ value: String, caption: String) -> some View {
        HStack(spacing: 2) {
            Text(value).bold()
            Text(caption).foregroundColor(.secondary)
        }
    }

    private func badge(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .bold()
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary)
    }

    private func chevron(_ expanded: Bool) -> some View {
        Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}

extension PerformanceStripView: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard
            lhs.tokensPerSecond == rhs.tokensPerSecond &&
            lhs.realTimeFactor == rhs.realTimeFactor &&
            lhs.speedFactor == rhs.speedFactor &&
            lhs.encodingRuns == rhs.encodingRuns &&
            lhs.decodingLoops == rhs.decodingLoops &&
            lhs.totalPipelineTime == rhs.totalPipelineTime &&
            lhs.lagFixedWordsCount == rhs.lagFixedWordsCount &&
            lhs.isActive == rhs.isActive &&
            lhs.timings?.tokensPerSecond == rhs.timings?.tokensPerSecond &&
            lhs.timings?.fullPipeline == rhs.timings?.fullPipeline &&
            lhs.diarizationSpeakerCount == rhs.diarizationSpeakerCount &&
            lhs.diarizationDurationMs == rhs.diarizationDurationMs &&
            lhs.diarizationAudioDuration == rhs.diarizationAudioDuration &&
            lhs.diarizationTimings?.fullPipeline == rhs.diarizationTimings?.fullPipeline &&
            lhs.streamBreakdown == rhs.streamBreakdown
        else { return false }
        if #available(macOS 15, iOS 18, *) {
            return lhs.streamingDiarizationTimings?.fullPipeline == rhs.streamingDiarizationTimings?.fullPipeline
        }
        return true
    }
}
