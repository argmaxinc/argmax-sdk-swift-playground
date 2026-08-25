import Foundation
import AVFoundation
import Argmax

/// Writes raw PCM audio samples to a WAV file in the temp directory.
///
/// Thread-safe: `append` and `finalize` may be called from any thread.
final class AudioFileWriter {
    let outputURL: URL
    private var audioFile: AVAudioFile?
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "com.argmax.playground.audiofilewriter")

    init(sampleRate: Double = 16000, channels: UInt32 = 1) {
        let fileName = "playground_\(UUID().uuidString).wav"
        self.outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            preconditionFailure("AudioFileWriter: failed to create AVAudioFormat (sampleRate: \(sampleRate), channels: \(channels))")
        }
        self.format = format

        do {
            self.audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            Logging.error("AudioFileWriter: Failed to create file: \(error)")
        }
    }

    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let audioFile = self.audioFile else { return }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: self.format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ) else { return }

            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let channelData = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { src in
                    channelData.update(from: src.baseAddress!, count: samples.count)
                }
            }

            do {
                try audioFile.write(from: buffer)
            } catch {
                Logging.error("AudioFileWriter: Failed to write: \(error)")
            }
        }
    }

    /// Closes the underlying file and returns its URL. Subsequent `append` calls become no-ops.
    func finalize() -> URL {
        queue.sync {
            self.audioFile = nil
        }
        return outputURL
    }

    var duration: TimeInterval {
        queue.sync {
            guard let audioFile else { return 0 }
            return Double(audioFile.length) / audioFile.fileFormat.sampleRate
        }
    }
}
