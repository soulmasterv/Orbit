import SwiftUI

struct CompactWorkspaceRow: View {
    let title: String
    let subtitle: String
    var divider = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Brand.muted)
            }.padding(.vertical, 14).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        }.padding(.horizontal, 12)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Brand.border, lineWidth: 1) }
            .contentShape(Rectangle())
    }
}

struct CompactServicesOverview: View {
    @ObservedObject var api: ServerAPI
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Application health and delivery health").font(.caption).foregroundStyle(Brand.muted)
                ForEach(ServicePage.allCases) { page in
                    NavigationLink { ServiceDetailView(api: api, page: page) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            CompactWorkspaceRow(title: page.title, subtitle: api.serviceSummary(page))
                            StatusBadge(status: api.serviceStatus(page))
                        }
                    }.buttonStyle(.plain)
                }
                SnapshotStamp(date: api.servicesUpdatedAt, failed: api.servicesError != nil)
                if let error = api.servicesError { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(16)
        }.background(Brand.background).navigationTitle("Services").navigationBarTitleDisplayMode(.inline)
            .task { await api.ensureServicesFresh() }.refreshable { await api.loadServices() }
    }
}
