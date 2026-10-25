import Foundation
import AppKit
@preconcurrency import Network

struct HostFailure: Error { let code: String; let message: String }
struct HostRequest { let method: String; let headers: [String: String]; let body: Data }
struct HostConfiguration: Decodable { let port: UInt16; let token: String }
struct HostPolicy {
    let port: UInt16
    let token: String
    static let origins: Set<String> = ["null", "http://127.0.0.1:8767", "http://localhost:8767"]
    func constantTimeEqual(_ input: String) -> Bool {
        let a = Array(input.utf8), b = Array(("Bearer " + token).utf8)
        var difference = a.count ^ b.count
        for i in 0..<max(a.count, b.count) { difference |= Int((i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)) }
        return difference == 0
    }
    func validate(_ request: HostRequest) throws -> String {
        guard request.headers["host"] == "127.0.0.1:\(port)", let origin = request.headers["origin"], Self.origins.contains(origin) else { throw HostFailure(code: "origin", message: "请求来源无效") }
        if request.method == "OPTIONS" {
            guard request.headers["access-control-request-method"] == "POST" else { throw HostFailure(code: "method", message: "仅支持 POST") }
            let requested = Set((request.headers["access-control-request-headers"] ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            guard requested.isSubset(of: ["authorization", "content-type"]) else { throw HostFailure(code: "headers", message: "请求头无效") }
        } else {
            guard request.method == "POST", constantTimeEqual(request.headers["authorization"] ?? "") else { throw HostFailure(code: "unauthorized", message: "配对凭据无效") }
            guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else { throw HostFailure(code: "content_type", message: "需要 JSON") }
        }
        return origin
    }
}
// Incremental bounded HTTP/1.1 parser. Reject ambiguous framing and extra bytes.
func parseHostRequest(_ bytes: Data) throws -> HostRequest? {
    guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
        if bytes.count > 8192 { throw HostFailure(code: "headers", message: "请求头过长") }; return nil
    }
    guard boundary.upperBound <= 8192, let header = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw HostFailure(code: "headers", message: "请求头无效") }
    let lines = header.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard first.count == 3, first[1] == "/api", first[2] == "HTTP/1.1", ["POST", "OPTIONS"].contains(String(first[0])) else { throw HostFailure(code: "request", message: "请求无效") }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw HostFailure(code: "headers", message: "请求头无效") }
        let key = String(line[..<colon]).lowercased()
        guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[key] == nil else { throw HostFailure(code: "headers", message: "重复请求头") }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !value.contains("\r"), !value.contains("\n") else { throw HostFailure(code: "headers", message: "请求头无效") }
        headers[key] = value
    }
    guard headers["transfer-encoding"] == nil, let raw = headers["content-length"] ?? (first[0] == "OPTIONS" ? "0" : nil), !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(raw), count <= 16384 else { throw HostFailure(code: "length", message: "请求长度无效") }
    let total = boundary.upperBound + count
    guard bytes.count <= total else { throw HostFailure(code: "pipeline", message: "不支持流水请求") }
    guard bytes.count == total else { return nil }
    return HostRequest(method: String(first[0]), headers: headers, body: Data(bytes[boundary.upperBound...]))
}
func jsonValue<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
func failureValue(_ error: Error) -> [String: Any] {
    let failure = error as? HostFailure
    return ["ok": false, "error": ["code": failure?.code ?? String(describing: error), "message": failure?.message ?? "照片操作未完成，请检查权限或重新选择照片。"]]
}
@MainActor final class PreviewReplies {
    private var replies: [UUID: ([String: Any]) -> Void] = [:]
    var count: Int { replies.count }
    func insert(_ token: UUID, reply: @escaping ([String: Any]) -> Void) { replies[token] = reply }
    func take(_ token: UUID) -> (([String: Any]) -> Void)? { replies.removeValue(forKey: token) }
    func cancel() {
        let callbacks = Array(replies.values); replies.removeAll()
        for callback in callbacks { callback(["status": "cancelled", "dataURI": NSNull()]) }
    }
}
struct SessionGuard {
    var active: String?
    func accepts(_ identifier: String?) -> Bool { active != nil && active == identifier }
    mutating func end(_ identifier: String?) -> Bool {
        guard accepts(identifier) else { return false }; active = nil; return true
    }
}
@MainActor final class HostDispatcher {
    private var lifecycle = SessionGuard()
    private var bridge: ApplePhotosBridge?
    private let pending = PreviewReplies()
    private var timers: [UUID: Task<Void, Never>] = [:]
    private func core() -> ApplePhotosBridge { if let bridge { return bridge }; let value = ApplePhotosBridge(); bridge = value; return value }
    func cancel() {
        lifecycle.active = nil
        bridge?.cancelAll(); bridge?.endImport()
        pending.cancel()
        for timer in timers.values { timer.cancel() }; timers.removeAll()
    }
    private func query(_ body: [String: Any]) throws -> Query {
        func date(_ key: String) throws -> Date? {
            guard let raw = body[key], !(raw is NSNull) else { return nil }
            guard let string = raw as? String else { throw BridgeError.invalidQuery }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let value = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string) else { throw BridgeError.invalidQuery }; return value
        }
        let result = Query(offset: body["offset"] as? Int ?? 0, limit: body["limit"] as? Int ?? 100, from: try date("from"), until: try date("until"), albumIdentifier: body["albumIdentifier"] as? String)
        try result.validate(); return result
    }
    func dispatch(_ body: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        func success(_ value: Any) { reply(["ok": true, "data": value]) }
        do {
            switch body["action"] as? String {
            case "status":
                // status does not initialize PHImageManager or fetch library contents.
                let value = PHStatus.value(); success(try jsonValue(value))
            case "authorize":
                NSApplication.shared.activate(ignoringOtherApps: true)
                Task { let status = await core().requestAuthorization(); do { success(try jsonValue(status)) } catch { reply(failureValue(error)) } }
            case "albums": success(["albums": try jsonValue(core().albums())])
            case "begin":
                cancel(); let q = try query(body); let token = try core().beginImport(q)
                lifecycle.active = token
                success(try jsonValue(core().assets(sessionIdentifier: token, query: q)))
            case "page":
                guard let token = body["sessionIdentifier"] as? String, lifecycle.accepts(token) else { throw BridgeError.noSession }
                success(try jsonValue(core().assets(sessionIdentifier: token, query: query(body))))
            case "preview":
                guard lifecycle.accepts(body["sessionIdentifier"] as? String) else { throw BridgeError.noSession }
                guard pending.count < 2 else { throw HostFailure(code: "busy", message: "最多同时读取两张预览") }
                guard let identifier = body["identifier"] as? String, core().selected(identifier) else { throw BridgeError.noSession }
                let token = UUID(), network = body["allowNetwork"] as? Bool ?? false
                let request = try core().preview(identifier: identifier, allowNetwork: network, progress: { _ in }) { [weak self] data, status in
                    guard let self, let callback = self.pending.take(token) else { return }
                    self.timers.removeValue(forKey: token)?.cancel()
                    callback(["status": status, "dataURI": data.map { "data:image/jpeg;base64," + $0.base64EncodedString() } as Any? ?? NSNull()])
                }
                pending.insert(token, reply: { success($0) })
                timers[token] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(network ? 120 : 45))
                    guard !Task.isCancelled, let self, let callback = self.pending.take(token) else { return }
                    self.bridge?.cancel(request); self.timers.removeValue(forKey: token)
                    callback(["status": "cancelled", "dataURI": NSNull()])
                }
            case "cancel", "end":
                let accepted = lifecycle.end(body["sessionIdentifier"] as? String)
                if accepted { cancel() }
                success(["cancelled": accepted])
            default: throw BridgeError.invalidArguments
            }
        } catch { reply(failureValue(error)) }
    }
}
@preconcurrency import Photos
enum PHStatus {
    static func value() -> LibraryStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let name: String
        switch status { case .authorized: name = "authorized"; case .limited: name = "limited"; case .denied: name = "denied"; case .restricted: name = "restricted"; case .notDetermined: name = "notdetermined"; @unknown default: name = "unknown" }
        return LibraryStatus(permission: name, canRead: status == .authorized || status == .limited)
    }
}
@MainActor final class HTTPClient {
    let connection: NWConnection
    let policy: HostPolicy
    let dispatcher: HostDispatcher
    var data = Data()
    var completed = false
    var timeout: Task<Void, Never>?
    init(_ connection: NWConnection, policy: HostPolicy, dispatcher: HostDispatcher) { self.connection = connection; self.policy = policy; self.dispatcher = dispatcher }
    func start() {
        connection.start(queue: .main)
        timeout = Task { [weak self] in try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled else { return }; self?.close() }
        receive()
    }
    func close() { completed = true; timeout?.cancel(); connection.cancel() }
    func send(_ value: [String: Any], origin: String? = nil, status: Int = 200, preflight: Bool = false, privateNetwork: Bool = false) {
        guard !completed else { return }; completed = true; timeout?.cancel()
        let body = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        var headers = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nVary: Origin\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if let origin { headers += "Access-Control-Allow-Origin: \(origin)\r\n" }
        if preflight { headers += "Access-Control-Allow-Methods: POST\r\nAccess-Control-Allow-Headers: authorization, content-type\r\n" }
        if preflight && privateNetwork { headers += "Access-Control-Allow-Private-Network: true\r\n" }
        connection.send(content: Data(headers.utf8) + Data("\r\n".utf8) + body, completion: .contentProcessed { [self] _ in connection.cancel() })
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 24577) { [self] bytes, _, ended, error in
            Task { @MainActor in
                guard !completed else { return }
                if let bytes { data.append(bytes) }
                do {
                    if let request = try parseHostRequest(data) {
                        let origin = try policy.validate(request)
                        timeout?.cancel()
                        if request.method == "OPTIONS" { send(["ok": true], origin: origin, preflight: true, privateNetwork: request.headers["access-control-request-private-network"] == "true"); return }
                        guard let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw BridgeError.invalidArguments }
                        dispatcher.dispatch(body) { [self] value in send(value, origin: origin) }
                    } else if ended || error != nil { close() } else { receive() }
                } catch { send(failureValue(error), status: 400) }
            }
        }
    }
}
enum HostText {
    static func text(_ zh: String, _ en: String, _ de: String) -> String {
        let language = Locale.preferredLanguages.first ?? "en"
        return language.hasPrefix("zh") ? zh : language.hasPrefix("de") ? de : en
    }
    static var title: String { text("片刻照片助手", "Moments Photos Helper", "Moments Fotos-Helfer") }
    static var ready: String { text("片刻照片助手运行中，请回照片页继续\n\n本应用不修改图库", "Photos Helper is running. Return to Photos to continue.\n\nThis app does not modify your library.", "Fotos-Helfer läuft. Kehre zur Fotoseite zurück.\n\nDiese App verändert deine Mediathek nicht.") }
    static var starting: String { text("照片助手正在启动…", "Starting Photos Helper…", "Fotos-Helfer wird gestartet…") }
    static var failed: String { text("照片助手启动失败。请退出后重试，或检查端口是否被占用。", "Photos Helper could not start. Quit and retry, or check whether its port is already in use.", "Fotos-Helfer konnte nicht starten. Beenden und erneut versuchen oder den belegten Port prüfen.") }
    static var quit: String { text("退出照片助手", "Quit Photos Helper", "Fotos-Helfer beenden") }
}
@MainActor final class HostApplication: NSObject, NSApplicationDelegate {
    var listener: NWListener?
    var window: NSWindow?
    var label: NSTextField?
    let dispatcher = HostDispatcher()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle: HostText.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); NSApplication.shared.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = HostText.title
        let label = NSTextField(wrappingLabelWithString: HostText.starting)
        label.frame = NSRect(x: 24, y: 30, width: 392, height: 96); window.contentView?.addSubview(label)
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window; self.label = label
        do {
            guard let url = Bundle.main.url(forResource: "connection", withExtension: "json") else { throw BridgeError.invalidArguments }
            let configuration = try JSONDecoder().decode(HostConfiguration.self, from: Data(contentsOf: url))
            guard configuration.port > 1024, configuration.token.count == 64, configuration.token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw BridgeError.invalidArguments }
            let policy = HostPolicy(port: configuration.port, token: configuration.token)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: configuration.port)!)
            let server = try NWListener(using: parameters)
            server.newConnectionHandler = { connection in Task { @MainActor in HTTPClient(connection, policy: policy, dispatcher: self.dispatcher).start() } }
            server.stateUpdateHandler = { state in Task { @MainActor in
                switch state {
                case .ready: self.label?.stringValue = HostText.ready
                case .failed: self.label?.stringValue = HostText.failed; self.dispatcher.cancel()
                default: break
                }
            } }
            server.start(queue: .main); listener = server
        } catch { label.stringValue = HostText.failed }
    }
    func applicationWillTerminate(_ notification: Notification) { dispatcher.cancel(); listener?.cancel() }
}
@MainActor func hostSelfTest() throws {
    let token = String(repeating: "a", count: 64), policy = HostPolicy(port: 8768, token: String(repeating: "a", count: 64))
    func wire(_ extra: String = "", body: String = "{}") -> Data { Data("POST /api HTTP/1.1\r\nHost: 127.0.0.1:8768\r\nOrigin: null\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8) }
    let request = try parseHostRequest(wire())!; let origin = try policy.validate(request); precondition(origin == "null")
    precondition(!policy.constantTimeEqual("Bearer wrong"))
    for invalid in [wire("Content-Length: 2\r\n"), wire("Transfer-Encoding: chunked\r\n"), wire() + Data("x".utf8), Data(repeating: 65, count: 8193)] {
        do { _ = try parseHostRequest(invalid); throw HostFailure(code: "test", message: "accepted invalid request") } catch let error as HostFailure { precondition(error.code != "test") }
    }
    for origin in ["http://evil.example", "http://127.0.0.1:8768", ""] {
        var headers = request.headers; headers["origin"] = origin
        do { _ = try policy.validate(HostRequest(method: "POST", headers: headers, body: request.body)); preconditionFailure() } catch {}
    }
    var lifecycle = SessionGuard(active: "A")
    precondition(lifecycle.accepts("A")); lifecycle.active = "B"
    precondition(!lifecycle.end("A") && lifecycle.accepts("B"))
    precondition(!lifecycle.end(nil) && lifecycle.accepts("B"))
    precondition(lifecycle.end("B") && !lifecycle.accepts("B"))
    let pending = PreviewReplies(); let previewToken = UUID(); var resolved = 0
    pending.insert(previewToken) { result in precondition(result["status"] as? String == "cancelled"); resolved += 1 }
    pending.cancel(); pending.cancel(); precondition(resolved == 1 && pending.count == 0 && pending.take(previewToken) == nil)
    var session = ImportSession()
    precondition(!session.contains("unselected"))
    let selected = ImportedAsset(id: "synthetic", localIdentifier: "chosen", date: nil, dateBasis: "utc-derived", captureLocalDate: nil, creationDate: nil, modificationDate: nil, originalTimeZone: nil, favorite: false, width: 1, height: 1, location: nil, duration: 0, mediaType: "image", cloudStatus: "unknown")
    _ = try session.begin([selected], query: Query())
    precondition(session.contains("chosen") && !session.contains("other"))
    session.end(); precondition(!session.contains("chosen"))
    print("Apple Photos host self-test passed (no PhotoKit access, listener, or UI)")
}
@main struct ApplePhotosHost {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--self-test"]) {
            do { try hostSelfTest() } catch { exit(1) }; return
        }
        let app = NSApplication.shared, delegate = HostApplication()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
