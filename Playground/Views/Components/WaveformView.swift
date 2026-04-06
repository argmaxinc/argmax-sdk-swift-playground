import SwiftUI

/// High-performance audio waveform visualization using Canvas (single draw call).
/// Replaces the SwiftUI Charts-based VoiceEnergyView for significantly lower CPU usage.
struct WaveformView: View {
    let samples: [Float]
    let silenceThreshold: Float
    /// When true, a TimelineView drives continuous redraws (use during live recording/streaming).
    /// When false, a single static Canvas snapshot is rendered with no timer overhead.
    var isActive: Bool = false

    private let barWidth: CGFloat = 2
    private let gap: CGFloat = 1

    var body: some View {
        if isActive {
            TimelineView(.animation(minimumInterval: 0.2)) { _ in
                waveformCanvas
            }
            .frame(height: 24)
        } else {
            waveformCanvas
                .frame(height: 24)
        }
    }

    private var waveformCanvas: some View {
        Canvas { context, size in
            let step = barWidth + gap
            let maxBars = Int(size.width / step)
            let startIndex = max(0, samples.count - maxBars)
            let visibleCount = min(samples.count, maxBars)

            guard visibleCount > 0 else { return }

            var greenPath = Path()
            var redPath = Path()

            for i in 0..<visibleCount {
                let sample = samples[startIndex + i]
                let clamped = min(max(sample, 0), 1)
                let x = CGFloat(i) * step
                let barHeight = max(CGFloat(clamped) * size.height, 1)
                let rect = CGRect(
                    x: x,
                    y: size.height - barHeight,
                    width: barWidth,
                    height: barHeight
                )
                if clamped > silenceThreshold {
                    greenPath.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
                } else {
                    redPath.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
                }
            }

            context.fill(greenPath, with: .color(.green))
            context.fill(redPath, with: .color(.red))
        }
    }
}

/// Static waveform overview for audio playback (renders entire file waveform).
struct WaveformOverview: View {
    let samples: [Float]
    let currentTime: Double
    let duration: Double

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, duration > 0 else { return }

            let barCount = Int(size.width / 2)
            let samplesPerBar = max(1, samples.count / barCount)

            var path = Path()
            for i in 0..<barCount {
                let start = i * samplesPerBar
                let end = min(start + samplesPerBar, samples.count)
                guard start < end else { continue }
                let maxVal = samples[start..<end].max() ?? 0
                let clamped = min(max(CGFloat(maxVal), 0), 1)
                let barHeight = max(clamped * size.height, 1)
                let rect = CGRect(
                    x: CGFloat(i) * 2,
                    y: size.height - barHeight,
                    width: 1.5,
                    height: barHeight
                )
                path.addRect(rect)
            }
            context.fill(path, with: .color(.secondary.opacity(0.4)))

            // Playhead
            let playheadX = CGFloat(currentTime / duration) * size.width
            let playheadRect = CGRect(x: playheadX - 1, y: 0, width: 2, height: size.height)
            context.fill(Path(playheadRect), with: .color(.accentColor))
        }
        .frame(height: 40)
    }
}

#Preview("WaveformView") {
    let samples: [Float] = (0..<400).map { _ in Float.random(in: 0...1) }
    WaveformView(samples: samples, silenceThreshold: 0.3)
        .padding()
}
