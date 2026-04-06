//  Based on Apple's sample code from "Capturing System Audio with Core Audio Taps"
//  Source: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
//
//  Copyright © 2024 Apple Inc.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#if os(macOS)
import Foundation
import CoreAudio
import Argmax

/// An `ObservableObject` for discovering and managing audio-producing processes on macOS.
///
/// `AudioProcessDiscoverer` enables applications to discover running processes that produce sound
/// and create process taps for audio capture. This functionality is essential for system-wide
/// audio transcription and monitoring applications.
///
/// ## Core Responsibilities
///
/// - **Process Discovery:** Continuously discovers active audio-producing processes using Core Audio APIs
/// - **Process Tapping:** Creates and manages `ProcessTapper` instances for selected processes
/// - **State Management:** Publishes process lists and selection state to SwiftUI views
/// - **Resource Management:** Properly handles lifecycle and cleanup of audio tapping resources
///
/// ## Usage Example
///
/// ```swift
/// @StateObject private var processDiscoverer = AudioProcessDiscoverer()
/// 
/// // Access available processes
/// let processes = processDiscoverer.availableProcessOptions
/// 
/// // Select a process for tapping
/// processDiscoverer.selectedProcessForStream = someAudioProcess
/// 
/// // Access the process tapper
/// if let tapper = processDiscoverer.processTapper {
///     // Use tapper for audio capture
/// }
/// ```
///
/// - Important: This class requires macOS 14.2+ and appropriate audio permissions.
///   Applications must declare `NSAudioCaptureUsageDescription` in their Info.plist.
class AudioProcessDiscoverer: ObservableObject {
    @Published var activeAudioProcessList = [AudioProcess]()
    @Published var selectedProcessForStream: AudioProcess = AudioProcess.noAudio {
        didSet {
            handleSelectedProcessChange()
        }
    }
    // Holds active ProcessTapper (macOS 14.2+). Nil when not capturing.
    var processTapper: ProcessTapper?
    
    // Track ongoing tapper changes to prevent race conditions
    private var isTapperChanging = false
    
    // Refresh state tracking
    private var isRefreshInProgress = false
    
    // Computed property to get all available process options for picker
    var availableProcessOptions: [AudioProcess] {
        return [AudioProcess.noAudio] + activeAudioProcessList
    }
    
    init() {
        refreshProcessList()
    }
    
    deinit {
        // Clean up ProcessTapper on background queue to avoid blocking deinit
        if let tapper = processTapper {
            Task.detached(priority: .background) {
                do {
                    try tapper.stop()
                } catch {
                    Logging.error("Failed to stop ProcessTapper in deinit: \(error)")
                }
            }
        }
    }
    
    
    /// Public method to refresh the process list (called on init and when picker is clicked)
    func refreshProcessList() {
        // Prevent handleSelectedProcessChange during refresh
        isRefreshInProgress = true
        
        // Capture current selection to preserve it
        let currentSelection = selectedProcessForStream
        
        // Create the address value locally—Core Audio APIs require an `inout` parameter, so it
        // must be `var` inside the background block.
        var address = getPropertyAddress(selector: kAudioHardwarePropertyProcessObjectList)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var propertySize: UInt32 = 0
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize)

            let processCount = Int(propertySize) / MemoryLayout<AudioObjectID>.stride
            var idList = [AudioObjectID](repeating: 0, count: processCount)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &idList)

            var newProcessList: [AudioProcess] = []
            newProcessList.reserveCapacity(idList.count)

            for pid in idList {
                let process = AudioProcess(id: pid)
                if process.isRunning {
                    newProcessList.append(process)
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                
                self.activeAudioProcessList = newProcessList
                
                // Restore selection if the process still exists, otherwise keep current selection
                // This prevents unwanted picker resets
                if currentSelection != .noAudio {
                    let stillExists = newProcessList.contains { $0.id == currentSelection.id }
                    if !stillExists {
                        Logging.debug("Selected process \(currentSelection.name) no longer exists, keeping selection")
                    }
                }
                
                self.isRefreshInProgress = false
            }
        }
    }

    // MARK: - Process Tapper Management
    private func handleSelectedProcessChange() {
        // Don't handle selection changes during refresh to prevent conflicts
        guard !isRefreshInProgress else {
            Logging.debug("Process list refresh in progress, deferring selection change")
            return
        }
        
        // Prevent multiple simultaneous tapper changes
        guard !isTapperChanging else {
            Logging.debug("ProcessTapper change already in progress, ignoring")
            return
        }
        
        let selectedProcess = selectedProcessForStream
        let currentTapper = processTapper
        isTapperChanging = true
        
        // Move heavy Core Audio operations to background queue to prevent UI hang
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.isTapperChanging = false
                }
            }
            
            // Clean up any existing tapper on background queue
            if let tapper = currentTapper {
                do {
                    try tapper.stop()
                } catch {
                    Logging.error("Failed to stop ProcessTapper: \(error)")
                }
            }
            
            // Create new tapper if needed
            let newTapper: ProcessTapper?
            if selectedProcess != .noAudio {
                do {
                    newTapper = try ProcessTapper(objectIDs: [selectedProcess.id])
                    Logging.debug("Successfully created ProcessTapper for process: \(selectedProcess.name)")
                } catch {
                    Logging.error("Failed to create ProcessTapper for process \(selectedProcess.name): \(error)")
                    newTapper = nil
                }
            } else {
                newTapper = nil
            }
            
            // Update the processTapper property on main actor
            await MainActor.run { [weak self] in
                self?.processTapper = newTapper
            }
        }
    }
}
#endif
