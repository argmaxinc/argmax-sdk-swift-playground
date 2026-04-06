import SwiftUI
import Argmax

struct HistoryView: View {
    @EnvironmentObject private var sessionHistory: SessionHistoryManager

    @State private var selectedRecordID: UUID?
    @State private var compareMode = false
    @State private var compareSelection: Set<UUID> = []

    var body: some View {
        Group {
            if sessionHistory.sessions.isEmpty {
                emptyState
            } else if let selectedID = selectedRecordID,
                      let record = sessionHistory.sessions.first(where: { $0.id == selectedID }) {
                SessionDetailView(record: record, allSessions: sessionHistory.sessions) {
                    selectedRecordID = nil
                }
            } else if compareMode && compareSelection.count == 2 {
                let records = compareSelection.compactMap { id in sessionHistory.sessions.first(where: { $0.id == id }) }
                if records.count == 2 {
                    SessionCompareView(left: records[0], right: records[1]) {
                        compareMode = false
                        compareSelection.removeAll()
                    }
                }
            } else {
                sessionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            compareMode = false
            compareSelection.removeAll()
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(selectedRecordID != nil)
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No sessions yet")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Transcribe or stream audio to build your history")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session History")
                    .font(.title2)
                    .bold()
                Spacer()

                #if os(macOS)
                if compareMode {
                    Text("\(compareSelection.count)/2 selected")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Cancel") {
                        compareMode = false
                        compareSelection.removeAll()
                    }
                    .glassSecondaryButtonStyle()
                    .controlSize(.small)
                } else {
                    Button {
                        compareMode = true
                        compareSelection.removeAll()
                    } label: {
                        Label("Compare", systemImage: "rectangle.split.2x1")
                    }
                    .glassSecondaryButtonStyle()
                    .controlSize(.small)
                    .disabled(sessionHistory.sessions.count < 2)
                }
                #endif

                Button(role: .destructive) {
                    sessionHistory.clearAll()
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .glassSecondaryButtonStyle()
                .controlSize(.small)
            }
            .padding()

            Divider()

            List {
                ForEach(sessionHistory.sessions) { session in
                    sessionRow(session)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if compareMode {
                                toggleCompareSelection(session.id)
                            } else {
                                selectedRecordID = session.id
                            }
                        }
                        .listRowSeparator(.visible)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        sessionHistory.removeSession(id: sessionHistory.sessions[index].id)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
        HStack(spacing: 12) {
            if compareMode {
                Image(systemName: compareSelection.contains(session.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(compareSelection.contains(session.id) ? .accentColor : .secondary)
            }

            Image(systemName: iconForMode(session.mode))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(session.settings.whisperKitModel.components(separatedBy: "_").dropFirst().joined(separator: " "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(session.displayDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let count = session.speakerCount {
                        Label("\(count)", systemImage: "person.2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if session.audioFileURL != nil {
                Image(systemName: "waveform.circle")
                    .foregroundColor(.green)
                    .help("Audio saved")
            }

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func iconForMode(_ mode: SessionMode) -> String {
        switch mode {
        case .stream: return "waveform.badge.mic"
        case .transcribeFile: return "doc"
        case .transcribeRecord: return "mic"
        }
    }

    private func toggleCompareSelection(_ id: UUID) {
        if compareSelection.contains(id) {
            compareSelection.remove(id)
        } else if compareSelection.count < 2 {
            compareSelection.insert(id)
        }
    }
}
