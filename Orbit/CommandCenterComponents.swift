import SwiftUI

enum StatusTone: Equatable {
    case healthy, warning, stopped, error, unknown
    init(_ value: String) {
        switch value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "healthy", "working", "online", "running", "connected", "accepted": self = .healthy
        case "warning", "rate limited", "high demand", "billing required", "payment ineligible", "webhook unavailable", "uncertain": self = .warning
        case "stopped", "offline", "exited", "paused", "cancelled": self = .stopped
        case "error", "invalid", "delivery failed", "google issue", "unhealthy", "errored", "failed", "authentication needed", "connection lost": self = .error
        default: self = .unknown
        }
    }
    var color: Color {
        switch self { case .healthy: return Brand.teal; case .warning: return .orange; case .error: return .red; case .stopped, .unknown: return .secondary }
    }
    var symbol: String {
        switch self { case .healthy: return "checkmark.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .error: return "xmark.circle.fill"; case .stopped: return "pause.circle.fill"; case .unknown: return "questionmark.circle" }
    }
}
struct StatusBadge: View {
    let status: String
    var body: some View {
        Label(status, systemImage: StatusTone(status).symbol)
            .font(.caption.weight(.medium)).foregroundStyle(StatusTone(status).color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(StatusTone(status).color.opacity(0.1), in: Capsule())
            .accessibilityElement(children: .combine).fixedSize(horizontal: false, vertical: true)
    }
}
struct Panel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content().padding(12).background(Brand.surface, in: RoundedRectangle(cornerRadius: 16)) }
}
struct FavoriteButton: View {
    @EnvironmentObject private var library: HomelabStore
    let target: FavoriteTarget
    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { library.toggle(target) } } label: {
            Image(systemName: library.favorites.contains(target) ? "star.fill" : "star")
                .foregroundStyle(library.favorites.contains(target) ? Color.orange : Color.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel(library.favorites.contains(target) ? "Remove favorite" : "Add favorite")
    }
}
struct RefreshIndicator: View {
    let loading: Bool
    let refresh: () -> Void
    var body: some View {
        Button(action: refresh) {
            ZStack { Image(systemName: "arrow.clockwise").opacity(loading ? 0 : 1); if loading { ProgressView().controlSize(.small) } }
        }.disabled(loading).accessibilityLabel(loading ? "Refreshing" : "Refresh")
    }
}
struct FeatureUnavailable: View {
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "info.circle").font(.subheadline.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}
struct ActivityRow: View {
    let event: ActivityEvent
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: StatusTone(event.result.rawValue).symbol).foregroundStyle(StatusTone(event.result.rawValue).color)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.subheadline.weight(.medium))
                Text(event.detail).font(.caption).foregroundStyle(.secondary)
                Text(HumanTime.label(event.date)).font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
    }
}
struct ActivityView: View {
    @EnvironmentObject private var library: HomelabStore
    @State private var clearConfirmation = false
    var body: some View {
        List {
            Section {
                Text("Actions initiated on this iPhone. Server acceptance does not confirm report delivery.").font(.caption).foregroundStyle(.secondary)
            }
            if library.events.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock", description: Text("Confirmed app actions and their results will appear here."))
            } else {
                ForEach(library.events) { ActivityRow(event: $0) }
            }
        }.navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if !library.events.isEmpty { Button("Clear", role: .destructive) { clearConfirmation = true } } } }
        .confirmationDialog("Clear activity on this iPhone?", isPresented: $clearConfirmation, titleVisibility: .visible) {
            Button("Clear local history", role: .destructive) { library.clearHistory() }
        } message: { Text("This removes the local action history. Server records are unaffected.") }
    }
}
