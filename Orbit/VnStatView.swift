import SwiftUI
import Charts

struct VnStatView: View {
    @ObservedObject var api: ServerAPI
    @Environment(\.scenePhase) private var phase
    @State private var snapshot: VnStatSnapshot?
    @State private var selected = ""
    @State private var busy = false
    @State private var error: String?
    @State private var monthly = false
    @State private var requestID = UUID()
    private var active: Bool { api.accessAllowed && phase != .background }
    private var interface: VnStatSnapshot.Interface? { snapshot?.interfaces.first { $0.id == selected } }
    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value <= Double(Int64.max/2) else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
    var body: some View {
        Form {
            if active {
                if let snapshot {
                    if snapshot.interfaces.isEmpty { Text("No tracked interfaces.").foregroundStyle(.secondary) }
                    else {
                        Picker("Interface", selection: $selected) {
                            ForEach(snapshot.interfaces) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                if let interface {
                    Section("Total recorded") {
                        LabeledContent("Received", value: Self.bytes(interface.rx))
                        LabeledContent("Sent", value: Self.bytes(interface.tx))
                        LabeledContent("Updated", value: InternetTrackerFormat.time(interface.updatedAt.map { $0 * 1000 }))
                    }
                    Section {
                        Picker("Period", selection: $monthly) { Text("Days").tag(false); Text("Months").tag(true) }.pickerStyle(.segmented)
                        let rows = monthly ? interface.months : interface.days
                        if rows.isEmpty { Text("No history for this period.").foregroundStyle(.secondary) }
                        else {
                            Chart(rows) { row in
                                BarMark(x: .value("Date", row.date), y: .value("Bytes", row.rx)).foregroundStyle(by: .value("Direction", "Received"))
                                BarMark(x: .value("Date", row.date), y: .value("Bytes", row.tx)).foregroundStyle(by: .value("Direction", "Sent"))
                            }
                            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let bytes = value.as(Double.self) { Text(Self.bytes(bytes)) } } } }
                            .chartXAxis {
                                AxisMarks(values: rows.enumerated().filter { $0.offset % max(1, rows.count / 5) == 0 }.map { $0.element.date }) { value in
                                    AxisValueLabel { if let date = value.as(String.self) { Text(String(date.suffix(monthly ? 7 : 5))) } }
                                }
                            }
                            .frame(height: 220)
                            ForEach(rows.reversed()) { row in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.date).font(.subheadline)
                                    HStack { Text("↓ " + Self.bytes(row.rx)); Spacer(); Text("↑ " + Self.bytes(row.tx)) }.font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Server interface traffic, not your provider’s remaining allowance.").font(.caption).foregroundStyle(.secondary)
                }
                if busy && snapshot == nil { ProgressView("Loading traffic…") }
                if let error { Text(error).foregroundStyle(.orange); Button("Refresh") { Task { await load() } }.disabled(busy) }
            }
        }
        .navigationTitle("vnStat").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(api.latestReportsContext)|\(active)") {
            requestID = UUID(); snapshot = nil; busy = false; error = nil
            if active { await load() }
        }
        .refreshable { await load() }
    }
    private func load() async {
        guard active, !busy else { return }; let id = UUID(), context = api.latestReportsContext; requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            let value = try await api.vnStat()
            guard requestID == id, active, api.latestReportsContext == context, !Task.isCancelled else { return }
            guard value.version == 1 else { throw URLError(.cannotParseResponse) }
            snapshot = value
            if !value.interfaces.contains(where: { $0.id == selected }) { selected = value.interfaces.first(where: { !$0.virtual })?.id ?? value.interfaces.first?.id ?? "" }
            error = nil
        } catch { guard requestID == id, active, api.latestReportsContext == context, !Task.isCancelled else { return }; self.error = "vnStat could not be refreshed. Try again." }
    }
}
