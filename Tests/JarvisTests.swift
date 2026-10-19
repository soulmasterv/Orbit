import XCTest
import WebKit
@testable import ServerControl

final class JarvisPolicyTests: XCTestCase {
    func testOnlyExactHTTPSOriginIsEmbedded() {
        for value in ["https://jarvis.labbing.space/", "https://jarvis.labbing.space:443/memory?view=1"] {
            XCTAssertTrue(JarvisPolicy.isOrigin(URL(string: value)))
        }
        for value in ["http://jarvis.labbing.space/", "https://jarvis.labbing.space:8001/", "https://jarvis.labbing.space.evil.example/",
                      "https://evil.example/?jarvis.labbing.space", "https://user:password@jarvis.labbing.space/",
                      "https://accounts.google.com/", "https://quiet-sky-4b47.cloudflareaccess.com/", "file:///memory", "javascript:alert(1)"] {
            XCTAssertFalse(JarvisPolicy.isOrigin(URL(string: value)), value)
        }
        XCTAssertFalse(JarvisPolicy.isOrigin(nil))
    }
    func testCaptureOriginRejectsOtherPortsAndProtocols() {
        XCTAssertTrue(JarvisPolicy.isCaptureOrigin(protocol: "https", host: "jarvis.labbing.space", port: 443))
        XCTAssertTrue(JarvisPolicy.isCaptureOrigin(protocol: "https", host: "jarvis.labbing.space", port: 0))
        XCTAssertFalse(JarvisPolicy.isCaptureOrigin(protocol: "http", host: "jarvis.labbing.space", port: 443))
        XCTAssertFalse(JarvisPolicy.isCaptureOrigin(protocol: "https", host: "jarvis.labbing.space", port: 8001))
        XCTAssertFalse(JarvisPolicy.isCaptureOrigin(protocol: "https", host: "photos.labbing.space", port: 443))
    }
    func testPermissionRequiresCompatibleAuthenticatedForegroundUserTap() {
        var gate = JarvisCaptureGate()
        gate.activate(); gate.arm(); XCTAssertNil(gate.consume())
        gate.update(version: 0, authenticated: true); gate.arm(); XCTAssertNil(gate.consume())
        gate.update(version: 1, authenticated: false); gate.arm(); XCTAssertNil(gate.consume())
        gate.update(version: 1, authenticated: true); XCTAssertNil(gate.consume())
        gate.arm(); let attempt = gate.consume(); XCTAssertNotNil(attempt)
        XCTAssertTrue(gate.permits(attempt!)); XCTAssertNil(gate.consume(), "Gesture is single use")
    }
    func testStopInvalidatesPendingPermissionAndNeverRearms() {
        var gate = JarvisCaptureGate(); gate.activate(); gate.update(version: 1, authenticated: true); gate.arm()
        let pending = gate.consume()!
        gate.stop(); XCTAssertFalse(gate.permits(pending)); XCTAssertNil(gate.consume())
        gate.arm(); let next = gate.consume()!; gate.stop(background: true)
        XCTAssertFalse(gate.permits(next)); gate.arm(); XCTAssertNil(gate.consume())
        gate.activate(); XCTAssertNil(gate.consume(), "Returning never starts capture")
    }
    func testNavigationAndSignOutInvalidateCaptureCompatibility() {
        var gate = JarvisCaptureGate(); gate.activate(); gate.update(version: 1, authenticated: true); gate.arm()
        let attempt = gate.consume()!; gate.resetDocument()
        XCTAssertFalse(gate.permits(attempt)); XCTAssertFalse(gate.ready)
        gate.arm(); XCTAssertNil(gate.consume())
        gate.update(version: 1, authenticated: true); gate.arm(); gate.update(version: 1, authenticated: false)
        XCTAssertNil(gate.consume())
    }
}

@MainActor
final class JarvisConfigurationTests: XCTestCase {
    func testWebKitConfigurationKeepsCookiesAndRequiresUserGesture() {
        let session = JarvisSession(); let web = session.makeWebView(loadInitialPage: false)
        XCTAssertTrue(web.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(web.configuration.allowsInlineMediaPlayback)
        XCTAssertEqual(web.configuration.mediaTypesRequiringUserActionForPlayback, .all)
        XCTAssertEqual(web.configuration.userContentController.userScripts.count, 1)
        XCTAssertTrue(web.configuration.userContentController.userScripts[0].isForMainFrameOnly)
        XCTAssertFalse(web.isInspectable)
        session.detach()
    }
    func testMicrophonePurposePresentWithoutATSBypass() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertFalse((info["NSMicrophoneUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertNil(info["NSAppTransportSecurity"])
        XCTAssertNil(info["NSCameraUsageDescription"])
    }
}
