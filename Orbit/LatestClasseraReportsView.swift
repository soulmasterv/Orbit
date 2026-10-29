import SwiftUI

struct LatestClasseraReportsSection: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var store: LatestClasseraReportsStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var requestID: String {
        "\(phase == .active)|\(api.accessAllowed)|\(api.hasSavedToken)|\(api.latestReportsContext)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Latest Classera Reports").font(.headline)
                Spacer()
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.loading || !api.accessAllowed || phase != .active)
                .accessibilityLabel("Refresh Classera report observations")
            }
            Text("Last observed in bot logs. Current Classera availability is not verified.")
                .font(.caption).foregroundStyle(.secondary)
            if store.loading {
                ProgressView("Reading report observations…").font(.caption)
            } else if let message = store.state.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                     count: dynamicType.isAccessibilitySize ? 1 : 2), spacing: 10) {
                ForEach(LatestClasseraReportsResponse.classes, id: \.self) { classID in
                    reportCard(classID, report: api.accessAllowed ? store.snapshot?.report(for: classID) : nil)
                }
            }
        }
        .task(id: requestID) { store.clear(); await refresh() }
        .onDisappear { store.clear() }
    }

    private func refresh() async {
        guard phase == .active && api.accessAllowed else { return }
        await store.load { try await api.latestClasseraReports() }
    }

    private func reportCard(_ classID: String, report: LatestClasseraReport?) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 9) {
                Text("Class \(classID)").font(.subheadline.weight(.semibold))
                Label("Last observed", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                if let report, report.hasObservation {
                    Text(report.title ?? "").font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    timestamp("Classera created", report.createdText)
                    timestamp("Log observed", report.observedText)
                    Text(report.timezoneText).font(.caption2).foregroundStyle(.secondary)
                    Text("From bot logs").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(store.loading ? "Reading logs…" : "No reliable observation to display.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func timestamp(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
