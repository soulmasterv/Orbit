import XCTest
@testable import Orbit

@MainActor
final class JarvisBootstrapTests: XCTestCase {
    nonisolated private static let instant = Date(timeIntervalSince1970: Double(Int(Date().timeIntervalSince1970)))
    private let installation = UUID(uuidString: "87E88911-A38B-4CEB-A471-BA636182952B")!
    private let nonce = String(repeating: "a", count: 43)
    nonisolated private static func response(nonce: String, edit: ((inout [String: Any]) -> Void)? = nil) -> Data {
        func cookie(_ name: String) -> [String: Any] {
            ["name":name,"value":"fixture-only-session","domain":"jarvis.labbing.space","path":"/",
             "secure":true,"http_only":true,"same_site":"Strict","expires_at":Int(Self.instant.timeIntervalSince1970) + 600]
        }
        var payload: [String: Any] = ["version":1,"nonce":nonce,"entry_url":"https://jarvis.labbing.space/",
                                     "expires_at":Int(Self.instant.timeIntervalSince1970) + 600,"cookies":[cookie("jarvis"),cookie("CF_Authorization")]]
        edit?(&payload); return try! JSONSerialization.data(withJSONObject: payload)
    }
    private func payload(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func broker(allowed: @escaping () -> Bool = { true }) -> JarvisAppSessionBroker {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        var count = 0
        return JarvisAppSessionBroker(configuration: config, requestBuilder: { path, body in
            var r = URLRequest(url: URL(string: "https://control.admin-ai.site" + path)!)
            r.httpMethod = "POST"; r.httpBody = body; r.setValue("Bearer fixture-owner-token", forHTTPHeaderField: "Authorization")
            r.setValue("must-be-removed", forHTTPHeaderField: "Origin"); r.setValue("must-be-removed", forHTTPHeaderField: "Cookie")
            return r
        }, isAllowed: allowed, nonce: { count += 1; return String(repeating: count == 1 ? "a" : "b", count: 43) }, now: { Self.instant })
    }
    override func setUp() async throws {
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    nonisolated private func reply(_ protocolInstance: MockURLProtocol, data: Data, status: Int = 200) {
        protocolInstance.client?.urlProtocol(protocolInstance, didReceive: HTTPURLResponse(url: protocolInstance.request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type":"application/json","Cache-Control":"no-store"])!, cacheStoragePolicy: .notAllowed)
        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: data)
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }

    func testUnauthenticatedFactoryMakesNoRequestsAndOptionalCookiesRemainUnconfirmed() throws {
        XCTAssertTrue(JarvisAppSessionRollout.verifiedOptionalCookies.isEmpty)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        let api = ServerAPI(session: URLSession(configuration: config), accessAllowed: false, tokenProvider: { "fixture-only" })
        XCTAssertThrowsError(try api.makeVerifiedJarvisBroker())
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testNonceUsesBase64URLAndInstallationIsCanonical() throws {
        let a = try JarvisSessionRequest.freshNonce(), b = try JarvisSessionRequest.freshNonce()
        XCTAssertNotEqual(a,b); XCTAssertEqual(a.count,43)
        let request = JarvisSessionRequest(installationID: installation, nonce: a)
        XCTAssertEqual(request.installation_id, installation.uuidString.lowercased()); XCTAssertNoThrow(try request.validate())
        for bad in ["", "a", String(repeating: "a", count: 129), String(repeating: "a", count: 22)+"=", String(repeating: "a", count: 22)+"/"] {
            XCTAssertThrowsError(try JarvisSessionRequest(installationID: installation, nonce: bad).validate())
        }
    }
    func testValidatedCookiesAreHostOnlySecureHTTPOnlyAndRedacted() throws {
        let value = try ValidatedJarvisAppSession.decode(Self.response(nonce: nonce), expectedNonce: nonce, now: Self.instant)
        XCTAssertEqual(value.entryURL, JarvisPolicy.home); XCTAssertEqual(value.cookies.count,2)
        for cookie in value.cookies {
            XCTAssertEqual(cookie.domain,"jarvis.labbing.space"); XCTAssertEqual(cookie.path,"/"); XCTAssertTrue(cookie.isSecure); XCTAssertTrue(cookie.isHTTPOnly)
            XCTAssertEqual(cookie.sameSitePolicy?.rawValue.lowercased(),"strict")
        }
        XCTAssertFalse(String(describing: value).contains("fixture-only-session"))
    }
    func testRejectsEveryMalformedCookieFieldAndCompleteResponseBeforeInstallation() throws {
        let badFields: [(String, Any)] = [("name","other"),("value","a; injected=x"),("value","a\r\nb"),("value",""),("domain",".jarvis.labbing.space"),
            ("domain","control.admin-ai.site"),("path","/voice"),("secure",false),("http_only",false),("same_site","Lax"),
            ("expires_at",Int(Self.instant.timeIntervalSince1970) + 1000),("expires_at",Int(Self.instant.timeIntervalSince1970) - 1)]
        for (key,bad) in badFields {
            let data = Self.response(nonce: nonce) { root in
                var cookies = root["cookies"] as! [[String:Any]]; cookies[1][key] = bad; root["cookies"] = cookies
            }
            XCTAssertThrowsError(try ValidatedJarvisAppSession.decode(data, expectedNonce: nonce, now: Self.instant), key)
        }
        for (key,bad) in [("version",2 as Any),("nonce","wrong"),("entry_url","https://jarvis.labbing.space:443/"),
                          ("entry_url","https://evil.example/"),("expires_at",Int(Self.instant.timeIntervalSince1970) + 59),("expires_at",Int(Self.instant.timeIntervalSince1970) + 901)] {
            XCTAssertThrowsError(try ValidatedJarvisAppSession.decode(Self.response(nonce: nonce) { $0[key]=bad }, expectedNonce: nonce, now: Self.instant))
        }
        XCTAssertThrowsError(try ValidatedJarvisAppSession.decode(Data("{}".utf8),expectedNonce:nonce,now:Self.instant))
    }
    func testOptionalNamesRequireSeparateLiveConfirmationAndDuplicatesAreRejected() throws {
        for optional in ["CF_Binding","CF_AppSession"] {
            let data = Self.response(nonce: nonce) { root in
                var cookies = root["cookies"] as! [[String:Any]]; var extra = cookies[0]; extra["name"] = optional; cookies.append(extra); root["cookies"] = cookies
            }
            XCTAssertThrowsError(try ValidatedJarvisAppSession.decode(data,expectedNonce:nonce,now:Self.instant))
            XCTAssertNoThrow(try ValidatedJarvisAppSession.decode(data,expectedNonce:nonce,now:Self.instant,verifiedOptionalNames:[optional]))
        }
        let duplicate = Self.response(nonce:nonce) { root in var c=root["cookies"] as! [[String:Any]]; c.append(c[0]); root["cookies"]=c }
        XCTAssertThrowsError(try ValidatedJarvisAppSession.decode(duplicate,expectedNonce:nonce,now:Self.instant))
    }
    func testPOSTPayloadAuthenticationAndNoCredentialForwarding() async throws {
        MockURLProtocol.onStart = { request in self.reply(request,data:Self.response(nonce:self.nonce)) }
        _ = try await broker().issue(installationID: installation)
        XCTAssertEqual(MockURLProtocol.requests.count,1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString,"https://control.admin-ai.site/api/jarvis/app-session")
        XCTAssertEqual(request.httpMethod,"POST"); XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer fixture-owner-token")
        XCTAssertNil(request.value(forHTTPHeaderField:"Origin")); XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField:"Content-Type"),"application/json")
        let body = try payload(request); XCTAssertEqual(Set(body.keys),["version","installation_id","nonce"])
        XCTAssertEqual(body["installation_id"] as? String,installation.uuidString.lowercased()); XCTAssertEqual(body["nonce"] as? String,nonce)
    }
    func testInvalidResponseRevokesOnceWithFreshNonceWithoutReissuing() async throws {
        MockURLProtocol.onStart = { request in
            if request.request.url?.path.hasSuffix("/revoke") == true {
                self.reply(request,data:Data("{\"version\":1,\"nonce\":\"\(String(repeating:"b",count:43))\",\"revoked\":true}".utf8))
            } else { self.reply(request,data:Data("{}".utf8)) }
        }
        let b=broker(); do { _ = try await b.issue(installationID:installation); XCTFail() } catch {}
        XCTAssertEqual(MockURLProtocol.requests.map { $0.url!.path },["/api/jarvis/app-session","/api/jarvis/app-session/revoke"])
        XCTAssertNotEqual(try payload(MockURLProtocol.requests[0])["nonce"] as? String,try payload(MockURLProtocol.requests[1])["nonce"] as? String)
        XCTAssertEqual(b.lastCompensatingRevocationConfirmed,true)
    }
    func testOfflineRevocationDoesNotClaimSuccessOrRetry() async {
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { try await broker().revoke(installationID:installation); XCTFail() } catch { XCTAssertTrue(error is JarvisBootstrapError) }
        XCTAssertEqual(MockURLProtocol.requests.count,1)
    }
    func testHTTPFailuresAreSanitizedAndNeverRetry() async {
        for code in [400,401,403,404,409,429,503] {
            MockURLProtocol.requests=[]; MockURLProtocol.onStart = { p in self.reply(p,data:Data("sensitive upstream error".utf8),status:code) }
            do { _ = try await broker().issue(installationID:installation); XCTFail() }
            catch { XCTAssertFalse(error.localizedDescription.contains("sensitive")) }
            XCTAssertEqual(MockURLProtocol.requests.count,1)
        }
    }
    func testLockPreventsRequestsAndStaleReplyCannotProduceCookies() async {
        var allowed=false; let b=broker(allowed:{ allowed })
        do { _ = try await b.issue(installationID:installation); XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        allowed=true; MockURLProtocol.onStart = { p in allowed=false; self.reply(p,data:Self.response(nonce:self.nonce)) }
        do { _ = try await b.issue(installationID:installation); XCTFail() } catch {}
        XCTAssertEqual(MockURLProtocol.requests.count,1)
    }
    func testRedirectDelegateNeverForwardsBearerToJarvisOrCloudflare() {
        let delegate=NoRedirectDelegate()
        let session=URLSession(configuration:.ephemeral)
        let task=session.dataTask(with:URL(string:"https://control.admin-ai.site/api/jarvis/app-session")!)
        for target in ["https://jarvis.labbing.space/","https://quiet-sky-4b47.cloudflareaccess.com/cdn-cgi/access/login/jarvis.labbing.space"] {
            let response=HTTPURLResponse(url:task.originalRequest!.url!,statusCode:302,httpVersion:nil,headerFields:["Location":target])!
            delegate.urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:target)!)) { forwarded in XCTAssertNil(forwarded) }
        }
        task.cancel();session.invalidateAndCancel();XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testWrongAPIHostIsRejectedBeforeAnyTransmission() async {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MockURLProtocol.self]
        let b=JarvisAppSessionBroker(configuration:config,requestBuilder:{ path,body in
            var r=URLRequest(url:URL(string:"https://jarvis.labbing.space"+path)!);r.httpMethod="POST";r.httpBody=body
            r.setValue("Bearer fixture-only",forHTTPHeaderField:"Authorization");return r
        },isAllowed:{true})
        do { _=try await b.issue(installationID:installation);XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testPendingIssuanceSuppressesDuplicateIssueAndRevoke() async throws {
        let entered=expectation(description:"Issuance pending"),gate=JarvisBootstrapRequestGate()
        MockURLProtocol.onStart={p in
            if p.request.url?.path.hasSuffix("/revoke") == true {
                // A failed issuance may compensate; never fulfill the issuance expectation twice.
                self.reply(p,data:Data("{\"version\":1,\"nonce\":\"\(String(repeating:"b",count:43))\",\"revoked\":true}".utf8))
            } else { gate.capture(p);entered.fulfill() }
        }
        let b=broker(),first=Task { try await b.issue(installationID:installation) }
        await fulfillment(of:[entered],timeout:2)
        do { _=try await b.issue(installationID:installation);XCTFail() } catch {}
        do { try await b.revoke(installationID:installation);XCTFail() } catch {}
        XCTAssertEqual(MockURLProtocol.requests.count,1)
        reply(try XCTUnwrap(gate.take()),data:Self.response(nonce:nonce));_=try await first.value
        XCTAssertEqual(MockURLProtocol.requests.count,1)
        XCTAssertFalse(b.pending)
    }
    func testFoundationCookieHeaderParsingDoesNotDefineContractSecurity() throws {
        // Characterize the OS parser with synthetic data, never live credentials.
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(secondsFromGMT:0)
        formatter.dateFormat="EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header="fixture=synthetic; Path=/; Secure; HttpOnly; SameSite=Strict; Expires=\(formatter.string(from:Self.instant.addingTimeInterval(600)))"
        let parsed=try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields:["Set-Cookie":header],for:JarvisPolicy.home).first)
        XCTAssertEqual(parsed.sameSitePolicy,.sameSiteStrict)
        XCTAssertEqual(parsed.expiresDate,Self.instant.addingTimeInterval(600))
        XCTAssertEqual(parsed.domain,"jarvis.labbing.space");XCTAssertTrue(parsed.isSecure);XCTAssertTrue(parsed.isHTTPOnly)
        let session=try ValidatedJarvisAppSession.decode(Self.response(nonce:nonce),expectedNonce:nonce,now:Self.instant)
        for cookie in session.cookies {
            XCTAssertEqual(cookie.sameSitePolicy,.sameSiteStrict)
            XCTAssertEqual(cookie.expiresDate,Self.instant.addingTimeInterval(600))
            XCTAssertFalse(cookie.isSessionOnly)
        }
    }
}

private final class JarvisBootstrapRequestGate {
    private let lock=NSLock()
    private var request:MockURLProtocol?
    func capture(_ value:MockURLProtocol){lock.lock();request=value;lock.unlock()}
    func take()->MockURLProtocol?{lock.lock();defer{lock.unlock()};return request}
}

