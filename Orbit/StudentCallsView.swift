import SwiftUI

struct StudentCallsView: View {
    @ObservedObject var api: ServerAPI

    var body: some View {
        List {
            NavigationLink {
                FunCallsWorkspaceView(api: api)
            } label: {
                Label("Fun calls", systemImage: "phone.fill")
            }
            .disabled(!api.accessAllowed)
            .accessibilityIdentifier("students.funCalls")
            NavigationLink {
                OrbitDiaaFriendsView(api: api)
            } label: {
                Label("Allowed Callers", systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(!api.accessAllowed)
        }
        .scrollContentBackground(.hidden)
        .background(StudentPalette.background)
        .navigationTitle("Orbit")
        .navigationBarTitleDisplayMode(.inline)
    }
}
