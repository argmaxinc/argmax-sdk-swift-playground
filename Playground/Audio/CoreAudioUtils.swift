#if os(macOS)
import CoreAudio

/// A dedicated `DispatchQueue` for CoreAudio API calls, needed for discovering current AudioProcess and creating ProcessTapper into each process.
extension DispatchQueue {
    static let argmaxCoreAudio = DispatchQueue(label: "Argmax.CoreAudio", qos: .userInitiated)
}

/// Creates an `AudioObjectPropertyAddress` with the specified selector and default scope/element values.
///
/// This utility function simplifies the creation of Core Audio property addresses by providing
/// sensible defaults for the scope and element parameters, which are commonly used when
/// querying audio object properties.
///
/// - Parameters:
///   - selector: The property selector identifying which property to access
///   - scope: The property scope (defaults to global scope)
///   - element: The property element (defaults to main element)
/// - Returns: A configured `AudioObjectPropertyAddress` for use with Core Audio APIs
func getPropertyAddress(selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    return AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}
#endif
