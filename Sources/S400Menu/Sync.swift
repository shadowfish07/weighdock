// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import S400Core

@MainActor protocol HealthAuthorizing: AnyObject {
    var authorized: Bool { get }
    func authorize(_ request: URLRequest) async throws -> URLRequest
}
extension GoogleAuthorization: HealthAuthorizing {}

@MainActor final class SyncEngine {
    let store: MeasurementStore
    let auth: any HealthAuthorizing
    // A paused/reconfigured session must not become valid again merely because
    // consent was enabled while an older authorization or request was awaiting.
    private var consentEpoch: UInt64 = 0
    var consent = false {
        didSet { if consent != oldValue { consentEpoch &+= 1 } }
    }
    var onStatus: ((String) -> Void)?
    private var busy = false
    private let network: URLSession
    init(store: MeasurementStore, auth: any HealthAuthorizing, network: URLSession? = nil) {
        self.store = store; self.auth = auth
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        config.httpShouldSetCookies = false
        self.network = network ?? URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    func run() async {
        guard consent, auth.authorized, !busy else { return }
        let epoch = consentEpoch
        busy = true; defer { busy = false }
        for snapshot in store.rows where !snapshot.simulated && !snapshot.isFiltered {
            for metric in snapshot.deliveries.keys.sorted() {
                guard consent, consentEpoch == epoch, auth.authorized,
                      var row = store.rows.first(where: { $0.id == snapshot.id }),
                      !row.isFiltered,
                      var delivery = row.deliveries[metric], ["pending", "operation"].contains(delivery.state), delivery.retryAt <= Date() else { continue }
                do {
                    var request: URLRequest
                    if let operation = delivery.operation {
                        // Strict path validation prevents a server string redirecting bearer credentials.
                        guard operation.range(of: "^(users/[A-Za-z0-9_-]+/)?operations/[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw ScaleError.operation }
                        request = URLRequest(url: URL(string: "https://health.googleapis.com/v4/\(operation)")!)
                    } else { request = try HealthPayload.request(row: row, metric: metric, consent: consent) }
                    request = try await auth.authorize(request)
                    guard consent, consentEpoch == epoch else { return }
                    let (data, response) = try await network.data(for: request)
                    guard consent, consentEpoch == epoch else { return }
                    guard let http = response as? HTTPURLResponse else { throw ScaleError.operation }
                    let code = http.statusCode
                    if code == 401 || code == 403 {
                        consent = false; onStatus?("同步已暂停：请检查授权与 API 权限"); return
                    }
                    if code == 429 || code >= 500 {
                        delivery.failed(now: Date(), retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
                        onStatus?("服务暂不可用，将自动重试")
                    } else if !(200...299).contains(code) {
                        // 409 is never blindly interpreted as success. Preserve the record for review.
                        delivery.state = "blocked"; onStatus?("同步需检查（HTTP \(code)）")
                    } else {
                        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if object?["done"] as? Bool == true {
                            if let error = object?["error"] as? [String: Any] {
                                let status = error["code"] as? Int ?? -1
                                if [4, 8, 13, 14].contains(status) {
                                    delivery.operation = nil; delivery.state = "pending"; delivery.failed(now: Date())
                                } else { delivery.state = "blocked" }
                                onStatus?("云端处理失败（\(status)）")
                            } else if object?["response"] != nil {
                                delivery.state = "synced"; onStatus?("已同步到 Google Health")
                            } else { throw ScaleError.operation }
                        } else if let name = object?["name"] as? String, name.contains("operations/") {
                            delivery.operation = name; delivery.state = "operation"
                            delivery.retryAt = Date().addingTimeInterval(30)
                            onStatus?("Google Health 正在处理")
                        } else { throw ScaleError.operation }
                    }
                } catch ScaleError.consent {
                    guard consent, consentEpoch == epoch else { return }
                    consent = false; onStatus?("同步已暂停：需要重新授权"); return
                } catch {
                    guard consent, consentEpoch == epoch else { return }
                    delivery.failed(now: Date()); onStatus?("连接未完成，将自动重试")
                }
                guard consent, consentEpoch == epoch else { return }
                row.deliveries[metric] = delivery
                do { try store.update(row) }
                catch { consent = false; onStatus?("保存同步进度失败，已暂停"); return }
            }
        }
    }
    static func retryAfter(_ text: String?) -> TimeInterval? {
        guard let text else { return nil }
        if let seconds = Double(text) { return max(0, min(seconds, 86400)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text).map { max(0, min($0.timeIntervalSinceNow, 86400)) }
    }
}

// Health requests must never forward a bearer token to another host via redirect.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
