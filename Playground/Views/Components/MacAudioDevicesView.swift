import Foundation
import SwiftUI
import Argmax

/// A SwiftUI view for macOS that provides UI for selecting audio input sources for transcription.
/// This view presents controls for two distinct types of audio streams, which can be used independently or concurrently.
///
/// ## Audio Stream Types
///
/// - **Device Stream:** Captures audio from microphone or selected audio input device
/// - **System Stream:** Captures audio from system applications or entire system output
///
/// ## Interface Modes
///
/// The view supports two display modes based on the `multiDeviceMode` parameter:
/// - **Multi-Device Mode:** Shows both device and system audio selection with labels and help buttons
/// - **Single-Device Mode:** Shows only device selection in a compact layout
///
/// ## Dependencies
///
/// - `AudioProcessDiscoverer`: Manages system audio process detection and selection
/// - `AudioDeviceDiscoverer`: Handles audio input device enumeration and selection
#if os(macOS)
struct MacAudioDevicesView: View {
    @EnvironmentObject var audioProcessDiscoverer: AudioProcessDiscoverer
    @EnvironmentObject var audioDeviceDiscoverer: AudioDeviceDiscoverer
    @Binding var isRecording: Bool
    @State private var showDeviceHelp: Bool = false
    @State private var showSystemHelp: Bool = false
    let multiDeviceMode: Bool
    
    var body: some View {
        if multiDeviceMode {
            VStack(alignment: .leading, spacing: 10) {
                // Device section
                if !audioDeviceDiscoverer.audioDevices.isEmpty {
                    HStack {
                        Text("Device:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 56, alignment: .leading)
                        
                        ClickableDropdownPicker(
                            items: audioDeviceDiscoverer.audioDevices,
                            selection: Binding(
                                get: { audioDeviceDiscoverer.audioDevices.first { $0.name == audioDeviceDiscoverer.selectedAudioInput } ?? audioDeviceDiscoverer.audioDevices.first! },
                                set: { audioDeviceDiscoverer.selectedAudioInput = $0.name }
                            ),
                            displayText: { $0.name },
                            isDisabled: isRecording,
                            onWillOpen: {
                                audioDeviceDiscoverer.refreshDevices(selectFirst: false)
                            }
                        )
                        .frame(maxWidth: 260)
                        
                        Button(action: { showDeviceHelp = true }) {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Device audio input help")
                    }
                }
                
                // Process section
                HStack {
                    Text("System:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(width: 56, alignment: .leading)
                    ClickableDropdownPicker(
                        items: audioProcessDiscoverer.availableProcessOptions,
                        selection: $audioProcessDiscoverer.selectedProcessForStream,
                        displayText: { $0.name },
                        isDisabled: isRecording,
                        onWillOpen: {
                            audioProcessDiscoverer.refreshProcessList()
                        }
                    )
                    .frame(maxWidth: 260)
                    
                    Button(action: { showSystemHelp = true }) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("System audio capture help")
                }
            }
            .alert("Device Stream", isPresented: $showDeviceHelp) {
                Button("OK") { }
            } message: {
                Text("Captures audio from your microphone or selected audio input device. This records your voice or external audio sources connected to your Mac.")
            }
            .alert("System Stream", isPresented: $showSystemHelp) {
                Button("OK") { }
            } message: {
                Text("Captures audio from system applications or the entire system.\n\n• No Audio: Disables system audio capture\n• Individual Apps: Captures audio from specific applications that are currently outputting audio.")
            }
        } else {
            HStack {
                if !audioDeviceDiscoverer.audioDevices.isEmpty {
                    ClickableDropdownPicker(
                        items: audioDeviceDiscoverer.audioDevices,
                        selection: Binding(
                            get: { audioDeviceDiscoverer.audioDevices.first { $0.name == audioDeviceDiscoverer.selectedAudioInput } ?? audioDeviceDiscoverer.audioDevices.first! },
                            set: { audioDeviceDiscoverer.selectedAudioInput = $0.name }
                        ),
                        displayText: { $0.name },
                        isDisabled: isRecording,
                        onWillOpen: {
                            audioDeviceDiscoverer.refreshDevices(selectFirst: false)
                        }
                    )
                    .frame(width: 250)
                }
            }
        }
    }
}

/// A custom dropdown picker that triggers a callback when clicked before opening
/// This component provides a popover-based selection interface with refresh capabilities.
///
/// ## Features
///
/// - **Pre-Open Callback:** Executes `onWillOpen` before displaying the picker for data refresh
/// - **Popover Interface:** Uses native popover presentation for selection options
/// - **Checkmark Indication:** Shows visual confirmation of current selection
/// - **Accessibility:** Supports proper button styling and interaction states
///
/// ## Generic Constraints
///
/// - `T`: Must conform to `Identifiable` and `Hashable` for SwiftUI list rendering
struct ClickableDropdownPicker<T: Identifiable & Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let displayText: (T) -> String
    let isDisabled: Bool
    let onWillOpen: () -> Void
    
    @State private var isOpen = false
    
    var body: some View {
        Button(action: {
            onWillOpen()
            isOpen = true
        }) {
            HStack {
                Text(displayText(selection))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
        }
        .disabled(isDisabled)
        .popover(isPresented: $isOpen) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    Button(action: {
                        selection = item
                        isOpen = false
                    }) {
                        HStack {
                            Text(displayText(item))
                            Spacer()
                            if item == selection {
                                Image(systemName: "checkmark")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .frame(minWidth: 200)
        }
    }
}

#Preview("Multi-Stream Input") {
    let mockAudioProcessDiscoverer = AudioProcessDiscoverer()
    let mockAudioDeviceDiscoverer = AudioDeviceDiscoverer()
    

    MacAudioDevicesView(
        isRecording: .constant(false),
        multiDeviceMode: true
    )
    .environmentObject(mockAudioProcessDiscoverer)
    .environmentObject(mockAudioDeviceDiscoverer)
    .padding()
    .frame(width: 450)
    .onAppear {
        mockAudioProcessDiscoverer.activeAudioProcessList = [
            .init(id: 456)
        ]
        mockAudioDeviceDiscoverer.audioDevices = [
            .init(id: 123, name: "Built-in Microphone"),
        ]
    }
}

#Preview("Single-Stream Input") {
    let mockAudioProcessDiscoverer = AudioProcessDiscoverer()
    let mockAudioDeviceDiscoverer = AudioDeviceDiscoverer()
    
    MacAudioDevicesView(
        isRecording: .constant(false),
        multiDeviceMode: false
    )
    .environmentObject(mockAudioProcessDiscoverer)
    .environmentObject(mockAudioDeviceDiscoverer)
    .padding()
    .frame(width: 450)
    .onAppear {
        mockAudioProcessDiscoverer.activeAudioProcessList = [
            .init(id: 456)
        ]
        mockAudioDeviceDiscoverer.audioDevices = [
            .init(id: 123, name: "Built-in Microphone"),
        ]
    }
}
#endif
