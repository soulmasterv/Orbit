import SwiftUI

enum Brand {
    static let accent = Color(red: 0.33, green: 0.65, blue: 1)
    static let teal = Color(red: 0.38, green: 0.82, blue: 0.63)
    static let background = adaptive(light: 0xF3F5F8, dark: 0x080A0D)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x15181E)
    static let raised = adaptive(light: 0xE8EDF3, dark: 0x1C2128)
    static let border = adaptive(light: 0xDCE1E8, dark: 0x292E38)
    static let muted = adaptive(light: 0x536174, dark: 0xA4AEBB)
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct BrandMark: View {
    var size: CGFloat = 44
    var body: some View {
        Image("OrbitLogo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConnectionNotice: View {
    @ObservedObject var api: ServerAPI
    var body: some View {
        if let message = api.errorMessage {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(message).font(.caption)
                    if api.dashboard != nil { Text("Cached snapshot • controls paused").font(.caption2) }
                }
            } icon: { Image(systemName: api.connection == .unauthorized ? "lock.shield" : "wifi.exclamationmark") }
            .foregroundStyle(.orange).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        if let notice = api.actionNotice {
            Label(notice, systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DashboardPlaceholder: View {
    @ObservedObject var api: ServerAPI
    var body: some View {
        VStack(spacing: 16) {
            if api.loading {
                ProgressView().controlSize(.large).tint(Brand.accent)
                Text("Connecting to your server").font(.headline)
                Text("Fetching the latest snapshot…").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Image(systemName: api.hasSavedToken ? "wifi.exclamationmark" : "lock.shield")
                    .font(.system(size: 40)).foregroundStyle(Brand.accent)
                Text(api.hasSavedToken ? "Let's reconnect" : "Your server, at a glance").font(.title3.bold())
                Text(api.errorMessage ?? "Add your server token in Settings to see your server.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if api.hasSavedToken {
                    Button("Try again") { Task { await api.loadDashboard() } }.buttonStyle(.borderedProminent)
                } else {
                    Text("Settings → Server connection").font(.caption.weight(.medium)).foregroundStyle(Brand.accent)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60).padding(.horizontal, 20)
    }
}

extension Double {
    var percentText: String { String(format: "%.1f%%", self) }
    var oneDecimal: String { String(format: "%.1f", self) }
    var boundedPercent: Double { isFinite ? min(max(self, 0), 100) : 0 }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}


