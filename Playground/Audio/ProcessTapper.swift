import SwiftUI
import WhisperKit
import AudioToolbox
import AVFoundation

/// A macOS utility class that enables tapping into one or more system audio processes to capture their audio output
/// for real-time transcription with WhisperKit.
///
/// `ProcessTapper` provides a bridge between macOS system audio and WhisperKit's transcription engine by capturing 
/// audio from specified processes and converting it to the appropriate format for speech recognition. This class uses 
/// Core Audio APIs to create process taps and aggregate devices for capturing audio from specified process object IDs.
///
/// ProcessTapper is integrated with LiveTranscriber using `StreamSourceType.process` for seamless system audio transcription.
///
/// ## Privacy Requirements
///
/// **Important**: Applications using ProcessTapper must declare the `NSAudioCaptureUsageDescription` key in their
/// `Info.plist` file to request microphone access permissions. This is required because process tapping is
/// considered a form of audio capture by the system.
///
/// Example `Info.plist` entry:
/// ```xml
/// <key>NSAudioCaptureUsageDescription</key>
/// <string>This app needs audio access to transcribe system audio for accessibility features.</string>
/// ```
///
/// ## Usage Example
///
/// ```swift
/// // Create ProcessTapper for specific process IDs
/// let processTapper = try ProcessTapper(objectIDs: [processID1, processID2])
///
/// // Create audio stream for WhisperKit
/// let (audioStream, continuation) = processTapper.startTapStream()
///
/// // Create WhisperKit stream session and start with ProcessTapper audio
/// let streamSession = whisperKit.makeStreamSession(options: options)
/// await streamSession.start(audioInputStream: audioStream)
/// ...
/// // Process transcription results
/// for try await result in streamSession {
///     print("Transcription: \(result.text)")  
/// }
///
/// // Stop transcription when done
/// continuation.finish()
/// ```
#if os(macOS)
@available(macOS 14.2, *)
public final class ProcessTapper {
    public static let processTapperPrefix = "ArgmaxPlayground.ProcessTapper"
    public typealias AudioBufferCallback = ([Float]) -> Void
    
    private let objectIDs: [AudioObjectID]
    
    private var processTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapStreamDescription: AudioStreamBasicDescription?
    private var audioFormat: AVAudioFormat?
    private var isRunning = false
    
    private let desiredFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    
    private var currentCallback: AudioBufferCallback?
    // Accumulates resampled samples until we have a full chunk to match AudioProcessor.minBufferLength
    private var sampleAccumulator: [Float] = []
    private var accumulatorHead: Int = 0
    private let targetChunkSize = 1600 // 100ms at 16kHz, matches AudioProcessor.minBufferLength

    /// Resample a single hardware-rate PCM buffer to the desired format using the converter
    /// in streaming mode. Unlike AudioProcessor.resampleBuffer, the inputBlock signals
    /// `.noDataNow` (not `.endOfStream`) after providing the buffer once, so the converter
    /// preserves its sinc-filter state across successive IO callbacks without injecting
    /// phantom duplicate frames.
    private func resampleChunk(_ pcm: AVAudioPCMBuffer) -> [Float]? {
        guard let conv = converter else { return nil }
        let ratio = desiredFormat.sampleRate / pcm.format.sampleRate
        let outputFrameCount = max(1, AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: outputFrameCount) else {
            return nil
        }
        var didProvide = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if didProvide {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvide = true
            outStatus.pointee = .haveData
            return pcm
        }
        var error: NSError?
        let status = conv.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error else { return nil }
        return AudioProcessor.convertBufferToArray(buffer: outputBuffer)
    }

    private lazy var ioBlock: AudioDeviceIOBlock = { [weak self] _, inBuf, _, _, _ in
        guard let self,
              let fmt  = self.audioFormat,
              let pcm  = AVAudioPCMBuffer(pcmFormat: fmt,
                                          bufferListNoCopy: inBuf,
                                          deallocator: nil)
        else { return }

        let floats: [Float]
        if !fmt.sampleRate.isEqual(to: self.desiredFormat.sampleRate),
           let resampled = self.resampleChunk(pcm) {
            floats = resampled
        } else {
            floats = AudioProcessor.convertBufferToArray(buffer: pcm)
        }

        // Accumulate samples and yield only when we have a full chunk (matches AudioProcessor.minBufferLength)
        self.sampleAccumulator.append(contentsOf: floats)
        while self.sampleAccumulator.count - self.accumulatorHead >= self.targetChunkSize {
            let start = self.accumulatorHead
            let chunk = Array(self.sampleAccumulator[start ..< start + self.targetChunkSize])
            self.accumulatorHead += self.targetChunkSize
            self.currentCallback?(chunk)
        }
        if self.accumulatorHead > 0 {
            self.sampleAccumulator.removeFirst(self.accumulatorHead)
            self.accumulatorHead = 0
        }
    }

    private func createIOProcOnce() throws {
        guard deviceProcID == nil else { return }
        let err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID,
                                                     aggregateDeviceID,
                                                     DispatchQueue.argmaxCoreAudio,
                                                     ioBlock)
        guard err == noErr else { throw ProcessTapperError.operationFailed }
    }
    
    
    public init(objectIDs: [AudioObjectID]) throws {
        self.objectIDs = objectIDs
        guard let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: Double(16000),
                                              channels: AVAudioChannelCount(1),
                                              interleaved: false) else {
            throw ProcessTapperError.setupFailed
        }
        self.desiredFormat = desiredFormat
        try setupProcessTapAndAggregateDevice()
        try createIOProcOnce()
    }
    
    deinit {
        do {
            try stop()
        } catch {
            Logging.error("Failed to stop ProcessTapper during deinitialization: \(error)")
        }
    }
    
    /// Creates and starts an async stream for capturing audio from the tapped processes.
    ///
    /// This method provides a modern async/await interface for audio capture. The stream will automatically
    /// handle the lifecycle of the ProcessTapper, starting capture when the stream is created and stopping
    /// when the stream is terminated or cancelled.
    ///
    /// - Returns: A tuple containing:
    ///   - An `AsyncThrowingStream<[Float], Error>` that yields audio samples as Float arrays
    ///   - A continuation that can be used to manually control the stream
    ///
    /// - Throws: `ProcessTapperError` if the audio capture cannot be started
    ///
    /// - Note: The stream uses unbounded buffering policy. The ProcessTapper will automatically stop
    ///   when the stream is terminated or cancelled.
    ///
    /// ## Usage Example:
    /// ```swift
    /// let (stream, continuation) = try processTapper.startTapStream()
    ///
    /// for try await audioSamples in stream {
    ///     // Process audio samples
    ///     print("Received \(audioSamples.count) samples")
    /// }
    /// ```
    public func startTapStream() -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        var continuation: AsyncThrowingStream<[Float], Error>.Continuation!
        let stream = AsyncThrowingStream<[Float], Error>(bufferingPolicy: .unbounded) { streamContinuation in
            continuation = streamContinuation
            
            // Set up termination handler to automatically stop recording
            streamContinuation.onTermination = { @Sendable _ in
                do {
                    try self.pause()
                } catch {
                    Logging.error("Failed to stop ProcessTapper during stream termination: \(error)")
                }
            }
            
            let legacyCallback: (([Float]) -> Void) = { floats in
                streamContinuation.yield(floats)
            }
            
            do {
                try self.startTap(callback: legacyCallback)
            } catch {
                streamContinuation.finish(throwing: error)
            }
        }
        return (stream, continuation)
    }
    
    /// Starts capturing audio from the tapped processes using a callback-based interface.
    ///
    /// This method begins audio capture from the processes specified during initialization. Audio samples
    /// are delivered asynchronously through the provided callback function. The callback receives Float
    /// arrays containing audio samples at the configured sample rate.
    ///
    /// - Parameter callback: A callback function that receives audio samples as `[Float]` arrays.
    ///   The callback is called on a background queue and should return quickly to avoid blocking
    ///   the audio processing pipeline.
    ///
    /// - Throws:
    ///   - `ProcessTapperError.alreadyRunning` if the ProcessTapper is already capturing audio
    ///   - `ProcessTapperError.operationFailed` if the audio capture cannot be started
    ///   - `ProcessTapperError.audioProcessingFailed` if audio format is not available
    ///
    /// - Note: You must call `stop()` to end the capture session. The ProcessTapper will continue
    ///   capturing until explicitly stopped.
    ///
    /// ## Usage Example:
    /// ```swift
    /// try processTapper.startTap { audioSamples in
    ///     // Process audio samples on background queue
    ///     print("Received \(audioSamples.count) samples")
    /// }
    ///
    /// // Later, stop the capture
    /// try processTapper.stop()
    /// ```
    public func startTap(callback: @escaping AudioBufferCallback) throws {
        
        guard !isRunning else {
            throw ProcessTapperError.alreadyRunning
        }
        self.currentCallback = callback
        try startAudioCapture(callback: callback)
        
        isRunning = true
    }
    
    /// Stops audio capture and cleans up all associated resources.
    ///
    /// This method terminates the active audio capture session and properly releases all Core Audio
    /// resources including the aggregate device, process tap, and I/O procedures. It's safe to call
    /// this method multiple times - subsequent calls will have no effect if already stopped.
    ///
    /// - Throws:
    ///   - `ProcessTapperError.operationFailed` if any of the cleanup operations fail, including:
    ///     - Stopping the aggregate audio device
    ///     - Destroying the I/O procedure
    ///     - Destroying the aggregate device
    ///     - Destroying the process tap
    ///
    /// - Note: This method is automatically called during deinitialization, but it's recommended
    ///   to call it explicitly when you're done capturing audio to ensure proper resource cleanup.
    ///
    /// ## Usage Example:
    /// ```swift
    /// // Start capture
    /// try processTapper.startTap { audioSamples in
    ///     // Process samples...
    /// }
    ///
    /// // Stop capture when done
    /// try processTapper.stop()
    /// ```
    public func stop() throws {
        guard isRunning else { return }
        do {
            try pause()
        } catch {
            Logging.error("Failed to pause ProcessTapper: \(error)")
        }

        // Stop audio device
        if aggregateDeviceID != kAudioObjectUnknown {
            // Destroy IO proc
            if let deviceProcID {
                let err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr {
                    throw ProcessTapperError.operationFailed
                }
                self.deviceProcID = nil
            }
            
            // Destroy aggregate device
            let err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr {
                throw ProcessTapperError.operationFailed
            }
            aggregateDeviceID = kAudioObjectUnknown
        }
        
        // Destroy process tap
        if processTapID != kAudioObjectUnknown {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr {
                throw ProcessTapperError.operationFailed
            }
            processTapID = kAudioObjectUnknown
        }
        
        isRunning = false
    }
    
    private func pause() throws {
        guard isRunning else { return }
        let err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
        if err != noErr {
            throw ProcessTapperError.operationFailed
        }
        converter?.reset()
        sampleAccumulator.removeAll()
        accumulatorHead = 0
        isRunning = false
    }
    
    private func setupProcessTapAndAggregateDevice() throws {
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        
        var tapID: AUAudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        
        guard err == noErr else {
            throw ProcessTapperError.setupFailed
        }
        
        processTapID = tapID
        
        
        let outputUID = try Self.getDefaultSystemOutputDeviceUID()
        let aggregateUID = UUID().uuidString
        
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(Self.processTapperPrefix)-\(objectIDs)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]
        
        tapStreamDescription = try Self.readTapStreamBasicDescription(tapID: tapID)
        
        guard var streamDescription = tapStreamDescription else {
            throw ProcessTapperError.setupFailed
        }
        
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw ProcessTapperError.setupFailed
        }
        
        audioFormat = format

        guard let converter = AVAudioConverter(from: format, to: desiredFormat) else {
            throw ProcessTapperError.setupFailed
        }

        self.converter = converter
        
        aggregateDeviceID = kAudioObjectUnknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw ProcessTapperError.setupFailed
        }
    }
    
    private func startAudioCapture(callback: @escaping AudioBufferCallback) throws {
        let err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            throw ProcessTapperError.operationFailed
        }
    }
    
    // MARK: - Private Static Functions
    
    /// Gets the UID of the default system output device using Core Audio APIs directly
    private static func getDefaultSystemOutputDeviceUID() throws -> String {
        // Get the default system output device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        
        guard err == noErr else {
            throw ProcessTapperError.operationFailed
        }
        
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        
        guard err == noErr else {
            throw ProcessTapperError.operationFailed
        }
        
        guard deviceID != kAudioObjectUnknown else {
            throw ProcessTapperError.operationFailed
        }
        
        // Get the device UID
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        err = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        
        guard err == noErr else {
            throw ProcessTapperError.operationFailed
        }
        
        var deviceUID: String = ""
        
        err = withUnsafeMutablePointer(to: &deviceUID) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        
        guard err == noErr else {
            throw ProcessTapperError.operationFailed
        }
        
        return deviceUID as String
    }
    
    /// Reads the AudioStreamBasicDescription for a tap using Core Audio APIs directly
    private static func readTapStreamBasicDescription(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(tapID, &address, 0, nil, &dataSize)
        
        guard err == noErr else {
            throw ProcessTapperError.operationFailed
        }
        
        var streamDescription = AudioStreamBasicDescription()
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &streamDescription)
        
        guard err == noErr else {
            throw ProcessTapperError.operationFailed
        }
        
        return streamDescription
    }
}

public enum ProcessTapperError: Error {
    case alreadyRunning
    case setupFailed
    case operationFailed
    case audioProcessingFailed
}

extension ProcessTapperError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "ProcessTapper is already running"
        case .setupFailed:
            return "Failed to setup ProcessTapper"
        case .operationFailed:
            return "ProcessTapper operation failed"
        case .audioProcessingFailed:
            return "Audio processing failed"
        }
    }
}
#endif
