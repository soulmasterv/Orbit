import SwiftUI

struct FunCallsWorkspaceView: View {
    @ObservedObject var api: ServerAPI
    // Presentation state only; no web view, handshake or microphone.
    @StateObject private var session = JarvisSession(voiceEnabled: false)
    @StateObject private var submission = JarvisFunCallSubmission()
    var body: some View {
        JarvisFunCallsView(api: api, session: session, submission: submission, embedded: true, nativeTransport: true)
    }
}
