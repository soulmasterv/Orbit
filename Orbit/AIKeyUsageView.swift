import SwiftUI
import Charts

@MainActor
final class AIKeyUsageStore: ObservableObject {
    @Published private(set) var snapshot: AIKeyUsageResponse?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var generation = 0
    private var inFlight: (key: String, task: Task<Void, Never>)?

    func clear() {
        generation += 1; inFlight?.task.cancel(); inFlight = nil
        snapshot = nil; error = nil; loading = false
    }

    func load(api: ServerAPI, days: Int, className: String) async {
        guard api.accessAllowed && !Task.isCancelled else { return }
        let key = "\(days)|\(className)|\(api.baseURL)"
        if let flight = inFlight, flight.key == key { await flight.task.value; return }
        inFlight?.task.cancel()
        generation += 1; let epoch = generation
        // Never label an old class/range snapshot as the newly selected filter.
        if snapshot?.days != days || snapshot?.class_name != className { snapshot = nil }
        loading = true; error = nil
        let task = Task { @MainActor in
            defer { if epoch == generation { loading = false; inFlight = nil } }
            do {
                let value = try await api.aiKeyUsage(days: days, className: className)
                guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
                snapshot = value
            } catch {
                guard epoch == generation && api.accessAllowed && !ServerAPI.isRefreshCancellation(error) else { return }
                if let failure = error as? ClasseraMonitoringFailure, case .http(404, _) = failure {
                    self.error = "AI Key Usage is not available on this backend yet."
                } else if let failure = error as? ClasseraMonitoringFailure, case .http(401, _) = failure {
                    self.error = "Authentication failed. Check your Orbit connection in Settings."
                } else {
                    self.error = "Could not refresh usage statistics. Your last successful snapshot is retained."
                }
            }
        }
        inFlight = (key, task)
        await task.value
    }
}

struct AIKeyUsageView: View {
    @ObservedObject var api: ServerAPI
    @StateObject private var store: AIKeyUsageStore
    @Environment(\.scenePhase) private var phase
    @State private var days = 7
    @State private var className = "All"

    init(api: ServerAPI, store: AIKeyUsageStore? = nil) {
        self.api = api; _store = StateObject(wrappedValue: store ?? AIKeyUsageStore())
    }
    private var requestID: String { "\(days)|\(className)|\(api.baseURL)|\(api.accessAllowed)|\(phase == .active)" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Period", selection: $days) {
                    Text("Today").tag(1); Text("7 Days").tag(7); Text("30 Days").tag(30)
                }.pickerStyle(.segmented)
                Picker("Classera class", selection: $className) {
                    Text("All").tag("All"); Text("Classera 12F").tag("12F"); Text("Classera 12E").tag("12E")
                }.pickerStyle(.menu)
                if store.loading { ProgressView("Refreshing usage…").font(.caption) }
                if let error = store.error { Text(error).font(.subheadline).foregroundStyle(.orange) }
                if let value = store.snapshot {
                    content(value)
                } else if !store.loading && store.error == nil {
                    Text("Waiting for usage data").foregroundStyle(.secondary)
                }
            }.padding(16)
        }.background(Brand.background)
        .navigationTitle("AI Key Usage").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.loading || !api.accessAllowed).accessibilityLabel("Refresh AI key usage")
            }
        }
        .task(id: requestID) { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: api.accessAllowed) { _, allowed in if !allowed { store.clear() } }
        .onDisappear { store.clear() }
    }
    private func refresh() async {
        guard phase == .active && api.accessAllowed else { return }
        await store.load(api: api, days: days, className: className)
    }
    @ViewBuilder private func content(_ value: AIKeyUsageResponse) -> some View {
        Text("Today · \(value.timezone)").font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metric("Configured keys", value.configured_keys)
            metric("Active today", value.active_keys_today)
            metric("Requests today", value.requests_today)
            metric("Rate limits today (429)", value.rate_limits_today)
        }
        if value.state == "waiting" {
            Panel { Label("Waiting for usage data", systemImage: "clock").foregroundStyle(.secondary) }
        }
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Requests per key · Last \(value.chart_days) days").font(.headline)
                if value.daily.contains(where: { $0.requests > 0 }) {
                    Chart(value.daily) { point in
                        BarMark(x: .value("Day", point.shortDay), y: .value("Requests", point.requests))
                            .foregroundStyle(by: .value("Key", point.label))
                    }
                    .chartForegroundStyleScale(range: [Color.blue, .teal, .orange, .pink, .cyan, .green, .yellow, .red])
                    .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    .frame(height: 210)
                    .accessibilityLabel("Daily API request counts by key")
                } else {
                    Text("No requests recorded in this chart period.").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                }
                Text("Each bar is one Cairo calendar day, split by key. Today may be incomplete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Text("Keys · \(days == 1 ? "Today" : "Last \(days) days")").font(.headline)
        Panel {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        Text("Key"); Text("Requests"); Text("Success"); Text("Failed"); Text("Last used")
                    }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(value.keys) { key in
                        GridRow {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(key.displayName).font(.subheadline.weight(.medium))
                                Text(!key.configured ? "Not in current pool" : key.requests == 0 ? "Unused in period" : "Used")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text("\(key.requests)"); Text("\(key.successful)"); Text("\(key.failed)")
                            Text(Self.lastUsed(key.last_used)).font(.caption)
                        }.monospacedDigit()
                    }
                }.padding(.vertical, 4)
            }
        }
        Text("Last used is the latest recorded request for this class filter, across all dates. Swipe the table to see all columns.")
            .font(.caption).foregroundStyle(.secondary)
        if value.unmapped_keys > 0 {
            Text("Some historical requests do not match a currently configured key. They remain separate as unmapped keys.")
                .font(.caption).foregroundStyle(.orange)
        }
        Panel { Text(value.recommendation).font(.subheadline) }
        Text("Usage records alone cannot establish available quota. No Gemini calls are made for these statistics.")
            .font(.caption).foregroundStyle(.secondary)
        Text("Updated \(Date(timeIntervalSince1970: Double(value.updated_at)).formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func metric(_ title: String, _ number: Int) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(number)").font(.title2.weight(.semibold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private static func lastUsed(_ timestamp: String?) -> String {
        guard let timestamp else { return "Never recorded" }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: timestamp) else { return "Unavailable" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
