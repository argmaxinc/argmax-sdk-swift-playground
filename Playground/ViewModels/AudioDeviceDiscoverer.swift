import Foundation
import Argmax
import SwiftUI

/// An `ObservableObject` responsible for discovering and managing available hardware audio input devices.
///
/// `AudioDeviceDiscoverer` acts as a single source of truth for the list of audio devices that users can 
/// select for recording, such as built-in microphones, external USB microphones, or other audio interfaces.
/// This class is specifically designed for macOS platforms where multiple audio input devices are common.
///
/// ## Core Responsibilities
///
/// - **Device Discovery:** Uses `AudioProcessor.getAudioDevices()` to fetch the current list of available input devices from Core Audio
/// - **State Publishing:** Publishes the device list via `@Published` properties, enabling SwiftUI views to dynamically display them in pickers
/// - **Selection Management:** Manages the currently selected audio input device and provides device ID resolution
/// - **Filtering:** Automatically filters out temporary ProcessTapper devices from the available device list
///
/// ## Usage Example
///
/// ```swift
/// @StateObject private var deviceDiscoverer = AudioDeviceDiscoverer()
/// 
/// // Access available devices
/// let devices = deviceDiscoverer.audioDevices
/// 
/// // Get selected device ID for Core Audio
/// if let deviceID = deviceDiscoverer.selectedDiviceID {
///     // Use deviceID for audio recording
/// }
/// ```
class AudioDeviceDiscoverer: ObservableObject {
    #if os(macOS)
    static let noAudioDevice = AudioDevice(id: 0, name: "No Audio")
    @Published var audioDevices: [AudioDevice] = []
    @AppStorage("selectedAudioInput") private var storedSelectedAudioInput: String = ""
    @Published var selectedAudioInput: String = "" {
        didSet {
            storedSelectedAudioInput = selectedAudioInput
        }
    }
    #endif
    
    var selectedDiviceID: DeviceID? {
        #if os(macOS)
        if selectedAudioInput == Self.noAudioDevice.name {
            return nil
        } else if let device = audioDevices.first(where: { $0.name == selectedAudioInput }){
            return device.id
        } else {
            return nil
        }
        #else
        return nil
        #endif
    }

    init() {
        refreshDevices(selectFirst: true)
    }

    func refreshDevices(selectFirst: Bool) {
        #if os(macOS)
        let allDevices = AudioProcessor.getAudioDevices()
        // Filter out ProcessTapper devices, these are created temporarily for process tapping
        let filteredDevices = allDevices.filter { device in
            !device.name.hasPrefix(ProcessTapper.processTapperPrefix)
        }
        audioDevices = filteredDevices + [AudioDeviceDiscoverer.noAudioDevice]
        
        if selectFirst, !audioDevices.isEmpty {
            // First, try to restore the previously stored selection if it exists in current devices
            if !storedSelectedAudioInput.isEmpty,
               audioDevices.contains(where: { $0.name == storedSelectedAudioInput }) {
                selectedAudioInput = storedSelectedAudioInput
            } else if let device = audioDevices.first {
                // Fallback to first device if stored selection is not available
                selectedAudioInput = device.name
            }
        }
        #endif
    }
}
