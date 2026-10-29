import SwiftUI

@MainActor
final class ClasseraWindowStore: ObservableObject {
    @Published private(set) var response: ClasseraMessagingResponse?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var receivedAt: Date?
    private(set) var receivedInstant = ContinuousClock.now
    private var generation = 0
    private var flight: (phone: String, task: Task<Void, Never>)?
    private let fetch: ((String) async throws -> ClasseraMessagingResponse)?
    init(fetch: ((String) async throws -> ClasseraMessagingResponse)? = nil) { self.fetch = fetch }
    func clear() {
        generation += 1; flight?.task.cancel(); flight = nil
        response = nil; receivedAt = nil; loading = false; error = nil
    }
    func refresh(api: ServerAPI, phone: String) async {
        guard api.accessAllowed && !Task.isCancelled else { return }
        if let flight, flight.phone == phone { await flight.task.value; return }
        flight?.task.cancel(); generation += 1; let epoch = generation
        if response?.phone != phone { response = nil; receivedAt = nil }
        loading = true; error = nil
        let task = Task { @MainActor in
            defer { if epoch == generation { loading = false; flight = nil } }
            do {
                let result: ClasseraMessagingResponse
                if let fetch { result = try await fetch(phone) }
                else { result = try await api.loadClasseraMessaging(phone: phone) }
                guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
                guard result.version == 1, result.phone == phone,
                      Set(result.whatsappWindows.map(\.className)).count == result.whatsappWindows.count else {
                    throw APIError.message("Window response is incompatible.")
                }
                response = result; receivedAt = Date(); receivedInstant = .now
            } catch {
                guard epoch == generation && api.accessAllowed && !ServerAPI.isRefreshCancellation(error) else { return }
                if let http = error as? HTTPFailure, [401, 403].contains(http.status) {
                    response = nil; self.error = "Authentication failed. Check the Orbit connection before retrying."
                } else if let http = error as? HTTPFailure, http.status == 404 {
                    self.error = "Window data was not found. Refresh the student’s details or retry."
                } else {
                    self.error = "Could not check the WhatsApp window. Retry when connected."
                }
            }
        }
        flight = (phone, task); await task.value
    }
}

struct ClasseraWindowPanel: View {
    @ObservedObject var store: ClasseraWindowStore
    let classes: [String]
    let retry: () -> Void
    private var visibleClasses: [String] {
        let values = Array(Set(classes.filter { ["12F", "12E"].contains($0) } +
            (store.response?.whatsappWindows.map(\.className) ?? []))).sorted()
        return values.isEmpty ? ["12F", "12E"] : values
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("WhatsApp 24-hour window").font(.subheadline.weight(.medium))
                Spacer()
                if store.loading { ProgressView().accessibilityLabel("Checking window") }
            }
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                ForEach(visibleClasses, id: \.self) { klass in
                    let window = store.response?.whatsappWindows.first { $0.className == klass }
                    let seconds = store.error == nil ? window?.remainingSeconds(since: store.receivedInstant) : nil
                    HStack(alignment: .top) {
                        Text(ClasseraClass.title(klass)).foregroundStyle(StudentPalette.secondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(seconds == nil ? Color.orange : seconds! > 0 ? .green : .gray).frame(width: 6, height: 6)
                            Text(store.loading && store.response == nil ? "Checking…" : seconds == nil ? "Unknown" :
                                window?.displayLabel(since: store.receivedInstant, receivedAt: store.receivedAt) ?? "Unknown")
                                .monospacedDigit()
                        }
                    }.font(.caption)
                }
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else if !store.loading && store.response?.whatsappWindows.allSatisfy({ $0.windowOpen == nil }) != false {
                Text("The backend has not returned verified window information. Unknown does not mean closed or allow sending.")
                    .font(.caption).foregroundStyle(StudentPalette.secondary)
            }
            Button(store.error == nil ? "Refresh window" : "Retry window check", action: retry)
                .font(.caption).disabled(store.loading)
            Text("Only verified inbound-message window evidence is used. Subscription and delivery status do not determine this window.")
                .font(.caption2).foregroundStyle(StudentPalette.secondary)
        }.accessibilityIdentifier("classera.student.whatsappWindow")
    }
}
