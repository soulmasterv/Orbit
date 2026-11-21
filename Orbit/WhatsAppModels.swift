import Foundation
import Combine

enum OrbitWhatsAppPhone {
    static func normalized(_ raw: String) -> String? {
        guard raw.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "+0123456789 ().-").contains($0) }) else { return nil }
        var value = OrbitPhoneNumberField.removingFormatting(raw)
        if value.hasPrefix("00") { value = String(value.dropFirst(2)) }
        if value.hasPrefix("+") { value.removeFirst() }
        return ClasseraPhone.normalized(value)
    }
}

struct OrbitWhatsAppChat: Decodable, Identifiable {
    let id: String
    let name: String
    let latest: String
    let at: Double
    let unread: Int
}
struct OrbitWhatsAppMessage: Decodable, Identifiable {
    let id: String
    let chat: String
    let text: String
    let outgoing: Bool
    let at: Double
    let status: String
    let media: OrbitWhatsAppAttachment?
}
struct OrbitWhatsAppChats: Decodable {
    let connected: Bool
    let chats: [OrbitWhatsAppChat]
}
struct OrbitWhatsAppMessages: Decodable {
    let connected: Bool
    let messages: [OrbitWhatsAppMessage]
}
struct OrbitWhatsAppResult: Decodable {
    let status: String
    let request_id: String?
    let message_id: String?
}
struct OrbitWhatsAppSend: Encodable {
    let request_id: String
    let destination: String
    let text: String
    let media_id: String?
    init(request_id: String, destination: String, text: String, media_id: String? = nil) {
        self.request_id = request_id; self.destination = destination; self.text = text; self.media_id = media_id
    }
}

@MainActor
final class OrbitWhatsAppSubmission: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var pending: OrbitWhatsAppSend?
    @Published private(set) var notice: String?
    private var generation = 0
    func clear() { generation += 1; pending = nil; notice = nil; busy = false }
    func submit(phone: String, text: String, mediaID: String? = nil, send: (OrbitWhatsAppSend) async throws -> OrbitWhatsAppResult) async {
        guard !busy, pending == nil else { return }
        let request = OrbitWhatsAppSend(request_id: UUID().uuidString.lowercased(), destination: phone, text: text, media_id: mediaID)
        pending = request; busy = true; notice = nil
        let epoch = generation
        defer { if epoch == generation { busy = false } }
        do { let result = try await send(request); if epoch == generation { accept(result) } }
        catch { if epoch == generation { notice = "Send unconfirmed. Check status before sending again. Your message will not be resent automatically." } }
    }
    func check(fetch: (String) async throws -> OrbitWhatsAppResult) async {
        guard !busy, let pending else { return }
        busy = true; let epoch = generation
        defer { if epoch == generation { busy = false } }
        do { let result = try await fetch(pending.request_id); if epoch == generation { accept(result) } }
        catch { if epoch == generation { notice = "Status unavailable. Do not resend until you have checked WhatsApp." } }
    }
    private func accept(_ result: OrbitWhatsAppResult) {
        if result.status == "sent", result.request_id == pending?.request_id, result.message_id?.isEmpty == false {
            pending = nil; notice = "Sent. Delivery and read status appear when reported by WhatsApp."
        } else {
            notice = "Send unconfirmed. Check WhatsApp before sending again. No automatic resend."
        }
    }
}
