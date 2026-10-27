import SwiftUI

enum ServicePage: String, CaseIterable, Identifiable, Codable {
    case gemini, classera, padel
    var id: String { rawValue }
    var title: String { self == .gemini ? "Gemini Monitor" : rawValue.capitalized }
    var symbol: String { switch self { case .gemini: return "sparkles"; case .classera: return "graduationcap"; case .padel: return "sportscourt" } }
}
struct ServiceDetailView: View {
    @ObservedObject var api: ServerAPI
    let page: ServicePage
    @State private var pending: ServiceCommand?
    @State private var recipientSheet: ClasseraRecipientSheetTarget?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Label(page.title, systemImage: page.symbol).font(.headline); Spacer(); StatusBadge(status: api.serviceStatus(page)) }
                        Text(api.serviceSummary(page)).font(.subheadline).foregroundStyle(.secondary)
                        if page == .gemini, let health = api.serviceSnapshot?.geminiHealth { HStack { Text("Monitor").font(.caption).foregroundStyle(.secondary); StatusBadge(status: health) } }
                        SnapshotStamp(date: api.servicesUpdatedAt, failed: api.servicesError != nil)
                    }
                }
                if let error = api.servicesError { Label(error, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                if api.serviceSnapshot == nil {
                    FeatureUnavailable(title: api.servicesLoading ? "Loading service health" : "Service data unavailable", message: "The authenticated backend must report this integration. Refresh to check again.")
                } else { serviceContent }
            }.padding(16)
        }.background(Brand.background).navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { FavoriteButton(target: .service(page)) }
            ToolbarItem(placement: .topBarTrailing) { RefreshIndicator(loading: api.servicesLoading) { Task { await api.loadServices() } } }
        }
        .task { await api.ensureServicesFresh() }.refreshable { await api.loadServices() }
        .sheet(item: $recipientSheet) { target in
            ClasseraRecipientSheet(api: api, target: target)
        }
        .confirmationDialog(
            pending?.title ?? "Confirm",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { command in

            switch command.kind {
            case .testGeminiKey:
                Button("Test \(command.name)") {
                    Task {
                        await api.serviceAction(command)
                    }
                }

            case .fireClasseraReport:
                Button("Send report for \(command.name)") {
                    Task {
                        await api.serviceAction(command)
                    }
                }

            case .forceFireClasseraReport, .forceOneClasseraReport:
                Button(
                    "Force send for \(command.name)",
                    role: .destructive
                ) {
                    Task {
                        await api.serviceAction(command)
                    }
                }
            }

            Button("Cancel", role: .cancel) {}

        } message: {
            Text($0.explanation)
        }
    }
    @ViewBuilder private var serviceContent: some View {
        switch page {
        case .gemini:
            let keys = api.serviceSnapshot?.gemini ?? []
            if keys.isEmpty { FeatureUnavailable(title: "No key status", message: "The monitor has not reported key health.") }
            ForEach(keys) { key in
                Panel {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(safeGeminiName(key)).font(.subheadline.weight(.semibold)); Spacer()
                            StatusBadge(status: key.status)
                            if reason(key.canTest) == nil { Button("Test") { pending = ServiceCommand(kind: .testGeminiKey, id: key.id, name: safeGeminiName(key)) }.font(.subheadline).frame(minWidth: 44, minHeight: 44) }
                        }
                        HStack { Text("Auth \(HumanTime.label(key.lastAuthenticationCheck))"); Spacer(); Text("Generation \(HumanTime.label(key.lastGenerationCheck))") }.font(.caption).foregroundStyle(.secondary)
                        if let why = reason(key.canTest) { Text("Test unavailable: \(why)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        case .classera:
            NavigationLink { ClasseraMonitoringView(api: api) } label: {
                Label("Waiting list, delivery history & statistics", systemImage: "chart.bar.xaxis")
            }.font(.subheadline.weight(.semibold))
            let instances = (api.serviceSnapshot?.classera ?? []).filter { ["classera-1", "classera-2"].contains($0.id) }

            if instances.isEmpty {
                FeatureUnavailable(
                    title: "No Classera status",
                    message: "Scheduler and report information has not been reported."
                )
            }

            ForEach(instances) { service in
                Panel {
                    VStack(alignment: .leading, spacing: 10) {

                        HStack {
                            Text(service.displayName)
                                .font(.headline)

                            Spacer()

                            StatusBadge(status: service.status)
                        }

                        HStack {
                            componentState(
                                "Scheduler",
                                service.schedulerStatus
                            )

                            Spacer()

                            componentState(
                                "Webhook",
                                service.webhookStatus
                            )
                        }

                        HStack {
                            timeRow(
                                "Last run",
                                service.lastRun
                            )

                            Spacer()

                            timeRow(
                                "Last report",
                                service.lastReport
                            )
                        }

                        if let reportName = service.lastReportName,
                           !reportName.isEmpty {

                            Label(
                                reportName,
                                systemImage: "doc.text"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        }

                        if let cache = service.aiCache {

                            HStack {
                                Label(
                                    "\(cache.count ?? 0) recent AI caches",
                                    systemImage: "brain"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                Spacer()

                                if let latest = cache.recent?.first?.updatedAt {
                                    Text(HumanTime.label(latest))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        classeraDelivery(service)

                        if let assessments = service.upcomingAssessments,
                           !assessments.isEmpty {

                            Divider()

                            Text("Upcoming FFs")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(
                                Array(assessments.prefix(3))
                            ) { assessment in

                                HStack(
                                    alignment: .top,
                                    spacing: 8
                                ) {

                                    Image(
                                        systemName: "calendar"
                                    )
                                    .foregroundStyle(
                                        Brand.accent
                                    )

                                    VStack(
                                        alignment: .leading,
                                        spacing: 2
                                    ) {

                                        Text(
                                            assessment.label
                                        )
                                        .font(
                                            .caption.weight(
                                                .medium
                                            )
                                        )

                                        HStack(spacing: 6) {
                                            Text(
                                                assessment.date
                                            )

                                            if let week = assessment.week {
                                                Text(
                                                    "Week \(week)"
                                                )
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(
                                            .secondary
                                        )
                                    }

                                    Spacer()
                                }
                            }
                        }

                        Divider()

                        if let why = reason(service.canFire) {

                            Label(
                                "Send unavailable: \(why)",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        } else {

                            Button {
                                pending = ServiceCommand(
                                    kind: .fireClasseraReport,
                                    id: service.id,
                                    name: service.displayName
                                )
                            } label: {
                                Label(
                                    "Send Now",
                                    systemImage: "paperplane"
                                )
                                .font(
                                    .subheadline.weight(
                                        .medium
                                    )
                                )
                                .frame(minHeight: 44)
                            }
                        }

                        if let why = reason(
                            service.canForceFire
                        ) {

                            Text(
                                "Force send unavailable: \(why)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        } else {

                            Button(role: .destructive) {

                                pending = ServiceCommand(
                                    kind: .forceFireClasseraReport,
                                    id: service.id,
                                    name: service.displayName
                                )

                            } label: {

                                Label(
                                    "Force Send",
                                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                                )
                                .font(
                                    .subheadline.weight(
                                        .medium
                                    )
                                )
                                .frame(minHeight: 44)
                            }
                        }
                        ClasseraRecipientsPreview(api: api, identifier: service.id)
                        NavigationLink { ClasseraStudentsView(api: api) } label: {
                            Label("Manage subscribers", systemImage: "person.2").frame(minHeight: 44)
                        }
                        Button(role: .destructive) {
                            recipientSheet = ClasseraRecipientSheetTarget(service: service, forceOne: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Force Send to Person", systemImage: "person.crop.circle.badge.exclamationmark")
                                Text("ONE PERSON ONLY").font(.caption.weight(.semibold))
                            }.frame(minHeight: 44)
                        }
                        .disabled(reason(service.canForceFire) != nil)
                    }
                }
            }
        case .padel:
            let components = api.serviceSnapshot?.padel ?? []
            if components.isEmpty { FeatureUnavailable(title: "No Padel status", message: "Application and delivery health has not been reported.") }
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(components) { component in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Label(component.name.replacingOccurrences(of: "Padel ", with: ""), systemImage: component.isWhatsApp ? "message" : "server.rack").font(.subheadline.weight(.medium)); Spacer(); StatusBadge(status: component.status) }
                            if component.isWhatsApp {
                                HStack { Text("Delivery / billing").font(.caption).foregroundStyle(.secondary); Spacer(); StatusBadge(status: component.deliveryStatus ?? "Unknown") }
                                Text("Delivery can fail while the application remains online.").font(.caption).foregroundStyle(.secondary)
                            }
                            if component.lastNotification != nil { Text("Last notification: \(HumanTime.label(component.lastNotification))").font(.caption).foregroundStyle(.secondary) }
                        }
                        if component.id != components.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func classeraDelivery(_ service: ClasseraStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Label("WhatsApp delivery", systemImage: "message").font(.caption.weight(.semibold))
                Spacer()
                StatusBadge(status: service.whatsappStatus ?? "Unknown")
            }
            if service.whatsappStatus == "No tracked sends" {
                Text("No tracked sends yet. Delivery tracking will populate after the next Classera report.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                deliveryCount("Accepted", service.acceptedCount)
                deliveryCount("Sent", service.sentCount)
                deliveryCount("Delivered", service.deliveredCount)
                deliveryCount("Read", service.readCount)
                deliveryCount("Failed", service.failedCount)
                deliveryCount("Unknown", service.unknownCount)
            }
            timeRow("Latest delivery", service.latestDeliveryAt)
            if let report = service.latestDeliveryReport, !report.isEmpty {
                Label(report, systemImage: "doc.text").font(.caption)
                    .foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func deliveryCount(_ title: String, _ count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(count.map { String($0) } ?? "—").monospacedDigit()
        }.font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func safeGeminiName(_ key: GeminiKeyStatus) -> String {
        // Never render monitor-provided names that could contain an actual key.
        let suffix = key.id.replacingOccurrences(of: "key-", with: "")
        return Int(suffix).map { (1...1000).contains($0) ? "Gemini \($0)" : "Gemini key" } ?? "Gemini key"
    }
    private func reason(_ capable: Bool?) -> String? {
        if capable != true { return "not enabled by the backend" }
        if api.actionBusy { return "another action is in progress" }
        if api.servicesLoading { return "checking the latest status" }
        if api.servicesError != nil { return "service status needs verification" }
        if !api.canControl { return "refresh and authenticate your connection" }
        return nil
    }
    private func componentState(_ title: String, _ state: String?) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); StatusBadge(status: state ?? "Unknown") } }
    private func timeRow(_ title: String, _ date: String?) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(HumanTime.label(date)).font(.caption.weight(.medium)) } }
}

private struct ClasseraRecipientsPreview: View {
    @ObservedObject var api: ServerAPI
    let identifier: String
    @State private var recipients: [String]?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Active recipients").font(.subheadline.weight(.semibold))
            if let recipients {
                if recipients.isEmpty { Text("No active subscriptions for this class.").font(.caption).foregroundStyle(.secondary) }
                ForEach(recipients, id: \.self) { phone in Text(phone).font(.caption).monospacedDigit().textSelection(.enabled) }
            } else if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            else { ProgressView("Loading recipients…") }
        }
        .task(id: api.servicesUpdatedAt) {
            recipients = nil; error = nil
            do { let result = try await api.loadClasseraRecipients(id: identifier); if !Task.isCancelled { recipients = result } }
            catch { if !ServerAPI.isRefreshCancellation(error) { self.error = "Recipients unavailable. Refresh to try again." } }
        }
        .onChange(of: api.accessAllowed) { _, allowed in if !allowed { recipients = nil } }
    }
}

private struct ClasseraRecipientSheetTarget: Identifiable {
    let service: ClasseraStatus
    let forceOne: Bool
    var id: String { service.id + (forceOne ? "-force-one" : "-edit") }
}

private struct RecipientDraft: Identifiable {
    let id = UUID()
    var number: String
}

private struct ClasseraRecipientSheet: View {
    @ObservedObject var api: ServerAPI
    let target: ClasseraRecipientSheetTarget
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [RecipientDraft] = []
    @State private var selected = ""
    @State private var loading = true
    @State private var saving = false
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmOne = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(target.service.displayName).font(.headline)
                    if target.forceOne {
                        Text("ONE PERSON ONLY").font(.headline).foregroundStyle(.orange)
                        Text("Choose one configured recipient. No other recipient will receive this force-send request.")
                    } else {
                        Text("Use digits only, including the country code.")
                    }
                }
                if loading { ProgressView("Loading recipients…") }
                if let error { Text(error).foregroundStyle(.orange) }
                if !loading && loaded {
                    if target.forceOne {
                        Section("Select one recipient") {
                            if drafts.isEmpty { Text("No recipients configured. Add a number using Edit Recipients first.") }
                            ForEach(drafts) { draft in
                                Button { selected = draft.number } label: {
                                    HStack {
                                        Text(draft.number).foregroundStyle(.primary)
                                        Spacer()
                                        if selected == draft.number { Image(systemName: "checkmark.circle.fill") }
                                    }
                                }
                            }
                        }
                        Section {
                            Button("Force Send to ONE PERSON ONLY", role: .destructive) { confirmOne = true }
                                .disabled(selected.isEmpty || saving || !api.canControl)
                        }
                    } else {
                        Section("Configured numbers") {
                            ForEach($drafts) { $draft in
                                HStack {
                                    TextField("Phone number", text: $draft.number).keyboardType(.numberPad)
                                        .accessibilityLabel("Recipient phone number")
                                    Button(role: .destructive) { drafts.removeAll { $0.id == draft.id } } label: {
                                        Image(systemName: "minus.circle")
                                    }.accessibilityLabel("Remove recipient").buttonStyle(.borderless)
                                }
                            }
                            Button("Add number") { drafts.append(RecipientDraft(number: "")) }
                        }.disabled(saving)
                        Section {
                            Button(saving ? "Saving…" : "Save Recipients") { Task { await save() } }
                                .disabled(saving || !api.canControl)
                        }
                    }
                }
            }
            .navigationTitle(target.forceOne ? "Force Send to Person" : "Edit Recipients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
            .task {
                do {
                    let numbers = try await api.loadClasseraRecipients(id: target.service.id)
                    drafts = numbers.map { RecipientDraft(number: $0) }
                    loaded = true
                } catch { self.error = api.friendly(error) }
                loading = false
            }
            .confirmationDialog("Send to ONE PERSON ONLY?", isPresented: $confirmOne, titleVisibility: .visible) {
                Button("Force send to \(selected) only", role: .destructive) {
                    let command = ServiceCommand(kind: .forceOneClasseraReport, id: target.service.id,
                                                 name: target.service.displayName, recipient: selected)
                    Task {
                        saving = true
                        api.actionError = nil
                        await api.serviceAction(command)
                        saving = false
                        if let failure = api.actionError { error = failure }
                        else { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This sends a real WhatsApp report to \(selected) ONLY and can resend a previously delivered report. Device authorization is required next.")
            }
        }.interactiveDismissDisabled(saving)
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await api.saveClasseraRecipients(id: target.service.id, recipients: drafts.map(\.number))
            dismiss()
        } catch { self.error = api.friendly(error) }
    }
}


