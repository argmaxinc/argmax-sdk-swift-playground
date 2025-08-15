import Foundation
import SwiftUI

/// A SwiftUI view that visualizes audio buffer energy levels with threshold-based color coding.
/// This component provides real-time visual feedback for audio input levels and voice activity detection.
///
/// ## Features
///
/// - **Energy Visualization:** Displays individual energy values as vertical bars
/// - **Threshold-Based Coloring:** Uses green for energy above silence threshold, red below
/// - **Horizontal Scrolling:** Supports scrollable timeline view of energy history
/// - **Auto-Scroll:** Automatically scrolls to show the most recent energy values
///
/// ## Visual Design
///
/// - Each energy sample renders as a 2px wide rounded rectangle
/// - Bar height scales proportionally to energy value (max 24px)
/// - Background color indicates voice activity based on silence threshold
/// - Minimal spacing between bars for dense timeline representation
///
/// ## User Settings Integration
///
/// Respects the `silenceThreshold` setting from user preferences to determine
/// the threshold for voice activity detection and color coding.
struct VoiceEnergyView: View {
    let bufferEnergy: [Float]
    @AppStorage("silenceThreshold") private var silenceThreshold: Double = 0.2
    
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 1) {
                ForEach(Array(bufferEnergy.enumerated()), id: \.offset) { _, energy in
                    RoundedRectangle(cornerRadius: 2)
                        .frame(width: 2, height: max(0, min(CGFloat(energy), 1)) * 24)
                        .frame(maxHeight: 24)
                        .background(energy > Float(silenceThreshold) ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                }
            }
        }
        .defaultScrollAnchor(.trailing)
        .frame(height: 24)
        .scrollIndicators(.never)
    }
}

#Preview {
    let sampleEnergy: [Float] = (0..<400).map { _ in Float.random(in: 0...1) }
    VoiceEnergyView(bufferEnergy: sampleEnergy)
        .padding()
        .onAppear() {
            UserDefaults.standard.set(0.2, forKey: "silenceThreshold")
        }
}
