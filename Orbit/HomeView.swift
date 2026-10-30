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
        case .classera: return aggregateStatus(s.classera?.filter { ["classera-1", "classera-2"].contains($0.id) }.flatMap { [$0.status, $0.schedulerStatus ?? "Unknown", $0.webhookStatus ?? "Unknown"] } ?? [])
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
            guard let c = serviceSnapshot?.classera?.filter({ ["classera-1", "classera-2"].contains($0.id) }), !c.isEmpty else { return "Scheduler health not reported" }
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
    @StateObject private var latestReports = LatestClasseraReportsStore()
    let requestCommand: (PendingCommand) -> Void
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject private var library: HomelabStore
    @Environment(\.orbitNavigation) private var navigation
    @State private var localAnchor: String?
    private var scrollAnchor: Binding<String?> {
        Binding(get: { navigation?.anchor(for: "home") ?? localAnchor }, set: { value in
            if let value { localAnchor = value; navigation?.remember(value, for: "home") }
        })
    }
    private var favorites: [ServiceTileModel] { api.serviceTiles.filter { library.favorites.contains($0.target) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                OrbitVersionLink().id("version")
                if api.hasNotice { ConnectionNotice(api: api) }
                if let d = api.dashboard { serverSummary(d.server).id("server"); systemSummary(d).id("system") } else { DashboardPlaceholder(api: api) }
                SectionHeading(title: "Workspace")
                VStack(spacing: 10) {
                    NavigationLink { StudentDatabasesView(api: api) } label: {
                        CompactWorkspaceRow(title: "Students", subtitle: "Student directories and messaging windows")
                    }
                    NavigationLink { JarvisView(api: api) } label: {
                        CompactWorkspaceRow(title: "JARVIS", subtitle: "Voice chat and reviewed memory")
                    }
                    NavigationLink { DownloadsView(api: api) } label: {
                        CompactWorkspaceRow(title: "Downloads", subtitle: "Browse files & daily reports")
                    }
                    NavigationLink { CompactServicesOverview(api: api) } label: {
                        CompactWorkspaceRow(title: "Services", subtitle: "Classera · Gemini · Padel")
                    }
                    NavigationLink { AIKeyUsageView(api: api) } label: {
                        CompactWorkspaceRow(title: "AI Key Usage", subtitle: "Recorded Classera requests", divider: false)
                    }
                }.buttonStyle(.plain).id("workspace")
                LatestClasseraReportsSection(api: api, store: latestReports).id("reports")
                if !favorites.isEmpty {
                    SectionHeading(title: "Favorites")
                    LazyVStack(spacing: 10) { ForEach(favorites) { tile($0) } }.id("favorites")
                }
                HStack {
                    Text("Services").font(.headline); Spacer()
                    if api.dashboard != nil || api.serviceSnapshot != nil { Text("\(api.serviceTiles.filter { StatusTone($0.status) == .healthy }.count) working").font(.caption).foregroundStyle(.secondary) }
                }
                if let error = api.servicesError { Label(error, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                SnapshotStamp(date: api.servicesUpdatedAt, failed: api.servicesError != nil)
                LazyVStack(spacing: 10) { ForEach(api.serviceTiles) { tile($0) } }.id("services")
                HStack { Text("Recent activity").font(.headline); Spacer(); NavigationLink("View all") { ActivityView() }.font(.caption) }
                if library.events.isEmpty { Text("Your confirmed app actions will appear here.").font(.caption).foregroundStyle(.secondary) }
                else { Panel { VStack(alignment: .leading, spacing: 8) { ForEach(Array(library.events.prefix(3))) { ActivityRow(event: $0) } } } }
            }.padding(16).scrollTargetLayout()
        }.background(Brand.background).navigationTitle("Orbit").navigationBarTitleDisplayMode(.inline)
        .scrollPosition(id: scrollAnchor, anchor: .top)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshIndicator(loading: api.loading || api.servicesLoading || latestReports.loading) { Task { await refreshHome() } } } }
        .task { await api.ensureServicesFresh() }.refreshable { await refreshHome() }
    }
    private func refreshHome() async {
        async let dashboard: Void = api.refreshAll()
        if phase == .active && api.accessAllowed {
            await latestReports.load { try await api.latestClasseraReports() }
        }
        await dashboard
    }
    private func tile(_ model: ServiceTileModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink {
                switch model.target {
                case .service(let page): ServiceDetailView(api: api, page: page)
                case .process(let id): ProcessDetailView(api: api, processID: id, requestCommand: requestCommand)
                case .docker(let name): ContainerDetailView(api: api, containerName: name, requestCommand: requestCommand)
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.symbol).font(.title3).foregroundStyle(Brand.accent)
                        .frame(width: 24).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        StatusBadge(status: model.status)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Brand.accent)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            FavoriteButton(target: model.target)
        }.padding(12)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Brand.border, lineWidth: 1) }
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
            if let c = api.serviceSnapshot?.classera?.filter({ ["classera-1", "classera-2"].contains($0.id) }), !c.isEmpty { summary("Classera", "\(c.filter { StatusTone($0.status) == .healthy }.count)/\(c.count)") }
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






