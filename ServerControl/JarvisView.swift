import SwiftUI
import WebKit
import AVFoundation
import Network

@MainActor
final class JarvisSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published private(set) var ready = false
    @Published private(set) var signedIn = false
    @Published private(set) var microphoneActive = false
    @Published private(set) var loading = true
    @Published private(set) var notice: String?
    @Published private(set) var memoryAvailable = false
    private(set) var webView: WKWebView?
    private var gate = JarvisCaptureGate()
    private var microphoneObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private let monitor = NWPathMonitor()
    private var alertCompletion: ((Bool) -> Void)?
    @Published var confirmation: String?

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            if began { Task { @MainActor in self?.stop("Audio interrupted. Tap Start voice when ready.") } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
                Task { @MainActor in
                    guard self?.microphoneActive == true else { return }
                    self?.stop("Audio device changed. Check your headphones, then tap Start voice.")
                }
            }
        })
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status != .satisfied { Task { @MainActor in self?.stop("Network unavailable. Reconnect, then tap Start voice.") } }
        }
        monitor.start(queue: DispatchQueue(label: "Orbit.Jarvis.Network"))
    }

    deinit {
        monitor.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func makeWebView(loadInitialPage: Bool = true) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // HttpOnly login cookies remain in WebKit, never copied into Swift.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.applicationNameForUserAgent = "OrbitJARVIS/1"
        config.userContentController.add(WeakJarvisHandler(self), name: "jarvisState")
        config.userContentController.addUserScript(WKUserScript(source: Self.bootstrap, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self
        web.isInspectable = false
        web.allowsBackForwardNavigationGestures = false
        webView = web
        microphoneObservation = web.observe(\.microphoneCaptureState, options: [.initial, .new]) { [weak self] view, _ in
            let active = view.microphoneCaptureState == .active
            Task { @MainActor in self?.microphoneActive = active }
        }
        if loadInitialPage { web.load(URLRequest(url: JarvisPolicy.home, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)) }
        return web
    }

    func activate() {
        gate.activate()
        webView?.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        // Activation never starts recording or replays a voice session.
    }

    func stop(_ message: String? = nil, background: Bool = false) {
        gate.stop(background: background)
        microphoneActive = false
        if let message { notice = message }
        if let web = webView {
            if JarvisPolicy.isOrigin(web.url) {
                web.evaluateJavaScript("window.orbitJarvis?.version === 1 && window.orbitJarvis.stop()", completionHandler: nil)
            }
            web.setMicrophoneCaptureState(.none, completionHandler: nil)
            web.pauseAllMediaPlayback(completionHandler: nil)
            if background { web.setAllMediaPlaybackSuspended(true, completionHandler: nil) }
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if background { finishConfirmation(false) }
    }

    func detach() {
        stop(background: true)
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "jarvisState")
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        // Replacing the document also discards any pending JS initialization.
        webView?.loadHTMLString("", baseURL: nil)
        microphoneObservation = nil; webView = nil
    }

    func reload() {
        stop(); gate.resetDocument(); ready = false; signedIn = false; memoryAvailable = false
        notice = nil; loading = true
        webView?.load(URLRequest(url: JarvisPolicy.home, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    func showMemory() {
        guard ready, signedIn, memoryAvailable, let web = webView, JarvisPolicy.isOrigin(web.url) else { return }
        stop()
        web.evaluateJavaScript("document.getElementById('memory-panel')?.scrollIntoView({behavior:'smooth',block:'start'})", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, JarvisPolicy.isOrigin(message.frameInfo.request.url),
              JarvisPolicy.isOrigin(webView?.url), let body = message.body as? [String: Any] else { return }
        if body["kind"] as? String == "startTap" {
            gate.arm()
            if gate.armed { notice = nil }
            return
        }
        guard body["kind"] as? String == "state", let version = body["version"] as? Int else { return }
        let authenticated = body["authenticated"] as? Bool ?? false
        gate.update(version: version, authenticated: authenticated)
        ready = gate.ready; signedIn = authenticated
        memoryAvailable = ready && body["memoryAvailable"] as? Bool == true
        if body["phase"] as? String == "idle" {
            // Web Stop/sign-out must invalidate an OS permission prompt that is still pending too.
            gate.stop()
            webView?.setMicrophoneCaptureState(.none, completionHandler: nil)
            webView?.pauseAllMediaPlayback(completionHandler: nil)
        }
        if !ready {
            notice = "JARVIS needs the supplied frontend update before voice can run safely in Orbit."
            webView?.setMicrophoneCaptureState(.none, completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard type == .microphone, frame.isMainFrame, JarvisPolicy.isOrigin(webView.url),
              JarvisPolicy.isOrigin(frame.request.url),
              JarvisPolicy.isCaptureOrigin(protocol: origin.protocol, host: origin.host, port: origin.port),
              let attempt = gate.consume() else { decisionHandler(.deny); return }
        AVAudioApplication.requestRecordPermission { [weak self, weak webView] granted in
            Task { @MainActor in
                guard let self, let webView, self.webView === webView, granted, self.gate.permits(attempt),
                      JarvisPolicy.isOrigin(webView.url) else {
                    if !granted { self?.notice = "Microphone denied. Enable Orbit’s microphone access in iPhone Settings." }
                    decisionHandler(.deny); return
                }
                do {
                    let audio = AVAudioSession.sharedInstance()
                    try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
                    try audio.setActive(true)
                    decisionHandler(.grant)
                } catch {
                    self.notice = "Audio is unavailable. Check your headphones or another active call."
                    decisionHandler(.deny)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if JarvisPolicy.isOrigin(action.request.url) {
            if action.targetFrame?.isMainFrame != false { stop(); gate.resetDocument() }
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        stop("Navigation outside JARVIS was blocked. Open external links in your browser.")
        if action.navigationType == .linkActivated, let url = action.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
        }
        // No Cloudflare/Google destinations are allowed implicitly. Add only a verified login flow.
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as? URLError)?.code != .cancelled else { return }
        loading = false; stop("JARVIS could not load. Check your network or server, then Reload.")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; gate.resetDocument(); stop("JARVIS was interrupted. Reload and start a new conversation.")
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard frame.isMainFrame, JarvisPolicy.isOrigin(frame.request.url), JarvisPolicy.isOrigin(webView.url), gate.foreground else {
            completionHandler(false); return
        }
        stop(); finishConfirmation(false)
        alertCompletion = completionHandler
        confirmation = String(message.prefix(300))
    }
    func finishConfirmation(_ confirmed: Bool) {
        let callback = alertCompletion; alertCompletion = nil; confirmation = nil; callback?(confirmed)
    }

    static let bootstrap = #"""
    (() => {
      if (location.origin !== 'https://jarvis.labbing.space') return;
      const bridge = window.webkit.messageHandlers.jarvisState;
      function report() {
        const api = window.orbitJarvis;
        const ready = api?.version === 1;
        const s = ready ? api.snapshot() : {};
        const start = document.getElementById('start');
        if (!ready && start) start.disabled = true;
        bridge.postMessage({kind:'state',version:ready?1:0,authenticated:s.authenticated===true,memoryAvailable:s.memoryAvailable===true,phase:s.phase==='starting'?'starting':s.phase==='listening'?'listening':'idle'});
      }
      document.addEventListener('click', e => {
        if (e.isTrusted && e.target.closest?.('#start') && window.orbitJarvis?.version === 1) bridge.postMessage({kind:'startTap'});
      }, true);
      window.addEventListener('orbit-jarvis-state', report);
      new MutationObserver(() => {
        if (window.orbitJarvis?.version !== 1) {
          const start = document.getElementById('start');
          if (start && !start.disabled) start.disabled = true;
        }
      }).observe(document.documentElement,{subtree:true,attributes:true,attributeFilter:['disabled']});
      report();
    })();
    """#
}

@MainActor
private final class WeakJarvisHandler: NSObject, WKScriptMessageHandler {
    weak var session: JarvisSession?
    init(_ session: JarvisSession) { self.session = session }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.userContentController(userContentController, didReceive: message)
    }
}

private struct JarvisWebView: UIViewRepresentable {
    @ObservedObject var session: JarvisSession
    func makeCoordinator() -> JarvisSession { session }
    func makeUIView(context: Context) -> WKWebView { session.makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: JarvisSession) {
        coordinator.detach()
    }
}

struct JarvisView: View {
    @StateObject private var session = JarvisSession()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(session.microphoneActive ? "Microphone active" : "Microphone off", systemImage: session.microphoneActive ? "mic.fill" : "mic.slash")
                        .font(.subheadline).foregroundStyle(session.microphoneActive ? .green : .secondary)
                    Spacer()
                    Button("Stop") { session.stop("Stopped. Microphone released.") }.buttonStyle(.bordered)
                }
                if let notice = session.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                Text("Tap Start voice below to begin. Use headphones. Nothing starts automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            if session.loading { ProgressView().padding(6) }
            JarvisWebView(session: session)
        }
        .background(Brand.background).navigationTitle("JARVIS").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { session.showMemory() } label: { Image(systemName: "brain") }.accessibilityLabel("Memory")
                    .disabled(!session.signedIn || !session.memoryAvailable)
                Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload JARVIS")
            }
        }
        .alert("Confirm memory deletion", isPresented: Binding(get: { session.confirmation != nil }, set: { if !$0 { session.finishConfirmation(false) } })) {
            Button("Cancel", role: .cancel) { session.finishConfirmation(false) }
            Button("Delete", role: .destructive) { session.finishConfirmation(true) }
        } message: { Text(session.confirmation ?? "") }
        .onAppear { if phase == .active { session.activate() } }
        .onDisappear { session.detach() }
        .onChange(of: phase) { _, value in
            if value == .background { session.stop("Paused in background. Tap Start voice when ready.", background: true) }
            else if value == .active { session.activate() }
        }
    }
}
