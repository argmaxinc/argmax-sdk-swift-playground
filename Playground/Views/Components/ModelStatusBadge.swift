import SwiftUI
import Argmax

struct ModelStatusBadge: View {
    let state: ModelState
    let label: String?

    init(state: ModelState, label: String? = nil) {
        self.state = state
        self.label = label
    }

    private var color: Color {
        switch state {
        case .loaded: return .green
        case .unloaded: return .red
        default: return .yellow
        }
    }

    private var isAnimating: Bool {
        state != .loaded && state != .unloaded
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .foregroundStyle(color)
                .font(.system(size: 8))
                .symbolEffect(.variableColor, isActive: isAnimating)
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct SpeakerModelStatusBadge: View {
    let state: ModelState

    private var color: Color {
        switch state {
        case .loaded: return .green
        case .unloaded: return .red
        default: return .yellow
        }
    }

    private var isAnimating: Bool {
        state != .loaded && state != .unloaded
    }

    var body: some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(color)
            .font(.system(size: 8))
            .symbolEffect(.variableColor, isActive: isAnimating)
    }
}
