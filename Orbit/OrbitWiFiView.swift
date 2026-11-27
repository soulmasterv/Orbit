import SwiftUI

struct OrbitWiFiView: View {
    @ObservedObject var api: ServerAPI
    @State private var phone = ""
    var body: some View {
        Form {
            Section {
                NavigationLink { VnStatView(api: api) } label: {
                    Label("Server traffic · vnStat", systemImage: "chart.bar.xaxis")
                }
            }
            Section("Contact Internet Tracker") {
                OrbitPhoneNumberField(prompt: "Contact number", text: $phone, canPick: api.accessAllowed)
                if let normalized = InternetTrackerFormat.phone(phone) {
                    NavigationLink("Internet Tracker") { InternetTrackerView(api: api, phone: normalized) }
                } else {
                    Text("Choose a contact or enter their number.").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!api.accessAllowed)
        .navigationTitle("WiFi").navigationBarTitleDisplayMode(.inline)
    }
}
