import SwiftUI
import AVFoundation
import Argmax

/// Observable audio player that wraps AVAudioPlayer for playback control.
class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        stop()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            currentTime = 0
        } catch {
            Logging.error("AudioPlayer: Failed to load \(url): \(error)")
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player?.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            Task { @MainActor in
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        stopTimer()
    }
}

struct AudioPlaybackView: View {
    let audioURL: URL
    let segments: [TranscriptionSegment]
    let onSegmentTap: ((TranscriptionSegment) -> Void)?

    @ObservedObject private var player: AudioPlayer

    init(audioURL: URL, segments: [TranscriptionSegment], player: AudioPlayer, onSegmentTap: ((TranscriptionSegment) -> Void)? = nil) {
        self.audioURL = audioURL
        self.segments = segments
        self.onSegmentTap = onSegmentTap
        self.player = player
    }

    var body: some View {
        VStack(spacing: 8) {
            WaveformOverview(
                samples: [],
                currentTime: player.currentTime,
                duration: max(player.duration, 0.01)
            )
            .overlay(
                GeometryReader { geo in
                    Color.clear.gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard player.duration > 0, geo.size.width > 0 else { return }
                                let fraction = max(0, min(1, value.location.x / geo.size.width))
                                player.seek(to: Double(fraction) * player.duration)
                            }
                    )
                }
            )

            HStack(spacing: 24) {
                Button {
                    player.seek(to: max(0, player.currentTime - 5))
                } label: {
                    Image(systemName: "gobackward.5")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .frame(width: 36, height: 36)

                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.borderless)
                .frame(width: 36, height: 36)

                Button {
                    player.seek(to: min(player.duration, player.currentTime + 5))
                } label: {
                    Image(systemName: "goforward.5")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .frame(width: 36, height: 36)

                Spacer()

                Text(formatTime(player.currentTime) + " / " + formatTime(player.duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .onAppear {
            player.load(url: audioURL)
        }
    }

    /// Returns the segment currently being played (for highlight sync)
    var activeSegment: TranscriptionSegment? {
        let time = Float(player.currentTime)
        return segments.first { $0.start <= time && $0.end >= time }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

/// Seek the audio player to a segment's start time when tapped in transcript view.
struct SegmentTapModifier: ViewModifier {
    let segment: TranscriptionSegment
    let player: AudioPlayer

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                player.seek(to: TimeInterval(segment.start))
                if !player.isPlaying {
                    player.play()
                }
            }
    }
}
