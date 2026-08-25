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
import CoreAudio
import Foundation
import AppKit

/// A model to represent a process that produces sound on macOS.
///
/// `AudioProcess` encapsulates information about a system audio process, including its process ID,
/// bundle identifier, name, and running state. It provides functionality to monitor and interact
/// with audio-producing processes on macOS systems.
///
/// Includes a `noAudio` sentinel for "no source selected" in audio-source pickers.
///
/// ## Usage Example
///
/// ```swift
/// // Create an AudioProcess for a specific process ID
/// let audioProcess = AudioProcess(id: processID)
/// print("Process: \(audioProcess.name), Running: \(audioProcess.isRunning)")
///
/// // Sentinel for "no source selected"
/// let noAudio = AudioProcess.noAudio
/// ```
@available(macOS 14.2, *)
final class AudioProcess: Identifiable, Hashable, ObservableObject {
    var id: AudioObjectID
    var pid: Int32 = 0
    var name: String = ""
    var bundleID: String = ""
    /// Only running process is producing audio
    /// Note: when an audio is paused from a process, it will stop running after a short delay
    var isRunning = false

    /// Sentinel "no audio source selected" instance. Carries a special ID outside the real
    /// `AudioObjectID` range so equality with real processes is impossible by construction.
    /// Skips the CoreAudio property fetch that `init(id:)` performs, since the sentinel ID
    /// doesn't correspond to a CoreAudio object.
    static let noAudio: AudioProcess = {
        let process = AudioProcess(
            sentinelId: AudioObjectID(UInt32.max - 1),
            pid: -2,
            name: "No Audio",
            bundleID: "no.audio"
        )
        return process
    }()

    /// Direct-field initializer for sentinel instances that don't correspond to a real
    /// CoreAudio process. Internal because callers should use the named static instances.
    private init(sentinelId: AudioObjectID, pid: Int32, name: String, bundleID: String) {
        self.id = sentinelId
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.isRunning = true
    }

    /// - Parameter localizedAppNames: Optional pre-captured map of `pid -> NSRunningApplication.localizedName`,
    ///   used to resolve process display names without touching `NSWorkspace` from a background
    ///   thread (`NSWorkspace` is not documented as thread-safe). When `nil` or missing, falls
    ///   back to `sysctl`-based naming. Callers on a background queue MUST capture this map on
    ///   the main thread first; see `AudioProcessDiscoverer.refreshProcessList`.
    init(id: AudioObjectID, localizedAppNames: [Int32: String]? = nil) {
        self.id = id

        // Get the bundle ID of the audio process.
        var propertyAddress = getPropertyAddress(selector: kAudioProcessPropertyBundleID)
        var propertySize = UInt32(MemoryLayout<CFString>.stride)
        var bundleID: CFString = "" as CFString
        _ = withUnsafeMutablePointer(to: &bundleID) { bundleID in
            AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &propertySize, bundleID)
        }
        self.bundleID = bundleID as String

        // Get the PID of the audio process.
        propertyAddress = getPropertyAddress(selector: kAudioProcessPropertyPID)
        propertySize = UInt32(MemoryLayout<Int32>.stride)
        var processPID: Int32 = 0
        AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &propertySize, &processPID)
        self.pid = processPID

        self.name = Self.resolveName(pid: self.pid, localizedAppNames: localizedAppNames)
        self.updateIsRunning()
    }
    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        return lhs.id == rhs.id
    }

    /// Hashes by `id` so the Hashable contract holds with the `==` implementation above
    /// (`a == b => a.hashValue == b.hashValue`). Two instances with the same `AudioObjectID`
    /// represent the same audio source and produce the same hash, keeping
    /// `Set<AudioProcess>` and `[AudioProcess: T]` lookups correct.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    
    func updateIsRunning() {
        // Get the `isRunning` property of the process object.
        var propertySize = UInt32(MemoryLayout<UInt32>.stride)
        var running: UInt32 = 0
        var isRunningAddress = getPropertyAddress(selector: kAudioProcessPropertyIsRunning)
        AudioObjectGetPropertyData(self.id, &isRunningAddress, 0, nil, &propertySize, &running)
        self.isRunning = running != 0
    }
    
    /// Resolves a process display name from a pre-captured `NSWorkspace` map (cheap, requires
    /// caller to have called `Self.snapshotLocalizedAppNames()` on the main thread), falling
    /// back to `sysctl` (thread-safe) when the pid isn't in the map.
    private static func resolveName(pid: Int32, localizedAppNames: [Int32: String]?) -> String {
        if let name = localizedAppNames?[pid] { return name }

        // sysctl-based fallback. Safe to call off-main.
        var result: String = ""
        var info = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if (sysctl(&mib, 4, &info, &len, nil, 0) != -1) && len > 0 {
            withUnsafePointer(to: info.kp_proc.p_comm) {
                $0.withMemoryRebound(to: UInt8.self, capacity: len) {
                    result = String(cString: $0)
                }
            }
        }
        return result
    }

    /// Snapshots `NSWorkspace.runningApplications` into a `[pid: localizedName]` map. The
    /// `@MainActor` annotation enforces that callers capture the snapshot on the main thread
    /// (`NSWorkspace` is not documented as thread-safe) before handing it to
    /// `init(id:localizedAppNames:)` on a background queue.
    @MainActor
    static func snapshotLocalizedAppNames() -> [Int32: String] {
        var result: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName {
                result[app.processIdentifier] = name
            }
        }
        return result
    }
}

#endif
