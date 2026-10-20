import XCTest
import WebKit
@testable import Orbit

final class JarvisPolicyTests: XCTestCase {
    func testKnownAccessLoginNeverBecomesContentOrCaptureOrigin() {
        let login = URL(string: "https://quiet-sky-4b47.cloudflareaccess.com/cdn-cgi/access/login/jarvis.labbing.space?token=private")!
        XCTAssertTrue(JarvisPolicy.isAccessLogin(login))
        XCTAssertFalse(JarvisPolicy.isOrigin(login))
        XCTAssertFalse(JarvisPolicy.isCaptureOrigin(protocol: "https", host: JarvisPolicy.accessHost, port: 443))
        for value in ["http://quiet-sky-4b47.cloudflareaccess.com/cdn-cgi/access/login/", "https://quiet-sky-4b47.cloudflareaccess.com.evil.example/cdn-cgi/access/login/", "https://quiet-sky-4b47.cloudflareaccess.com:8443/cdn-cgi/access/login/", "https://user:pass@quiet-sky-4b47.cloudflareaccess.com/cdn-cgi/access/login/", "https://quiet-sky-4b47.cloudflareaccess.com/other", "https://another.cloudflareaccess.com/cdn-cgi/access/login/"] {
            XCTAssertFalse(JarvisPolicy.isAccessLogin(URL(string: value)), value)
        }
    }
    func testErrorMessagesNeverIncludePrivateURLValues() {
        let e = NSError(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "private-token", NSURLErrorFailingURLStringErrorKey: "https://example.test/?secret=private-token"])
        XCTAssertTrue(JarvisPolicy.loadFailure(e)?.contains("timed out") == true)
        XCTAssertFalse(JarvisPolicy.loadFailure(e)?.contains("private-token") == true)
        XCTAssertNil(JarvisPolicy.loadFailure(URLError(.cancelled)))
    }
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
        gate.update(version: 1, authenticated: true); gate.arm(); let priorLoginAttempt = gate.consume()!
        gate.update(version: 1, authenticated: false)
        XCTAssertNil(gate.consume())
        gate.update(version: 1, authenticated: true)
        XCTAssertFalse(gate.permits(priorLoginAttempt), "Signing in again must not revive a previous permission request")
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

