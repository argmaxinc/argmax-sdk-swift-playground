#if os(iOS)
import Foundation
import AppIntents

/// Live Activity button intent. Tapped from the Lock Screen, Dynamic Island, or the Mac mirror
/// of the iPhone's Live Activity, it ends the running streaming-transcription session.
///
/// The intent runs in the main app's background process and posts a `NotificationCenter` event
/// that `StreamViewModel` observes. The stream stops without the app coming to the foreground.
///
/// The file is a member of both the main app target (where `perform()` runs) and the Widget
/// extension target (which references the type for `Button(intent:)`). With the file only in
/// the widget extension, iOS would have no copy of the type in the main app to dispatch to.
@available(iOS 17.0, *)
struct StopTranscriptionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Transcription"
    static var description = IntentDescription("Stops the running streaming-transcription session.")
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("com.argmax.playground.stopTranscriptionRequested"),
                object: nil
            )
        }
        return .result()
    }
}
#endif
