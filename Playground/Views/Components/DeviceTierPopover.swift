import SwiftUI
import Argmax

// MARK: - Device support evaluation

/// Everything the popover renders for one model: the SDK's own device-support breakdown,
/// plus the two annotations that are app knowledge rather than SDK knowledge.
struct ModelDeviceSupport {
    /// The SDK's itemized verdict. Rows, overall result, and the first unmet requirement all
    /// come from one `PlatformValidator.deviceSupport(for:)` call, so nothing here can drift
    /// from what the load path enforces.
    let support: DeviceSupportReport
    /// Whether the model is already on disk (annotates the free-disk row; presentation only).
    let isOnDisk: Bool
    /// What `.auto` optimization resolves to on this device. Qwen-only; nil elsewhere.
    let autoOptimizationNote: String?
    /// The floors `support` was evaluated against; rows render as "measured ≥ floor".
    let modelRequirements: ModelRequirements
}

/// Builds the device-support breakdown shown in ``DeviceTierPopover``.
///
/// The SDK evaluates its own floors: which gates apply to this model, what this device
/// measures, and which requirement failed first. Nothing here re-derives a threshold or
/// re-reads a probe, so a release that moves a floor -- or adds a model family with different
/// floors -- moves this popover with it, with nothing to keep in sync by hand.
enum DeviceSupportEvaluator {

    static func report(role: DownloadRole, modelName: String, isOnDisk: Bool) -> ModelDeviceSupport {
        // Only the transcription row names a specific model; companion model names fall
        // back to the SDK-wide floors inside `forModel(named:)`.
        let requirements = ModelRequirements.forModel(named: modelName)

        return ModelDeviceSupport(
            support: PlatformValidator.deviceSupport(for: requirements),
            isOnDisk: isOnDisk,
            autoOptimizationNote: autoOptimizationNote(role: role, modelName: modelName),
            modelRequirements: requirements
        )
    }

    /// Optimization profiles are a Qwen3-ASR concept, so the note is omitted for other models.
    /// The SDK resolves `.auto`; the app only decides whether the line is relevant here.
    private static func autoOptimizationNote(role: DownloadRole, modelName: String) -> String? {
        guard role == .transcription,
              TranscriptionModelFamily(modelName: modelName) == .qwen
        else {
            return nil
        }
        let profile = ModelOptimizationMode.auto.resolved
        let name = profile == .latencyOptimized ? "Latency Optimized" : "Memory Optimized"
        return "Auto optimization resolves to \(name)"
    }
}

// MARK: - Row icon button

/// Sidebar model-row icon (next to the folder/trash controls) that reveals the device-support
/// breakdown for that row's model on click or hover. Tinted by the verdict: green seal when the
/// device is supported for the model, orange warning when it isn't.
struct DeviceTierButton: View {
    let role: DownloadRole
    let modelName: String
    /// Whether the model is already on disk (annotates the free-disk row).
    let isOnDisk: Bool

    @State private var isPresented = false
    @State private var report: ModelDeviceSupport?

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: (report?.support.isSupported ?? true) ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor((report?.support.isSupported ?? true) ? .green : .orange)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Device support")
        .onAppear {
            report = DeviceSupportEvaluator.report(role: role, modelName: modelName, isOnDisk: isOnDisk)
        }
        #if os(macOS)
        // Mirror the hover state (like InfoPopoverIcon) so hover-out closes the popover
        // instead of latching one open per row the pointer crossed.
        .onHover { isPresented = $0 }
        .help("Device support for \(modelName)")
        #endif
        .popover(isPresented: $isPresented) {
            popoverContent
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        // Recompute on open so free disk / verdict are current.
        let current = DeviceSupportEvaluator.report(role: role, modelName: modelName, isOnDisk: isOnDisk)
        let popover = DeviceTierPopover(modelName: modelName, report: current)
            .onAppear { report = current }
        #if os(iOS)
        popover.presentationCompactAdaptation(.popover)
        #else
        popover
        #endif
    }
}

// MARK: - Popover content

/// Device-support breakdown: one pass/fail line per requirement, the `.auto` optimization note
/// for Qwen, and the overall verdict ball.
struct DeviceTierPopover: View {
    let modelName: String
    let report: ModelDeviceSupport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Device Support · \(modelName)")
                .font(.caption)
                .fontWeight(.semibold)

            ForEach(report.support.requirements) { requirement in
                HStack(spacing: 6) {
                    Image(systemName: requirement.isSatisfied ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(requirement.isSatisfied ? .green : .red)
                    Text(label(for: requirement))
                        .font(.caption)
                    Spacer(minLength: 12)
                    Text(detail(for: requirement))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(requirement.isSatisfied ? .secondary : .red)
                }
            }

            if let note = report.autoOptimizationNote {
                Divider()

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                    Text(note)
                        .font(.caption)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(report.support.isSupported ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(report.support.isSupported ? "Validated on this device" : "Not validated on this device")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                // The SDK's own wording for the first unmet requirement, so the popover can
                // never disagree with the message the load path produces. Orange when the user
                // can act on it (storage), grey when the device simply can't run the model.
                if let failure = report.support.failure {
                    Text(failure.localizedDescription)
                        .font(.caption2)
                        .foregroundColor(failure.isRecoverable ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 240)
    }

    /// Row title for a requirement kind. Display strings are app-side; the SDK reports
    /// only the kind, the verdict, and the measured value.
    private func label(for requirement: DeviceRequirement) -> String {
        switch requirement.kind {
        case .osVersion: "OS version"
        case .neuralEngine: "Neural Engine"
        case .chip: "Chip"
        case .memory: "Memory"
        case .freeDiskSpace: "Free storage"
        @unknown default: requirement.kind.rawValue
        }
    }

    /// "424.4 GB ≥ 2 GB (downloaded)": measured value, floor comparison, on-disk annotation.
    private func detail(for requirement: DeviceRequirement) -> String {
        guard let measured = requirement.measured else {
            return requirement.isSatisfied ? "Available" : "Unavailable"
        }
        var text = measured
        if let minimum = minimumText(for: requirement) {
            text += " \(requirement.isSatisfied ? "≥" : "<") \(minimum)"
        }
        if requirement.kind == .freeDiskSpace, report.isOnDisk {
            text += " (downloaded)"
        }
        return text
    }

    /// The model's floor for a row. Neural Engine is presence-only: no floor to compare.
    private func minimumText(for requirement: DeviceRequirement) -> String? {
        let floors = report.modelRequirements
        switch requirement.kind {
        case .osVersion:
            #if os(macOS)
            return "\(floors.minimumMacOSVersion)"
            #else
            return "\(floors.minimumIOSVersion)"
            #endif
        case .chip:
            // The chip family picks the generation floor, same as the SDK's gate.
            // Unrecognized chips get no comparison.
            if requirement.measured?.hasPrefix("A") == true { return "A\(floors.minimumASeriesGeneration)" }
            if requirement.measured?.hasPrefix("M") == true { return "M\(floors.minimumMSeriesGeneration)" }
            return nil
        case .memory:
            return floors.minimumIOSMemory.map(Self.gigabytes)
        case .freeDiskSpace:
            return Self.gigabytes(floors.minimumFreeDiskSpace)
        case .neuralEngine:
            return nil
        @unknown default:
            return nil
        }
    }

    /// GiB with at most one decimal place, matching the SDK's measured-value formatting.
    private static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) GB"
    }
}

// Recoverability is app-side wording logic: only storage can be freed by the user.
private extension PlatformValidationError {
    var isRecoverable: Bool {
        if case .insufficientDiskSpace = self { return true }
        return false
    }
}
