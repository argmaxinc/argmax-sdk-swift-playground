import ActivityKit
import WidgetKit
import SwiftUI

/// Bundle configuration for the transcription live activity widgets
///
/// This bundle registers all live activity widgets and configurations for the
/// transcription app. It provides the entry point for ActivityKit to discover
/// and manage live activities across different iOS presentation contexts.
@main
struct TranscriptionLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TranscriptionLiveActivity()
    }
}
