import SwiftUI
import Charts

struct ClasseraMonitoringView: View {
    @ObservedObject var api: ServerAPI
    @StateObject private var store: ClasseraMonitoringStore
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    @State private var search = ""
    @State private var classID = ""
    @State private var template = ""
    @State private var status = ""
    @State private var sort = "updated"
    @State private var ascending = false
    @State private var offset = 0
    @State private var rangeEnabled = false
    @State private var fromDate = Date().addingTimeInterval(-6 * 86400)
    @State private var toDate = Date()
    @State private var days = 7
    @State private var report = ""
    @State private var previewTarget: ClasseraReadyPreview?
    init(api: ServerAPI, store: ClasseraMonitoringStore? = nil, initialTab: Int = 0, initialSearch: String = "") {
        self.api = api; _store = StateObject(wrappedValue: store ?? ClasseraMonitoringStore())
        _tab = State(initialValue: initialTab); _search = State(initialValue: initialSearch)
    }
    private var query: [String: String] {
        if tab == 2 {
            return ["from": Self.day(Date().addingTimeInterval(Double(1-days)*86400)), "to": Self.day(Date()), "class_id": classID]
        }
        return ["search": search, "class_id": classID, "template": template, "status": status,
                "sort": sort, "direction": ascending ? "asc" : "desc", "offset": String(offset), "limit": "30",
                "from": rangeEnabled ? Self.day(fromDate) : "", "to": rangeEnabled ? Self.day(toDate) : "",
                "report": report]
    }
    private var requestKey: String {
        "\(tab)|\(query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))|\(phase == .active && api.accessAllowed)"
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(["Waiting List", "Delivery History", "Daily Statistics"].enumerated()), id: \.offset) { index, title in
                            StudentFilterChip(title: title, selected: tab == index) { tab = index; offset = 0 }
                        }
                    }
                }
                if store.loading { ProgressView("Refreshing…").font(.caption) }
                if let error = store.error { Text(error).font(.subheadline).foregroundStyle(.orange) }
                if store.pending != nil { ClasseraOperationPanel(api: api, store: store) }
                switch tab {
                case 0: waiting
                case 1: history
                default: statistics
                }
            }.padding(16)
        }.modifier(StudentAppearance())
        .navigationTitle("Classera").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(store.mutationBusy)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.loading || store.mutationBusy || !api.accessAllowed)
                    .accessibilityLabel("Refresh Classera monitoring")
            }
        }
        .task(id: requestKey) {
            guard phase == .active && api.accessAllowed else { return }
            store.restore()
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await refresh()
        }
        .onChange(of: phase) { _, value in if value == .background { store.clear() } }
        .onChange(of: api.accessAllowed) { _, value in if !value { store.clear() } }
        .onDisappear { store.clear() }
        .refreshable { await refresh() }
        .sheet(item: $previewTarget) { value in
            ClasseraNotificationPreview(api: api, store: store, classID: value.class_id)
        }
    }
    private func refresh() async {
        guard api.accessAllowed && phase == .active && !store.mutationBusy else { return }
        await store.load(api: api, tab: tab, query: query)
    }
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let response = store.waiting {
                stamp(response.updated_at)
                Text(response.notice).font(.caption).foregroundStyle(.secondary)
                if !response.sending_enabled {
                    Label("Sending disabled — template contract must be verified", systemImage: "lock.fill")
                        .font(.subheadline).foregroundStyle(.yellow)
                }
                if response.classes.isEmpty { empty("No waiting classes", "Waiting registrations will appear here.") }
                ForEach(response.classes) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(item.class_name).font(.headline)
                            Spacer()
                            Text(item.supported ? "Supported" : "Not supported")
                                .font(.caption).foregroundStyle(item.supported ? StudentPalette.accent : .yellow)
                        }
                        Text("\(item.waiting_count) waiting · \(item.eligible_count) eligible").font(.subheadline)
                        ForEach(item.students) { student in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(student.name?.isEmpty == false ? student.name! : "Not provided yet").font(.subheadline.weight(.medium))
                                Text(student.phone).monospacedDigit().textSelection(.enabled)
                                Text("Registered: \(Self.registration(student.joined_at))").font(.caption).foregroundStyle(.secondary)
                                Text("Notification: \(student.notification_status.replacingOccurrences(of: "_", with: " ").capitalized)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                            Divider()
                        }
                        Button("Preview invitation") { previewTarget = item }
                            .accessibilityIdentifier("classera.preview.\(item.class_id)")
                        Text("Preview is read-only. Class availability never enables a scheduler.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(14).background(StudentPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            } else if !store.loading && store.error == nil { empty("Waiting list unavailable", "Pull to refresh.") }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 13) {
            StudentSearchField(text: $search)
                .onChange(of: search) { _, _ in offset = 0 }
            TextField("Class code — all", text: $classID).textInputAutocapitalization(.characters)
                .onChange(of: classID) { _, _ in offset = 0 }
            TextField("Template — all", text: $template).textInputAutocapitalization(.never)
                .onChange(of: template) { _, _ in offset = 0 }
            HStack {
                Picker("Status", selection: $status) {
                    Text("All statuses").tag("")
                    ForEach(ClasseraDeliveryState.all, id: \.self) { Text(ClasseraDeliveryState.title($0)).tag($0) }
                }.onChange(of: status) { _, _ in offset = 0 }
                Spacer()
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("Updated").tag("updated"); Text("Report date").tag("date"); Text("Class").tag("class")
                    }
                    Toggle("Ascending", isOn: $ascending)
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
            Toggle("Filter report dates", isOn: $rangeEnabled).onChange(of: rangeEnabled) { _, _ in offset = 0 }
            if rangeEnabled {
                DatePicker("From", selection: $fromDate, displayedComponents: .date).onChange(of: fromDate) { _, _ in offset = 0 }
                DatePicker("To", selection: $toDate, displayedComponents: .date).onChange(of: toDate) { _, _ in offset = 0 }
            }
            if !report.isEmpty {
                HStack {
                    Text("Report: \(report)").font(.caption)
                    Spacer(); Button("Clear report") { report = ""; offset = 0 }
                }
            }
            if let response = store.history {
                stamp(response.updated_at)
                Text("\(response.total) records").font(.caption).foregroundStyle(.secondary)
                if response.records.isEmpty { empty("No delivery records", "Try another class, date, template or search.") }
                ForEach(response.records) { row in
                    NavigationLink { ClasseraDeliveryDetail(record: row) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(row.student ?? "Subscriber name unavailable").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(ClasseraDeliveryState.title(row.status)).font(.caption).foregroundStyle(color(row.status))
                            }
                            Text(row.phone).font(.subheadline).monospacedDigit()
                            Text("\(row.class_id) · \(row.report_date ?? "Report date unavailable")").font(.caption).foregroundStyle(.secondary)
                            Text(row.report).font(.caption).foregroundStyle(.secondary)
                            Text(row.template ?? "Template not recorded").font(.caption).foregroundStyle(.secondary)
                        }.foregroundStyle(.white).padding(13)
                            .background(StudentPalette.surface, in: RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain)
                }
                HStack {
                    Button("Previous") { offset = max(0, offset-30) }.disabled(offset == 0 || store.loading)
                    Spacer()
                    Text("Page \(offset/30 + 1)").font(.caption)
                    Spacer()
                    Button("Next") { if let next = response.next_offset { offset = next } }
                        .disabled(response.next_offset == nil || store.loading)
                }
                ForEach(response.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        }.textFieldStyle(.roundedBorder)
    }
    private var statistics: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Period", selection: $days) { Text("7 days").tag(7); Text("30 days").tag(30) }.pickerStyle(.segmented)
            TextField("Class code — all", text: $classID).textInputAutocapitalization(.characters).textFieldStyle(.roundedBorder)
            if let data = store.statistics {
                stamp(data.updated_at)
                metrics(data)
                if data.reports.isEmpty { empty("No reports in this period", "No example counts are substituted for missing data.") }
                if !data.reports.isEmpty {
                    Text("Daily delivery trend").font(.headline)
                    Chart {
                        ForEach(trend(data), id: \.day) { point in
                            LineMark(x: .value("Report date", point.day), y: .value("Delivered or read messages", point.count))
                                .foregroundStyle(StudentPalette.accent)
                            PointMark(x: .value("Report date", point.day), y: .value("Delivered or read messages", point.count))
                                .foregroundStyle(StudentPalette.accent)
                        }
                    }.frame(height: 180)
                    Text("Delivery status breakdown").font(.headline)
                    Chart {
                        ForEach(ClasseraDeliveryState.all, id: \.self) { state in
                            if let count = data.counts[state] {
                                BarMark(x: .value("Messages", count), y: .value("Status", ClasseraDeliveryState.title(state)))
                                    .foregroundStyle(color(state))
                            }
                        }
                    }.frame(height: 190)
                    Text("Delivery rate by class").font(.headline)
                    let rates = rates(data)
                    if rates.contains(where: { $0.rate != nil }) { Chart {
                        ForEach(rates, id: \.classID) { row in
                            if let rate = row.rate {
                                BarMark(x: .value("Class", row.classID), y: .value("Delivery rate %", rate))
                                    .foregroundStyle(StudentPalette.accent)
                            }
                        }
                    }.chartYScale(domain: 0...100).frame(height: 150) }
                    else { Text("Rates are unavailable without complete expected-recipient snapshots.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(rates, id: \.classID) { row in
                        LabeledContent(row.classID, value: rate(row.rate)).font(.caption)
                    }
                    Text("Reports — tap to inspect recipients").font(.headline)
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Date   Class   Expected   Accepted   Sent   Delivered   Read   Failed   Unknown").font(.caption.bold())
                            ForEach(data.reports) { row in
                                Button {
                                    report = row.report; classID = row.class_id; fromDate = Self.date(row.date)
                                    toDate = fromDate; rangeEnabled = true; offset = 0; tab = 1
                                } label: {
                                    HStack(spacing: 14) {
                                        Text(row.date).frame(width: 86, alignment: .leading)
                                        Text(row.class_id).frame(width: 45, alignment: .leading)
                                        Text(number(row.expected)).frame(width: 80)
                                        ForEach(["accepted","sent","delivered","read","failed","unknown"], id: \.self) { state in
                                            Text(number(row.counts[state])).frame(width: 68)
                                        }
                                    }.font(.caption.monospacedDigit()).padding(.vertical, 9)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                if data.unknown_date_records > 0 {
                    Text("\(data.unknown_date_records) historical records have no reliable report date and are excluded from date-based statistics.")
                        .font(.caption).foregroundStyle(.yellow)
                }
                ForEach(data.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func metrics(_ data: ClasseraStatisticsResponse) -> some View {
        VStack(spacing: 9) {
            LabeledContent("Expected recipient/report targets", value: number(data.expected))
            LabeledContent("Recorded attempts", value: String(data.attempts))
            ForEach(ClasseraDeliveryState.all, id: \.self) { state in
                LabeledContent(ClasseraDeliveryState.title(state), value: number(data.counts[state]))
            }
            LabeledContent("Not attempted", value: number(data.not_attempted))
            LabeledContent("Skipped", value: number(data.skipped))
            LabeledContent("Delivered/read targets", value: number(data.delivered_targets))
            LabeledContent("Delivery rate", value: rate(data.delivery_rate))
            Text("Rate denominator: \(number(data.expected)) expected targets. A message appears in one latest-status category. Acceptance and HTTP 200 do not prove delivery.")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.subheadline).padding(14).background(StudentPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func trend(_ data: ClasseraStatisticsResponse) -> [(day: String, count: Int)] {
        Dictionary(grouping: data.reports, by: \.date).keys.sorted().map { day in
            (day, data.reports.filter { $0.date == day }.reduce(0) { $0 + ($1.counts["delivered"] ?? 0) + ($1.counts["read"] ?? 0) })
        }
    }
    private func rates(_ data: ClasseraStatisticsResponse) -> [(classID: String, rate: Double?)] {
        Dictionary(grouping: data.reports, by: \.class_id).keys.sorted().map { key in
            let rows = data.reports.filter { $0.class_id == key }
            let complete = rows.allSatisfy { $0.expected != nil && $0.delivered_targets != nil }
            let expected = rows.reduce(0) { $0 + ($1.expected ?? 0) }
            let delivered = rows.reduce(0) { $0 + ($1.delivered_targets ?? 0) }
            return (key, complete && expected > 0 ? 100 * Double(delivered) / Double(expected) : nil)
        }
    }
    private func empty(_ title: String, _ description: String) -> some View {
        ContentUnavailableView(title, systemImage: "chart.bar.doc.horizontal", description: Text(description))
    }
    private func stamp(_ value: Int) -> some View {
        Text("Last updated: \(Date(timeIntervalSince1970: Double(value)).formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func number(_ value: Int?) -> String { value.map(String.init) ?? "Unavailable" }
    private func rate(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "Unavailable" }
    private func color(_ state: String) -> Color {
        switch state {
        case "delivered", "read": return StudentPalette.accent
        case "failed": return .red
        case "reserved", "unknown": return .yellow
        default: return .gray
        }
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Africa/Cairo")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }
    static func date(_ value: String) -> Date {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Africa/Cairo"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value) ?? Date()
    }
    static func registration(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

private struct ClasseraNotificationPreview: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var store: ClasseraMonitoringStore
    let classID: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: ClasseraReadyPreview?
    var body: some View {
        NavigationStack {
            Form {
                if let error = store.error { Section { Text(error).foregroundStyle(.orange) } }
                if store.loading { ProgressView("Loading read-only preview…") }
                if let value = store.preview, value.class_id == classID {
                    Section("Preview — no messages sent") {
                        LabeledContent("Class", value: value.class_name)
                        LabeledContent("Waiting", value: String(value.waiting_count))
                        LabeledContent("Eligible invitations", value: String(value.eligible_count))
                        Text("Invites students to opt in. It does not activate subscriptions or schedulers.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(value.students.filter(\.eligible)) { student in
                            VStack(alignment: .leading) { Text(student.name ?? "Not provided yet"); Text(student.phone).monospacedDigit() }
                        }
                    }
                    Section {
                        Button("Notify \(value.eligible_count) students") { confirmation = value }
                            .disabled(!value.can_execute || !store.vaultReady || store.pending != nil || store.mutationBusy || !api.accessAllowed)
                        if let reason = value.disabled_reason {
                            Text(reason == "template_contract_unverified" ? "Sending disabled until the approved template contract is verified." :
                                 reason == "class_not_supported" ? "This class is not supported yet." : "There are no eligible, unnotified students.")
                                .font(.caption).foregroundStyle(.yellow)
                        }
                        Button("Refresh preview") { Task { await store.loadPreview(api: api, classID: classID) } }.disabled(store.mutationBusy || store.loading)
                    }
                }
                if store.pending != nil { Section { ClasseraOperationPanel(api: api, store: store) } }
            }.scrollContentBackground(.hidden).modifier(StudentAppearance())
                .navigationTitle("Class-ready invitation").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(store.mutationBusy) } }
                .task { await store.loadPreview(api: api, classID: classID) }
                .confirmationDialog("Send class-ready invitations?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible, presenting: confirmation) { value in
                    Button("Notify \(value.eligible_count) students", role: .destructive) { Task { await store.submit(api: api, confirmed: value) } }
                    Button("Cancel", role: .cancel) {}
                } message: { value in
                    Text("Send one WhatsApp opt-in invitation to each of \(value.eligible_count) eligible students waiting for \(value.class_name). Authorize on your iPhone next. This does not start a scheduler or subscribe anyone.")
                }
        }.interactiveDismissDisabled(store.mutationBusy)
    }
}

private struct ClasseraOperationPanel: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var store: ClasseraMonitoringStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved notification operation").font(.headline)
            if let pending = store.pending {
                Text(pending.payload.request_id).font(.caption).textSelection(.enabled)
                Text("Class \(pending.payload.class_id) · \(pending.payload.expected_eligible_count) intended invitations").font(.caption)
            }
            if let value = store.operation {
                Text(value.status == "complete" ? "Processing complete — see delivery states below." : "Reserved — check status before any further action.")
                ForEach(ClasseraDeliveryState.all, id: \.self) { state in
                    LabeledContent(ClasseraDeliveryState.title(state), value: value.counts[state].map(String.init) ?? "Unavailable")
                        .font(.caption)
                }
                Text("Accepted is not delivered. Failed and unknown invitations are never automatically resent.").font(.caption).foregroundStyle(.secondary)
                if value.status == "complete" { Button("Reviewed — return to preview") { store.reviewed() } }
            }
            Button("Check status — does not send") { Task { await store.checkOperation(api: api) } }
                .disabled(store.loading || store.mutationBusy || !api.accessAllowed)
        }.padding(12).background(StudentPalette.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ClasseraDeliveryDetail: View {
    let record: ClasseraDeliveryRecord
    var body: some View {
        Form {
            Section("Report delivery") {
                LabeledContent("Student", value: record.student ?? "Unavailable")
                LabeledContent("Phone", value: record.phone).textSelection(.enabled)
                LabeledContent("Class", value: record.class_id)
                LabeledContent("Report", value: record.report)
                LabeledContent("Report date", value: record.report_date ?? "Unavailable")
                LabeledContent("Template", value: record.template ?? "Not recorded")
                LabeledContent("Message ID", value: record.message_id ?? "Not recorded").textSelection(.enabled)
                LabeledContent("Status", value: ClasseraDeliveryState.title(record.status))
                LabeledContent("Updated", value: Date(timeIntervalSince1970: Double(record.updated_at)).formatted(date: .abbreviated, time: .shortened))
            }
            Text(record.historical ? "Imported last-known snapshot. Earlier events, template and original attempt time may not have been recorded." :
                    "This is the latest confirmed state for this message attempt. API acceptance does not prove delivery.")
                .font(.caption).foregroundStyle(.secondary)
        }.scrollContentBackground(.hidden).modifier(StudentAppearance())
            .navigationTitle("Delivery record").navigationBarTitleDisplayMode(.inline)
    }
}
