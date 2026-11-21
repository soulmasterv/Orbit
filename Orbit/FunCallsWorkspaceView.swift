import SwiftUI

struct FunCallsWorkspaceView: View {
    @ObservedObject var api: ServerAPI
    @EnvironmentObject private var mobile: MobileStore
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = JarvisSession(voiceEnabled: false)
    @State private var connection: JarvisAppConnection?

    var body: some View {
        ZStack {
            // Reuse the persistent authenticated JARVIS session for Controls.
            // Voice capture is disabled for this native-only workspace.
            JarvisWebView(session: session)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if connection?.connected == true, session.signedIn {
                JarvisFunCallsView(api: api, session: session, submission: session.funCalls, embedded: true)
            } else {
                VStack(spacing: 14) {
                    if connection == nil || connection?.busy == true || session.loading {
                        ProgressView("Connecting securely…")
                    } else {
                        Text(connection?.message ?? session.notice ?? "Connect to use Fun calls.")
                            .multilineTextAlignment(.center)
                        Button("Reconnect") { Task { await connection?.connect() } }
                    }
                }.padding()
            }
        }
        .navigationTitle("Fun calls")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard connection == nil else { return }
            let web = session.makeWebView(loadInitialPage: false)
            let next = JarvisAppConnection(
                cookies: JarvisWebKitCookies(web.configuration.websiteDataStore.httpCookieStore),
                makeBroker: { try api.makeVerifiedJarvisBroker() },
                installation: { try mobile.jarvisInstallationID() },
                allowed: { api.accessAllowed && phase == .active },
                stop: { [weak session] in session?.hideAppContent() },
                navigate: { [weak session] url in session?.activate(); session?.loadAppSession(url) })
            connection = next
            session.appConnection = next
            await next.connect()
        }
        .onDisappear { connection?.suspend(); session.detach() }
        .onChange(of: api.accessAllowed) { _, allowed in
            if !allowed { connection?.suspend() }
        }
        .onChange(of: phase) { _, next in
            if next == .background { connection?.suspend(); session.stop(background: true) }
            else if next == .active { session.activate() }
        }
    }
}
