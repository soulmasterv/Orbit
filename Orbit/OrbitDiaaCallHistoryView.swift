import SwiftUI

struct OrbitDiaaCallHistory: Decodable {
    struct Call: Decodable, Identifiable {
        let id: String
        let seen_at: Double
    }

    let total: Int
    let calls: [Call]
}

struct OrbitDiaaCallHistoryView: View {
    @ObservedObject var api: ServerAPI
    let number: String
    @Environment(\.scenePhase) private var phase
    @State private var timeframe = Timeframe.week
    @State private var from = Date()
    @State private var through = Date()
    @State private var endAnchor = Date()
    @State private var records: [OrbitDiaaCallHistory.Call] = []
    @State private var total: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()

    private enum Timeframe: String, CaseIterable, Identifiable {
        case today = "Today", week = "Last 7 days", month = "Last 30 days", custom = "Custom dates"
        var id: Self { self }
    }

    private var cairo: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Cairo") ?? .gmt
        return calendar
    }

    private var interval: DateInterval? {
        let today = cairo.startOfDay(for: endAnchor)
        let start: Date
        let end: Date
        switch timeframe {
        case .today, .week, .month:
            let days = timeframe == .today ? 0 : timeframe == .week ? 6 : 29
            guard let value = cairo.date(byAdding: .day, value: -days, to: today) else { return nil }
            start = value
            end = endAnchor
        case .custom:
            start = cairo.startOfDay(for: from)
            guard let tomorrow = cairo.date(byAdding: .day, value: 1, to: cairo.startOfDay(for: through)) else { return nil }
            end = min(tomorrow, endAnchor)
        }
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private var visible: Bool { api.accessAllowed && phase == .active }

    var body: some View {
        Form {
            if visible {
                Section("Timeframe") {
                    Picker("Range", selection: $timeframe) {
                        ForEach(Timeframe.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if timeframe == .custom {
                        DatePicker("From", selection: $from, in: ...Date(), displayedComponents: .date)
                        DatePicker("Through", selection: $through, in: ...Date(), displayedComponents: .date)
                    }
                }
                Section {
                    if let error { Text(error).foregroundStyle(.orange) }
                    if loading { ProgressView("Loading calls…") }
                    if let total {
                        Text("\(total) calls seen")
                        ForEach(records) { call in
                            Text(OrbitDiaaFriendsView.cairoCallTime(call.seen_at))
                        }
                        if records.count < total {
                            Button("Load more") { Task { await load(reset: false) } }.disabled(loading)
                        }
                    }
                } header: {
                    Text(number)
                } footer: {
                    Text("Times are in Cairo. Call history starts when detailed tracking was enabled.")
                }
            }
        }
        .environment(\.timeZone, cairo.timeZone)
        .scrollContentBackground(.hidden)
        .modifier(StudentAppearance())
        .navigationTitle("Call history")
        .task(id: "\(timeframe)|\(from)|\(through)|\(visible)|\(api.latestReportsContext)") {
            requestID = UUID()
            loading = false
            records = []
            total = nil
            error = nil
            if visible { await load(reset: true) }
        }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard visible && !loading else { return }
        if reset {
            endAnchor = Date()
            records = []
            total = nil
        }
        guard let interval else {
            error = "Choose a valid date range."
            return
        }
        let id = UUID()
        requestID = id
        loading = true
        error = nil
        defer { if requestID == id { loading = false } }
        do {
            let result = try await api.diaaCallHistory(number: number, start: interval.start, end: interval.end,
                                                      offset: records.count)
            guard requestID == id, visible, !Task.isCancelled else { return }
            records.append(contentsOf: result.calls)
            total = result.total
        } catch {
            guard requestID == id, visible, !Task.isCancelled else { return }
            self.error = "Call history could not be loaded. Pull down to retry."
        }
    }
}
