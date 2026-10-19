import SwiftUI

struct ControlMenu: View {
    let name: String
    let target: PendingCommand.Target
    let disabled: Bool
    let requestCommand: (PendingCommand) -> Void
    var body: some View {
        Menu {
            ForEach(ServerAction.allCases, id: \.rawValue) { action in
                Button(role: action == .stop ? .destructive : nil) { requestCommand(PendingCommand(name: name, target: target, action: action)) } label: { Label(action.title, systemImage: action.symbol) }
            }
        } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 44, minHeight: 44) }
        .disabled(disabled).accessibilityLabel("Control \(name)").accessibilityHint("Confirmation and device authentication required")
    }
}
struct ProcessesView: View {
    @ObservedObject var api: ServerAPI
    let requestCommand: (PendingCommand) -> Void
    @State private var search = ""
    private var processes: [PM2Process] { (api.dashboard?.processes ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                SearchField(prompt: "Find a process", text: $search)
                if api.hasNotice { ConnectionNotice(api: api) }
                SnapshotStamp(date: api.lastUpdated, failed: api.errorMessage != nil)
                if api.dashboard == nil { DashboardPlaceholder(api: api) }
                else {
                    Text("\(processes.count) processes").font(.subheadline.weight(.semibold)).padding(.vertical, 4)
                    if processes.isEmpty { FeatureUnavailable(title: "No processes", message: search.isEmpty ? "No PM2 processes were returned." : "Try a different search.") }
                    ForEach(processes) { p in
                        Panel {
                            VStack(alignment: .leading, spacing: 5) {
                                NavigationLink { ProcessDetailView(api: api, processID: p.id, requestCommand: requestCommand) } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack { Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2); Spacer(); StatusBadge(status: p.status.capitalized) }
                                        HStack(spacing: 12) {
                                            Text("#\(p.id)")
                                            if let cpu = p.cpu { Label(cpu.percentText, systemImage: "cpu") }
                                            if let ram = p.memoryMB { Label("\(ram.oneDecimal) MB", systemImage: "memorychip") }
                                        }.font(.caption).foregroundStyle(.secondary)
                                        if p.uptime != nil || p.restartCount != nil { Text("\(p.uptime ?? "Uptime not reported") • \(p.restartCount.map { "\($0) restarts" } ?? "Restarts not reported")").font(.caption).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                HStack {
                                    NavigationLink { LogViewer(api: api, target: .process(p.id), name: p.name) } label: { Label("Logs", systemImage: "text.alignleft").font(.caption).frame(minHeight: 44) }
                                    Spacer(); FavoriteButton(target: .process(p.id))
                                    ControlMenu(name: p.name, target: .process(p.id), disabled: !api.canControl, requestCommand: requestCommand)
                                }
                            }
                        }
                    }
                }
            }.padding(16)
        }.background(Brand.background).navigationTitle("PM2").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshIndicator(loading: api.loading) { Task { await api.loadDashboard() } } } }
        .scrollDismissesKeyboard(.interactively).refreshable { await api.loadDashboard() }
    }
}
struct ContainersView: View {
    @ObservedObject var api: ServerAPI
    let requestCommand: (PendingCommand) -> Void
    @State private var search = ""
    private var containers: [DockerContainer] { (api.dashboard?.containers ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                SearchField(prompt: "Find a container", text: $search)
                if api.hasNotice { ConnectionNotice(api: api) }
                SnapshotStamp(date: api.lastUpdated, failed: api.errorMessage != nil)
                if api.dashboard == nil { DashboardPlaceholder(api: api) }
                else {
                    Text("\(containers.count) containers").font(.subheadline.weight(.semibold)).padding(.vertical, 4)
                    if containers.isEmpty { FeatureUnavailable(title: "No containers", message: "No containers match this view.") }
                    ForEach(containers) { c in
                        Panel {
                            VStack(alignment: .leading, spacing: 5) {
                                NavigationLink { ContainerDetailView(api: api, containerName: c.name, requestCommand: requestCommand) } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack { Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2); Spacer(); StatusBadge(status: c.displayStatus) }
                                        Text(c.image ?? "Image not reported").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text(c.status ?? "Health not reported").font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                HStack { Label("Container", systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary); Spacer(); FavoriteButton(target: .docker(c.name)); ControlMenu(name: c.name, target: .docker, disabled: !api.canControl, requestCommand: requestCommand) }
                            }
                        }
                    }
                }
            }.padding(16)
        }.background(Brand.background).navigationTitle("Docker").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshIndicator(loading: api.loading) { Task { await api.loadDashboard() } } } }
        .scrollDismissesKeyboard(.interactively).refreshable { await api.loadDashboard() }
    }
}
struct ContainerDetailView: View {
    @ObservedObject var api: ServerAPI
    let containerName: String
    let requestCommand: (PendingCommand) -> Void
    private var container: DockerContainer? { api.dashboard?.containers.first { $0.name == containerName } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let c = container {
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            StatusBadge(status: c.displayStatus)
                            LabeledContent("Image", value: c.image ?? "Not reported").font(.subheadline).textSelection(.enabled)
                            LabeledContent("State", value: c.state ?? "Not reported").font(.subheadline)
                            Text(c.status ?? "Health not reported").font(.subheadline).foregroundStyle(.secondary)
                            Divider()
                            CommandButtons(name: c.name, target: .docker, api: api, requestCommand: requestCommand)
                        }
                    }
                    NavigationLink { LogViewer(api: api, target: .docker(c.name), name: c.name) } label: { Label("Check container logs", systemImage: "text.alignleft").font(.subheadline).frame(minHeight: 44) }
                    Text("Logs require an authenticated backend endpoint. If unsupported, the console explains why.").font(.caption).foregroundStyle(.secondary)
                    SnapshotStamp(date: api.lastUpdated, failed: api.errorMessage != nil)
                } else { FeatureUnavailable(title: "Container unavailable", message: "This container is no longer in the snapshot.") }
            }.padding(16)
        }.background(Brand.background).navigationTitle(containerName).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { FavoriteButton(target: .docker(containerName)) } }
        .refreshable { await api.loadDashboard() }
    }
}
struct CommandButtons: View {
    let name: String
    let target: PendingCommand.Target
    @ObservedObject var api: ServerAPI
    let requestCommand: (PendingCommand) -> Void
    var body: some View {
        HStack {
            ForEach(ServerAction.allCases, id: \.rawValue) { action in
                Button { requestCommand(PendingCommand(name: name, target: target, action: action)) } label: { Label(action.title, systemImage: action.symbol).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44) }
                    .tint(action == .stop ? .red : Brand.accent).disabled(!api.canControl)
            }
        }
        if !api.canControl { Text(api.actionBusy ? "Another action is in progress." : "Refresh and verify your connection to enable controls.").font(.caption).foregroundStyle(.secondary) }
    }
}
