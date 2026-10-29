import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
private final class PresentationFixture: ObservableObject {
    @Published var visible = true
    @Published var phase: ScenePhase = .active
    var identities: [UUID] = []
}
private struct IdentityProbe: View {
    let record: (UUID) -> Void
    @State private var identity = UUID()
    var body: some View { Text("Private fixture").onAppear { record(identity) } }
}
@MainActor
private struct RetentionHarness: View {
    @ObservedObject var fixture: PresentationFixture
    var body: some View {
        RetainedProtectedContent(visible: fixture.visible) {
            IdentityProbe { fixture.identities.append($0) }
        } cover: { Text("Locked").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black) }
    }
}
@MainActor
private struct NavigationHarness: View {
    @ObservedObject var fixture: PresentationFixture
    let api: ServerAPI
    let navigation: OrbitNavigationState
    var body: some View {
        RetainedProtectedContent(visible: fixture.visible) {
            ContentView(api: api, navigation: navigation)
        } cover: { Text("Locked").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black) }
            .environment(\.scenePhase, fixture.phase)
    }
}

@MainActor
final class OrbitPresentationTests: XCTestCase {
    private func window<V: View>(_ content: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        return window
    }
    private func capture(_ window: UIWindow, name: String) {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testPrivacyCoverKeepsTheSameViewIdentityAcrossUnlock() async throws {
        let fixture = PresentationFixture()
        let window = try window(RetentionHarness(fixture: fixture)); defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.identities.count, 1)
        let original = fixture.identities.first
        fixture.visible = false
        try await Task.sleep(for: .milliseconds(150))
        capture(window, name: "retained-content-locked")
        fixture.visible = true
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.identities, original.map { [$0] } ?? [])
    }
    func testBackgroundAndCoverDoNotResetTheSelectedTabOrDeepRoute() async throws {
        let suite = "Orbit.Presentation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        let api = ServerAPI(session: URLSession(configuration: config), defaults: defaults,
            accessAllowed: false, tokenProvider: { "fixture-owner" }, authorize: { _ in XCTFail("No device prompt in a fixture") })
        MockURLProtocol.onStart = nil; MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in XCTFail("Locked views must not request data"); throw URLError(.cancelled) }
        let fixture = PresentationFixture()
        let navigation = OrbitNavigationState(selectedTab: 0, home: [.service(.gemini)])
        let window = try window(NavigationHarness(fixture: fixture, api: api, navigation: navigation))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        fixture.phase = .background; fixture.visible = false
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(navigation.selectedTab, 0); XCTAssertEqual(navigation.homePath.count, 1)
        fixture.phase = .active; fixture.visible = true
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(navigation.selectedTab, 0); XCTAssertEqual(navigation.homePath.count, 1)
        XCTAssertFalse(api.accessAllowed); XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testCompactWindowPanelShowsVerifiedAndUnknownEvidenceOnIPhone() async throws {
        let api = ServerAPI(accessAllowed: true, tokenProvider: { "fixture-owner" }, authorize: { _ in })
        let store = ClasseraWindowStore(fetch: { phone in
            .init(version: 1, phone: phone, whatsappWindows: [
                .init(className: "12F", windowOpen: true, secondsLeft: 3600, lastInboundAt: nil),
                .init(className: "12E", windowOpen: nil, secondsLeft: nil, lastInboundAt: nil)])
        })
        await store.refresh(api: api, phone: "201000000001")
        let window = try window(NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                OrbitVersionLink()
                ClasseraWindowPanel(store: store, classes: ["12F", "12E"], retry: {})
                Text("Subscription and delivery status are separate.").font(.caption)
                Spacer()
            }.padding(16).background(Brand.background).navigationTitle("Student details")
        }.preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        capture(window, name: "compact-window-evidence")
        XCTAssertEqual(store.response?.whatsappWindows[0].windowOpen, true)
        XCTAssertNil(store.response?.whatsappWindows[1].windowOpen)
    }
}
