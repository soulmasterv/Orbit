import SwiftUI

enum WhatsAppPalette {
    static let background = Color.black
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let conversation = Color(red: 0.04, green: 0.06, blue: 0.06)
    static let outgoing = Color(red: 0.075, green: 0.30, blue: 0.215)
    static let accent = Color(red: 0.145, green: 0.827, blue: 0.40)
    static let selectedFilter = Color(red: 0.04, green: 0.20, blue: 0.14)
    static let muted = Color(red: 0.56, green: 0.60, blue: 0.61)
    static let read = Color(red: 0.33, green: 0.74, blue: 0.92)
}

struct WhatsAppAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content.background(WhatsAppPalette.background)
            .environment(\.colorScheme, .dark).tint(WhatsAppPalette.accent)
            .toolbarBackground(WhatsAppPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct WhatsAppFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? WhatsAppPalette.accent : WhatsAppPalette.muted)
                .padding(.horizontal, 15).padding(.vertical, 8)
                .background(selected ? WhatsAppPalette.selectedFilter : WhatsAppPalette.surface, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private enum WhatsAppClock {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
    static func day(_ timestamp: Double) -> String {
        let value = Date(timeIntervalSince1970: timestamp)
        if Calendar.current.isDateInToday(value) { return "Today" }
        if Calendar.current.isDateInYesterday(value) { return "Yesterday" }
        return date.string(from: value)
    }
}

struct WhatsAppAvatar: View {
    let name: String
    var size: CGFloat = 46
    private var initials: String {
        let value = StudentPalette.initials(name)
        return name.allSatisfy({ $0.isNumber || $0 == "+" }) ? "" : value
    }
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.17))
            if initials.isEmpty { Image(systemName: "person.fill").font(.system(size: size * 0.38)) }
            else { Text(initials).font(.system(size: size * 0.34, weight: .semibold)) }
        }
        .foregroundStyle(Color(white: 0.72))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct WhatsAppConnectionLabel: View {
    let connected: Bool?
    private var title: String { connected.map { $0 ? "Connected" : "Disconnected" } ?? "Connecting…" }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(connected == true ? WhatsAppPalette.accent : WhatsAppPalette.muted).frame(width: 5, height: 5)
            Text(title).font(.caption2)
        }.foregroundStyle(WhatsAppPalette.muted)
            .accessibilityLabel("WhatsApp \(title)")
    }
}

struct WhatsAppChatRow: View {
    let chat: OrbitWhatsAppChat
    var body: some View {
        HStack(spacing: 12) {
            WhatsAppAvatar(name: chat.name)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.name).font(.subheadline.weight(chat.unread > 0 ? .bold : .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 5)
                    Text(WhatsAppClock.time.string(from: Date(timeIntervalSince1970: chat.at)))
                        .font(.caption2).foregroundStyle(chat.unread > 0 ? WhatsAppPalette.accent : WhatsAppPalette.muted)
                }
                HStack(alignment: .top, spacing: 10) {
                    Text(chat.latest).font(.subheadline).foregroundStyle(WhatsAppPalette.muted).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if chat.unread > 0 {
                        Text(chat.unread > 99 ? "99+" : String(chat.unread))
                            .font(.caption2.bold()).foregroundStyle(.black)
                            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                            .background(WhatsAppPalette.accent, in: Capsule())
                            .accessibilityLabel("\(chat.unread) unread messages")
                    }
                }
            }
        }.padding(.vertical, 8)
    }
}

struct WhatsAppDateSeparator: View {
    let timestamp: Double
    var body: some View {
        Text(WhatsAppClock.day(timestamp)).font(.caption2.weight(.medium))
            .foregroundStyle(WhatsAppPalette.muted)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(WhatsAppPalette.surface, in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

struct WhatsAppMessageBubble: View {
    let message: OrbitWhatsAppMessage
    var downloading = false
    var openAttachment: (() -> Void)? = nil
    @ViewBuilder private var receipt: some View {
        if ["sent", "delivered", "read"].contains(message.status) {
            HStack(spacing: -5) {
                Image(systemName: "checkmark")
                if message.status != "sent" { Image(systemName: "checkmark") }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(message.status == "read" ? WhatsAppPalette.read : WhatsAppPalette.muted)
            .accessibilityLabel(message.status.capitalized)
        } else {
            Label(message.status == "unknown" ? "Unconfirmed" : message.status.capitalized,
                  systemImage: message.status == "pending" ? "clock" : "exclamationmark.circle")
        }
    }
    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 44) }
            VStack(alignment: .trailing, spacing: 6) {
                if let attachment = message.media {
                    WhatsAppAttachmentCard(attachment: attachment, loading: downloading) { openAttachment?() }
                }
                if !message.text.isEmpty { Text(message.text).font(.body).foregroundStyle(.white).multilineTextAlignment(.leading).textSelection(.enabled) }
                HStack(spacing: 4) {
                    Text(WhatsAppClock.time.string(from: Date(timeIntervalSince1970: message.at)))
                    if message.outgoing {
                        receipt
                    }
                }
                .font(.caption2)
                .foregroundStyle(WhatsAppPalette.muted)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(message.outgoing ? WhatsAppPalette.outgoing : WhatsAppPalette.surface,
                        in: UnevenRoundedRectangle(topLeadingRadius: message.outgoing ? 12 : 3,
                                                   bottomLeadingRadius: 12, bottomTrailingRadius: 12,
                                                   topTrailingRadius: message.outgoing ? 3 : 12))
            .fixedSize(horizontal: false, vertical: true)
            if !message.outgoing { Spacer(minLength: 44) }
        }
    }
}
