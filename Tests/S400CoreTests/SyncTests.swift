// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import S400Core
@testable import S400Menu

// No socket is opened: all fixture requests are intercepted before URL loading.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!
    static var requests = [URLRequest]()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.requests.append(request)
            let (code, headers, body) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.requestBodyStreamExhausted) }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
@MainActor final class MockAuthorization: HealthAuthorizing {
    var authorized = true
    var calls = 0
    func authorize(_ request: URLRequest) async throws -> URLRequest { calls += 1; return request }
}

// A controllable token-refresh boundary. All values are synthetic and it opens
// no connection; tests release the first authorization only after switching consent.
@MainActor private final class DeferredAuthorization: HealthAuthorizing {
    var authorized = true
    var calls = 0
    var sessionName = "old-synthetic-session"
    private var deferredRequest: URLRequest?
    private var pending: CheckedContinuation<URLRequest, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func authorize(_ request: URLRequest) async throws -> URLRequest {
        calls += 1
        var tagged = request; tagged.setValue(sessionName, forHTTPHeaderField: "X-Test-Session")
        if calls > 1 { return tagged }
        deferredRequest = tagged
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            waiter?.resume(); waiter = nil
        }
    }
    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(error: (any Error)? = nil) {
        let continuation = pending; pending = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: deferredRequest!) }
        deferredRequest = nil
    }
}

// URLProtocol catches the request before socket creation, then holds its reply
// while the main-actor test pauses and resumes the sync engine.
private final class DeferredURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var pending: DeferredURLProtocol?
    private static var waiter: CheckedContinuation<Void, Never>?
    private(set) static var starts = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.starts += 1; Self.pending = self
        let ready = Self.waiter; Self.waiter = nil
        Self.lock.unlock()
        ready?.resume()
    }
    override func stopLoading() {}
    static func reset() {
        lock.lock(); pending = nil; waiter = nil; starts = 0; lock.unlock()
    }
    static func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let started = pending != nil
            if !started { waiter = continuation }
            lock.unlock()
            if started { continuation.resume() }
        }
    }
    static func finish(status: Int) {
        lock.lock(); let current = pending; pending = nil; lock.unlock()
        guard let current else { return }
        let response = HTTPURLResponse(url: current.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        current.client?.urlProtocol(current, didReceive: response, cacheStoragePolicy: .notAllowed)
        current.client?.urlProtocol(current, didLoad: Data(#"{"done":true,"response":{}}"#.utf8))
        current.client?.urlProtocolDidFinishLoading(current)
    }
}
@Suite(.serialized) @MainActor final class SyncTests {
    var dir: URL!
    var store: MeasurementStore!
    var auth: MockAuthorization!
    var engine: SyncEngine!
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try MeasurementStore(url: dir.appendingPathComponent("fixture.json"))
        auth = MockAuthorization()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        engine = SyncEngine(store: store, auth: auth, network: URLSession(configuration: config))
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in (200, [:], Data(#"{"done":true,"response":{}}"#.utf8)) }
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
    func add(simulated: Bool = false, twoMetrics: Bool = true) throws {
        let now = Date()
        let row = Measurement(reading: FinalReading(weight: 76.5, low: 402, high: 365, date: now),
            profile: twoMetrics ? Profile(birthYear: Calendar.current.component(.year, from: now) - 27, height: 172, male: true) : nil, simulated: simulated)
        try store.insert(row)
    }
    @Test func testNoConsentMakesZeroRequests() async throws {
        try add(); await engine.run()
        XCTAssertTrue(MockURLProtocol.requests.isEmpty); XCTAssertEqual(auth.calls, 0)
    }
    @Test func testSimulationCannotReachAuthorizerOrNetwork() async throws {
        try add(simulated: true); engine.consent = true; await engine.run()
        XCTAssertTrue(MockURLProtocol.requests.isEmpty); XCTAssertEqual(auth.calls, 0)
    }
    @Test func testBothMetricsAckAndRestartDoNotReupload() async throws {
        try add(); engine.consent = true; await engine.run()
        XCTAssertEqual(MockURLProtocol.requests.count, 2); XCTAssertEqual(store.pendingCount, 0)
        await engine.run(); XCTAssertEqual(MockURLProtocol.requests.count, 2)
        let reopened = try MeasurementStore(url: store.url)
        XCTAssertEqual(reopened.pendingCount, 0)
    }
    @Test func testFilteredSampleBlocksBothMetricsBeforeAuthorization() async throws {
        try add(); engine.consent = true; await engine.run()
        #expect(MockURLProtocol.requests.count == 2)
        let previous = store.rows[0]
        let rejected = Measurement(reading: FinalReading(weight: 96, low: 402, high: 365,
            date: previous.date.addingTimeInterval(120)),
            profile: Profile(birthYear: Calendar.current.component(.year, from: Date()) - 27, height: 172, male: true), simulated: false)
        #expect(rejected.deliveries.count == 2)
        #expect(try store.insertWithResult(rejected) == .filtered)
        await engine.run()
        #expect(MockURLProtocol.requests.count == 2)
        #expect(auth.calls == 2)
        #expect(store.pendingCount == 0)
        #expect(store.rows.count == 2 && store.rows[0] == previous)
        #expect(store.rows[1].isFiltered && store.rows[1].deliveries.isEmpty)
        let reopened = try MeasurementStore(url: store.url)
        #expect(reopened.rows == store.rows)
        for metric in ["weight", "body-fat"] {
            #expect(throws: ScaleError.self) { try HealthPayload.request(row: reopened.rows[1], metric: metric, consent: true) }
        }
        // Even forged delivery entries cannot bypass the exclusion guard.
        var forged = reopened.rows[1]
        forged.deliveries = ["weight": Delivery(), "body-fat": Delivery()]
        let forgedURL = dir.appendingPathComponent("forged.json")
        try JSONEncoder().encode([forged]).write(to: forgedURL)
        let forgedStore = try MeasurementStore(url: forgedURL)
        let forgedEngine = SyncEngine(store: forgedStore, auth: auth, network: engineNetwork())
        forgedEngine.consent = true
        await forgedEngine.run()
        #expect(MockURLProtocol.requests.count == 2 && auth.calls == 2)
    }
    private func engineNetwork() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
    @Test func testLegacyPendingMetricUsesSavedFatAndDoesNotReplaySyncedWeight() async throws {
        try add(); engine.consent = true
        var legacy = store.rows[0]
        legacy.fat = 31.7; legacy.bodyFatAlgorithm = nil
        legacy.deliveries["weight"]?.state = "synced"
        try store.update(legacy)
        MockURLProtocol.handler = { request in
            #expect(request.url!.path.contains("body-fat"))
            let payload = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as! [String: Any]
            #expect((payload["bodyFat"] as? [String: Any])?["percentage"] as? Double == 31.7)
            return (200, [:], Data(#"{"done":true,"response":{}}"#.utf8))
        }
        await engine.run()
        #expect(MockURLProtocol.requests.count == 1)
        #expect(store.rows[0].fat == 31.7 && store.rows[0].bodyFatAlgorithm == nil)
        #expect(store.pendingCount == 0)
    }
    @Test func testPartialSuccessDoesNotReplaySuccessfulMetric() async throws {
        try add(); engine.consent = true
        MockURLProtocol.handler = { request in
            request.url!.path.contains("body-fat") ? (200, [:], Data(#"{"done":true,"response":{}}"#.utf8)) : (503, ["Retry-After": "600"], Data())
        }
        await engine.run()
        let row = store.rows[0]
        XCTAssertEqual(row.deliveries["body-fat"]?.state, "synced")
        XCTAssertEqual(row.deliveries["weight"]?.state, "pending")
        XCTAssertGreaterThan(row.deliveries["weight"]!.retryAt.timeIntervalSinceNow, 590)
        await engine.run(); XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }
    @Test func testOfflineFailureIsDurable() async throws {
        try add(twoMetrics: false); engine.consent = true
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await engine.run()
        let reopened = try MeasurementStore(url: store.url)
        XCTAssertEqual(reopened.rows[0].deliveries["weight"]?.attempts, 1)
        XCTAssertEqual(reopened.pendingCount, 1)
    }
    @Test func test401PausesWithoutLosingRecord() async throws {
        try add(); engine.consent = true
        MockURLProtocol.handler = { _ in (401, [:], Data()) }
        await engine.run(); XCTAssertFalse(engine.consent); XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    @Test func test409IsHeldForReview() async throws {
        try add(twoMetrics: false); engine.consent = true
        MockURLProtocol.handler = { _ in (409, [:], Data()) }
        await engine.run(); XCTAssertEqual(store.rows[0].deliveries["weight"]?.state, "blocked")
        await engine.run(); XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    @Test func testAsynchronousOperationNeverPrematurelyAcknowledged() async throws {
        try add(twoMetrics: false); engine.consent = true
        MockURLProtocol.handler = { _ in (200, [:], Data(#"{"name":"operations/test-op","done":false}"#.utf8)) }
        await engine.run(); XCTAssertEqual(store.rows[0].deliveries["weight"]?.state, "operation")
        XCTAssertEqual(store.pendingCount, 1)
        var row = store.rows[0]; row.deliveries["weight"]?.retryAt = .distantPast; try store.update(row)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], Data(#"{"done":true,"response":{}}"#.utf8))
        }
        await engine.run(); XCTAssertEqual(store.pendingCount, 0)
    }
    @Test func testMaliciousOperationPathDoesNotReachAuthorization() async throws {
        try add(twoMetrics: false); engine.consent = true
        var row = store.rows[0]
        row.deliveries["weight"]?.operation = "https://evil.invalid/operations/steal"
        row.deliveries["weight"]?.state = "operation"; try store.update(row)
        await engine.run(); XCTAssertEqual(auth.calls, 0); XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    @Test func pauseResumeInvalidatesAwaitingAuthorizationAndKeepsBusyUntilItFinishes() async throws {
        try add(twoMetrics: false)
        let delayed = DeferredAuthorization()
        let current = SyncEngine(store: store, auth: delayed, network: engineNetwork())
        current.consent = true
        let original = store.rows
        let previousRun = Task { await current.run() }
        await delayed.waitUntilSuspended()
        current.consent = false; current.consent = true
        await current.run() // Must not begin a competing task while the old one awaits.
        #expect(delayed.calls == 1 && MockURLProtocol.requests.isEmpty)
        delayed.finish()
        await previousRun.value
        #expect(current.consent && store.rows == original && MockURLProtocol.requests.isEmpty)
        await current.run()
        #expect(delayed.calls == 2 && MockURLProtocol.requests.count == 1)
        #expect(store.pendingCount == 0)
    }

    @Test func replacementSessionIgnoresOldAuthorizationErrorAndUsesOnlyNewToken() async throws {
        try add(twoMetrics: false)
        let delayed = DeferredAuthorization()
        let current = SyncEngine(store: store, auth: delayed, network: engineNetwork())
        current.consent = true
        var statusMessages: [String] = []
        current.onStatus = { statusMessages.append($0) }
        let original = store.rows
        let previousRun = Task { await current.run() }
        await delayed.waitUntilSuspended()
        current.consent = false
        delayed.sessionName = "replacement-synthetic-session"
        current.consent = true
        delayed.finish(error: ScaleError.consent)
        await previousRun.value
        #expect(current.consent && statusMessages.isEmpty && store.rows == original)
        #expect(MockURLProtocol.requests.isEmpty)
        await current.run()
        #expect(MockURLProtocol.requests.count == 1)
        #expect(MockURLProtocol.requests[0].value(forHTTPHeaderField: "X-Test-Session") == "replacement-synthetic-session")
        #expect(store.pendingCount == 0)
    }

    @Test(arguments: [200, 401, 503]) func lateResponseFromOldSessionCannotAcknowledgePauseOrOverwriteCurrentQueue(status: Int) async throws {
        try add(twoMetrics: false)
        DeferredURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DeferredURLProtocol.self]
        let current = SyncEngine(store: store, auth: auth, network: URLSession(configuration: config))
        current.consent = true
        var statusMessages: [String] = []
        current.onStatus = { statusMessages.append($0) }
        let previousRun = Task { await current.run() }
        await DeferredURLProtocol.waitUntilStarted()
        current.consent = false; current.consent = true
        var saved = store.rows[0]
        saved.deliveries["weight"]?.attempts = 7
        saved.deliveries["weight"]?.retryAt = .distantFuture
        try store.update(saved)
        await current.run() // A second URL task must not start while the first is outstanding.
        #expect(auth.calls == 1 && DeferredURLProtocol.starts == 1)
        DeferredURLProtocol.finish(status: status)
        await previousRun.value
        #expect(current.consent && statusMessages.isEmpty)
        #expect(store.rows == [saved] && store.pendingCount == 1)
        #expect(auth.calls == 1 && DeferredURLProtocol.starts == 1)
    }
}
