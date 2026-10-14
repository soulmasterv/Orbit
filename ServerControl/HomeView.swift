import SwiftUI

struct ServiceTileModel: Identifiable {
    let target: FavoriteTarget
    let name: String
    let symbol: String
    let status: String
    let detail: String
    var id: String { target.id }
}
enum ServiceIdentity {
    static func identify(_ name: String) -> (String, String) {
        for (match, title, symbol) in [("immich", "Immich", "photo.stack"), ("pi-hole", "Pi-hole", "shield.lefthalf.filled"), ("pihole", "Pi-hole", "shield.lefthalf.filled"), ("uptime-kuma", "Uptime Kuma", "waveform.path.ecg"), ("portainer", "Portainer", "shippingbox"), ("vnstat", "vnStat", "chart.bar"), ("whatsapp", "WhatsApp", "message"), ("server-bot", "Server Bot", "bubble.left.and.bubble.right")] {
            if name.lowercased().contains(match) { return (title, symbol) }
        }
        return (name, "server.rack")
    }
}
extension ServerAPI {
    var serviceTiles: [ServiceTileModel] {
        var result = ServicePage.allCases.map { ServiceTileModel(target: .service($0), name: $0.title, symbol: $0.symbol, status: serviceStatus($0), detail: serviceSummary($0)) }
        result += (dashboard?.containers ?? []).map { c in
            let identity = ServiceIdentity.identify(c.name)
            return ServiceTileModel(target: .docker(c.name), name: identity.0, symbol: identity.1, status: c.displayStatus, detail: "Docker • \(c.status ?? "Health not reported")")
        }
        result += (dashboard?.processes ?? []).map { p in
            let identity = ServiceIdentity.identify(p.name)
            return ServiceTileModel(target: .process(p.id), name: identity.0, symbol: identity.1, status: p.status.capitalized, detail: "PM2 • \(p.memoryMB.map { "\($0.oneDecimal) MB" } ?? "Memory not reported")")
        }
        return result
    }
    func serviceStatus(_ page: ServicePage) -> String {
        guard let s = serviceSnapshot else { return "Unavailable" }
        switch page {
        case .gemini: return aggregateStatus(s.gemini?.map(\.status) ?? [])
        case .classera: return aggregateStatus(s.classera?.flatMap { [$0.status, $0.schedulerStatus ?? "Unknown", $0.webhookStatus ?? "Unknown"] } ?? [])
        case .padel:
            if let delivery = s.padel?.first(where: { $0.isWhatsApp })?.deliveryStatus, [.warning, .error].contains(StatusTone(delivery)) { return delivery }
            return aggregateStatus(s.padel?.map(\.status) ?? [])
        }
    }
    func serviceSummary(_ page: ServicePage) -> String {
        switch page {
        case .gemini:
            guard let keys = serviceSnapshot?.gemini, !keys.isEmpty else { return "Key health not reported" }
            return "\(keys.filter { StatusTone($0.status) == .healthy }.count)/\(keys.count) keys working"
        case .classera:
            guard let c = serviceSnapshot?.classera, !c.isEmpty else { return "Scheduler health not reported" }
            return "\(c.filter { StatusTone($0.status) == .healthy }.count)/\(c.count) instances working"
        case .padel:
            guard let c = serviceSnapshot?.padel, !c.isEmpty else { return "Application & delivery health" }
            return "\(c.filter { StatusTone($0.status) == .healthy }.count)/\(c.count) components online"
        }
    }
    private func aggregateStatus(_ states: [String]) -> String {
        for tone in [StatusTone.error, .warning, .stopped] { if let state = states.first(where: { StatusTone($0) == tone }) { return state } }
        return states.isEmpty || states.contains(where: { StatusTone($0) == .unknown }) ? "Unknown" : "Working"
    }
}
struct HomeView: View {
    @ObservedObject var api: ServerAPI
    let requestCommand: (PendingCommand) -> Void
    @EnvironmentObject private var library: HomelabStore
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicType.isAccessibilitySize ? 1 : 2) }
    private var favorites: [ServiceTileModel] { api.serviceTiles.filter { library.favorites.contains($0.target) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if api.hasNotice { ConnectionNotice(api: api) }
                if let d = api.dashboard { serverSummary(d.server); systemSummary(d) } else { DashboardPlaceholder(api: api) }
                NavigationLink {
                    StudentsView(api: api)
                } label: {
                    Panel {
                        HStack(spacing: 12) {
                            Image(systemName: "person.3").foregroundStyle(Brand.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Students").font(.headline).foregroundStyle(.primary)
                                Text("Student directory and messaging windows")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                }.buttonStyle(.plain)
                if !favorites.isEmpty {
                    SectionHeading(title: "Favorites")
                    LazyVGrid(columns: columns, spacing: 10) { ForEach(favorites) { tile($0) } }
                }
                HStack {
                    Text("Services").font(.headline); Spacer()
                    if api.dashboard != nil || api.serviceSnapshot != nil { Text("\(api.serviceTiles.filter { StatusTone($0.status) == .healthy }.count) working").font(.caption).foregroundStyle(.secondary) }
                }
                if let error = api.servicesError { Label(error, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                SnapshotStamp(date: api.servicesUpdatedAt, failed: api.servicesError != nil)
                LazyVGrid(columns: columns, spacing: 10) { ForEach(api.serviceTiles) { tile($0) } }
                HStack { Text("Recent activity").font(.headline); Spacer(); NavigationLink("View all") { ActivityView() }.font(.caption) }
                if library.events.isEmpty { Text("Your confirmed app actions will appear here.").font(.caption).foregroundStyle(.secondary) }
                else { Panel { VStack(alignment: .leading, spacing: 8) { ForEach(Array(library.events.prefix(3))) { ActivityRow(event: $0) } } } }
            }.padding(16)
        }.background(Brand.background).navigationTitle("Command Center").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshIndicator(loading: api.loading || api.servicesLoading) { Task { await api.refreshAll() } } } }
        .task { await api.ensureServicesFresh() }.refreshable { await api.refreshAll() }
    }
    private func tile(_ model: ServiceTileModel) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 7) {
                HStack { Image(systemName: model.symbol).font(.title3).foregroundStyle(Brand.accent); Spacer(); FavoriteButton(target: model.target) }
                NavigationLink {
                    switch model.target {
                    case .service(let page): ServiceDetailView(api: api, page: page)
                    case .process(let id): ProcessDetailView(api: api, processID: id, requestCommand: requestCommand)
                    case .docker(let name): ContainerDetailView(api: api, containerName: name, requestCommand: requestCommand)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                        StatusBadge(status: model.status)
                        Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    private func serverSummary(_ server: ServerStats) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label(server.hostname, systemImage: "server.rack").font(.subheadline.weight(.semibold)).lineLimit(1); Spacer(); StatusBadge(status: api.connection == .connected ? "Online" : api.connection.title) }
                Text("Uptime \(server.uptime)").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 14) {
                    metric("CPU", value: server.cpuPercent.percentText, percent: server.cpuPercent)
                    metric("RAM", value: "\(server.memoryUsedGB.oneDecimal)/\(server.memoryTotalGB.oneDecimal) GB", percent: percentage(server.memoryUsedGB, server.memoryTotalGB))
                    metric("Disk", value: percentage(server.diskUsedGB, server.diskTotalGB).percentText, percent: percentage(server.diskUsedGB, server.diskTotalGB))
                }
                SnapshotStamp(date: api.lastUpdated, failed: api.errorMessage != nil)
            }
        }
    }
    private func metric(_ title: String, value: String, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            ProgressView(value: percent.boundedPercent, total: 100).tint(percent >= 90 ? .orange : Brand.accent)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func systemSummary(_ d: DashboardResponse) -> some View {
        HStack(alignment: .top, spacing: 12) {
            summary("PM2", "\(d.processes.filter { StatusTone($0.status) == .healthy }.count)/\(d.processes.count)")
            summary("Docker", "\(d.containers.filter { $0.isRunning && !$0.isUnhealthy }.count)/\(d.containers.count)")
            if let keys = api.serviceSnapshot?.gemini, !keys.isEmpty { summary("Gemini", "\(keys.filter { StatusTone($0.status) == .healthy }.count)/\(keys.count)") }
            if let c = api.serviceSnapshot?.classera, !c.isEmpty { summary("Classera", "\(c.filter { StatusTone($0.status) == .healthy }.count)/\(c.count)") }
        }
    }
    private func summary(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(value).font(.subheadline.bold()).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func percentage(_ used: Double, _ total: Double) -> Double { total > 0 ? used / total * 100 : 0 }
}
extension DockerContainer {
    var isRunning: Bool { state.map { $0.lowercased() == "running" } ?? (status?.lowercased().hasPrefix("up") ?? false) }
    var isUnhealthy: Bool { status?.lowercased().contains("unhealthy") ?? false }
    var displayStatus: String { isUnhealthy ? "Unhealthy" : (isRunning ? "Running" : (state?.capitalized ?? "Unknown")) }
}
extension PadelComponent { var isWhatsApp: Bool { id.lowercased() == "whatsapp" || name.lowercased().contains("whatsapp") } }

