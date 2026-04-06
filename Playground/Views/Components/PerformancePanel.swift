import SwiftUI
import Argmax

struct PerformancePanel: View {
    @EnvironmentObject private var sessionHistory: SessionHistoryManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Performance Metrics")
                    .font(.title2)
                    .bold()
                    .padding(.horizontal)

                // Live metrics from most recent activity
                if let latest = sessionHistory.sessions.first {
                    latestSessionMetrics(latest)
                }

                Divider()
                    .padding(.horizontal)

                // History comparison table
                if !sessionHistory.sessions.isEmpty {
                    historyTable
                }

                // System info
                Divider()
                    .padding(.horizontal)
                systemInfoSection
            }
            .padding(.vertical)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Latest Session Metrics

    private func latestSessionMetrics(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Latest: \(session.displayTitle)")
                    .font(.headline)
                Spacer()
                Text(session.settings.whisperKitModel.components(separatedBy: "_").dropFirst().joined(separator: " "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            if let timings = session.transcriptionTimings {
                transcriptionTimingsView(timings)
            } else {
                Text("No detailed timing data available for this session")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
        }
    }

    private func transcriptionTimingsView(_ timings: TranscriptionTimings) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Transcription Pipeline")
                .font(.subheadline)
                .bold()
                .padding(.horizontal)

            let pipeline = timings.fullPipeline
            let rows: [(String, Double, Double?)] = [
                ("Audio Processing", timings.audioProcessing * 1000, pipeline > 0 ? (timings.audioProcessing / pipeline) * 100 : nil),
                ("Encoding", timings.encoding * 1000, pipeline > 0 ? (timings.encoding / pipeline) * 100 : nil),
                ("Decoding", timings.decodingLoop * 1000, pipeline > 0 ? (timings.decodingLoop / pipeline) * 100 : nil),
                ("Full Pipeline", pipeline * 1000, nil),
            ]

            ForEach(rows, id: \.0) { label, ms, pct in
                HStack {
                    Text(label)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 160, alignment: .leading)
                    Text(String(format: "%8.2f ms", ms))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 100, alignment: .trailing)
                    if let pct {
                        Text(String(format: "%5.1f%%", pct))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
            }

            Divider().padding(.horizontal)

            // Summary metrics
            HStack(spacing: 24) {
                metricBadge("Tokens/s", value: String(format: "%.1f", timings.tokensPerSecond))
                metricBadge("RTF", value: String(format: "%.3f", timings.realTimeFactor))
                metricBadge("Speed", value: String(format: "%.1fx", timings.speedFactor))
                metricBadge("1st Token", value: String(format: "%.2fs", timings.firstTokenTime - timings.pipelineStart))
                metricBadge("Enc Runs", value: "\(Int(timings.totalEncodingRuns))")
                metricBadge("Dec Loops", value: "\(Int(timings.totalDecodingLoops))")
            }
            .padding(.horizontal)
        }
    }

    private func metricBadge(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .bold()
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - History Table

    private var historyTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session History")
                .font(.headline)
                .padding(.horizontal)

            // Table header
            HStack {
                Text("Time").frame(width: 70, alignment: .leading)
                Text("Mode").frame(width: 50, alignment: .leading)
                Text("Model").frame(width: 120, alignment: .leading)
                Text("Duration").frame(width: 60, alignment: .trailing)
                Text("tok/s").frame(width: 60, alignment: .trailing)
                Text("RTF").frame(width: 60, alignment: .trailing)
                Text("Pipeline").frame(width: 70, alignment: .trailing)
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal)

            ForEach(sessionHistory.sessions.prefix(20)) { session in
                HStack {
                    Text(timeString(session.timestamp))
                        .frame(width: 70, alignment: .leading)
                    Text(session.mode.rawValue.prefix(4))
                        .frame(width: 50, alignment: .leading)
                    Text(session.settings.whisperKitModel.components(separatedBy: "_").dropFirst().joined(separator: " ").prefix(16))
                        .frame(width: 120, alignment: .leading)
                    Text(session.displayDuration)
                        .frame(width: 60, alignment: .trailing)
                    if let t = session.transcriptionTimings {
                        Text(String(format: "%.1f", t.tokensPerSecond))
                            .frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.3f", t.realTimeFactor))
                            .frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.2fs", t.fullPipeline))
                            .frame(width: 70, alignment: .trailing)
                    } else {
                        Text("-").frame(width: 60, alignment: .trailing)
                        Text("-").frame(width: 60, alignment: .trailing)
                        Text("-").frame(width: 70, alignment: .trailing)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal)
            }
        }
    }

    // MARK: - System Info

    private var systemInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System Info")
                .font(.headline)
                .padding(.horizontal)

            let memInfo = getMemoryInfo()
            let bytesToGB = { (bytes: UInt64) -> String in
                String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
            }

            Group {
                infoRow("App Memory", value: bytesToGB(memInfo.appUsed))
                infoRow("System Used", value: bytesToGB(memInfo.totalUsed))
                infoRow("Total Memory", value: bytesToGB(memInfo.totalPhysical))
                infoRow("Device", value: WhisperKit.deviceName())
                infoRow("SDK Version", value: ArgmaxSDK.sdkVersion)

                let thermalState = ProcessInfo.processInfo.thermalState
                infoRow("Thermal", value: thermalState.description.capitalized)
            }
            .padding(.horizontal)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    // Memory info helper (simplified from ContentView)
    private func getMemoryInfo() -> (appUsed: UInt64, totalUsed: UInt64, totalPhysical: UInt64) {
        let totalPhysical = ProcessInfo.processInfo.physicalMemory

        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        let appUsed = result == KERN_SUCCESS ? UInt64(taskInfo.resident_size) : 0

        var hostSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.stride)
        var hostInfo = vm_statistics64_data_t()
        let vmResult = withUnsafeMutablePointer(to: &hostInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(hostSize)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &hostSize)
            }
        }
        let totalUsed: UInt64
        if vmResult == KERN_SUCCESS {
            let free = UInt64(hostInfo.free_count) * UInt64(vm_page_size)
            let inactive = UInt64(hostInfo.inactive_count) * UInt64(vm_page_size)
            totalUsed = totalPhysical - (free + inactive)
        } else {
            totalUsed = 0
        }

        return (appUsed, totalUsed, totalPhysical)
    }
}

extension ProcessInfo.ThermalState {
    var description: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
