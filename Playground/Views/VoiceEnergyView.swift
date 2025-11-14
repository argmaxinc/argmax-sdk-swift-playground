import Foundation
import SwiftUI
import Charts

/// A SwiftUI view that visualizes audio buffer energy levels with threshold-based color coding.
/// This component provides real-time visual feedback for audio input levels and voice activity detection.
///
/// ## Features
///
/// - **Energy Visualization:** Displays individual energy values as vertical bars using SwiftUI Charts
/// - **Threshold-Based Coloring:** Uses green for energy above silence threshold, red below
/// - **Efficient Rendering:** Single Chart component instead of hundreds of individual views
/// - **Complete Timeline:** Shows all energy samples from the entire audio session
///
/// ## Visual Design
///
/// - Each energy sample renders as a 2px wide bar using BarMark
/// - Bar height scales proportionally to energy value
/// - Color coding based on silence threshold for voice activity indication
/// - Optimized performance using SwiftUI Charts framework
///
/// ## User Settings Integration
///
/// Respects the `silenceThreshold` setting from user preferences to determine
/// the threshold for voice activity detection and color coding.
struct VoiceEnergyView: View {
    let bufferEnergy: [Float]
    @AppStorage("silenceThreshold") private var silenceThreshold: Double = 0.2
    
    /// Data structure for Chart energy values
    private struct EnergyData: Identifiable {
        let id: Int
        let value: Float
    }
    
    /// Prepare chart data from all energy samples
    private var chartData: [EnergyData] {
        bufferEnergy.enumerated().map { index, energy in
            let clampedEnergy = min(max(energy, 0), 1)
            return EnergyData(id: index, value: clampedEnergy)
        }
    }
    
    var body: some View {
        let energyChartData = chartData
        return Group {
            if energyChartData.isEmpty {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 24)
            } else {
            #if os(macOS)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    Chart(energyChartData) { energyData in
                        BarMark(
                            x: .value("Index", energyData.id),
                            y: .value("Energy", energyData.value),
                            width: 2
                        )
                        .cornerRadius(1)
                        .foregroundStyle(energyData.value > Float(silenceThreshold) ? .green : .red)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: 0...1)
                    .chartXScale(domain: 0...max(1, energyChartData.count - 1))
                    .frame(width: CGFloat(energyChartData.count * 3), height: 24)
                    .clipped()
                    .id("chart")
                }
                .defaultScrollAnchor(.trailing)
                .frame(height: 24)
                .scrollIndicators(.never)
                .onChange(of: bufferEnergy.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("chart", anchor: .trailing)
                    }
                }
                .onAppear {
                    proxy.scrollTo("chart", anchor: .trailing)
                }
            }
            #else
            ScrollView(.horizontal) {
                Chart(energyChartData) { energyData in
                    BarMark(
                        x: .value("Index", energyData.id),
                        y: .value("Energy", energyData.value),
                        width: 2
                    )
                    .cornerRadius(1)
                    .foregroundStyle(energyData.value > Float(silenceThreshold) ? .green : .red)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...1)
                .chartXScale(domain: 0...max(1, energyChartData.count - 1))
                .frame(width: CGFloat(energyChartData.count * 3), height: 24)
                .clipped()
            }
            .defaultScrollAnchor(.trailing)
            .frame(height: 24)
            .scrollIndicators(.never)
            #endif
        }
        }
    }
}

#Preview {
    let sampleEnergy: [Float] = (0..<400).map { _ in Float.random(in: 0...1) }
    VoiceEnergyView(bufferEnergy: sampleEnergy)
        .padding()
        .onAppear() {
            UserDefaults.standard.set(0.9, forKey: "silenceThreshold")
        }
}
