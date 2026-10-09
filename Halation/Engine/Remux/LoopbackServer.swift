import Foundation
import Network

struct HTTPResource: Sendable {
    var body: Data
    var contentType: String
}

/// A tiny HTTP/1.1 server that hands AVPlayer remuxed HLS over `127.0.0.1` (PLAN.md, phase 2). AVPlayer cannot
/// take HLS media from an `AVAssetResourceLoader`, so this is the transport.
///
/// - Listens on the IPv4 loopback address only, on a port the system picks.
/// - Every URL starts with a random token (`/<token>/…`), so other processes on the Mac can't guess what to fetch.
/// - Answers GET and HEAD, with single `Range` requests (AVPlayer uses them), over keep-alive connections.
/// - What is served comes from `provider`, called with the path after the token. Nil means 404.
///
/// The sandbox needs `com.apple.security.network.server` to listen here.
final class LoopbackServer: @unchecked Sendable {
    typealias Provider = @Sendable (String) async -> HTTPResource?

    enum Failure: Error, Equatable { case couldNotStart(String) }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "halation.loopback-server")
    private let token: String
    private let provider: Provider
    private var connections: [ObjectIdentifier: Connection] = [:]  // guarded by `queue`

    /// `http://127.0.0.1:<port>/<token>/`, once started.
    private(set) var baseURL: URL?

    init(provider: @escaping Provider) throws {
        self.provider = provider
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Waits until the listener is ready, and returns the base URL.
    func start() async throws -> URL {
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { [listener, token] state in
                switch state {
                case .ready:
                    guard once.take(), let port = listener.port?.rawValue else { return }
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port)/\(token)/")!)
                case .failed(let error), .waiting(let error):
                    // `.waiting` is what a denied bind looks like (EPERM in the sandbox without the server entitlement).
                    guard once.take() else { return }
                    listener.cancel()
                    continuation.resume(throwing: Failure.couldNotStart("\(error)"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        baseURL = url
        return url
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            connections.values.forEach { $0.close() }
            connections = [:]
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = Connection(nwConnection, token: token, provider: provider, queue: queue) { [weak self] closed in
            self?.queue.async { self?.connections[ObjectIdentifier(closed)] = nil }
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}

// MARK: One client connection

private final class Connection: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private let provider: LoopbackServer.Provider
    private let queue: DispatchQueue
    private let onClose: (Connection) -> Void
    private var buffer = Data()

    init(_ connection: NWConnection, token: String, provider: @escaping LoopbackServer.Provider, queue: DispatchQueue, onClose: @escaping (Connection) -> Void) {
        self.connection = connection
        self.token = token
        self.provider = provider
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: if let self { onClose(self) }
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            if error != nil || (isComplete && data == nil) { connection.cancel(); return }
            processBufferedRequest()
        }
    }

    /// Handles one complete request if the buffer holds one, otherwise reads more.
    private func processBufferedRequest() {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 * 1024 { connection.cancel() } else { receive() }  // headers that big aren't ours
            return
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        guard let request = HTTPRequest(head: head) else {
            send(status: 400, reason: "Bad Request", keepAlive: false)
            return
        }
        Task { [self] in
            let response = await respond(to: request)
            send(response, keepAlive: request.keepAlive)
        }
    }

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else { return .empty(405, "Method Not Allowed") }
        let prefix = "/\(token)/"
        guard request.path.hasPrefix(prefix) else { return .empty(404, "Not Found") }
        let resourcePath = String(request.path.dropFirst(prefix.count))
        guard let resource = await provider(resourcePath) else { return .empty(404, "Not Found") }
        return HTTPResponse.make(for: request, resource: resource)
    }

    private func send(status: Int, reason: String, keepAlive: Bool) {
        send(.empty(status, reason), keepAlive: keepAlive)
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || !keepAlive { connection.cancel() } else { processBufferedRequest() }
        })
    }
}

// MARK: HTTP pieces (pure, so they are tested without sockets)

struct HTTPRequest: Equatable {
    var method: String
    /// Percent-decoded, without the query.
    var path: String
    /// Lowercased names.
    var headers: [String: String]
    var keepAlive: Bool

    init?(head: String) {
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
        method = String(parts[0])
        let target = String(parts[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let decoded = String(target).removingPercentEncoding else { return nil }
        path = decoded
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        let connection = headers["connection"]?.lowercased()
        keepAlive = parts[2] == "HTTP/1.1" ? connection != "close" : connection == "keep-alive"
    }
}

struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [(String, String)]
    var body: Data

    static func empty(_ status: Int, _ reason: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, headers: [("Content-Length", "0")] + headers, body: Data())
    }

    /// A parsed `Range: bytes=…` header.
    enum ByteRange: Equatable {
        case satisfiable(ClosedRange<Int>)
        case unsatisfiable
        case none
    }

    /// Single ranges only (`a-b`, `a-`, `-n`). Anything else is ignored and the whole resource is sent.
    static func byteRange(_ header: String?, length: Int) -> ByteRange {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return .none }
        let spec = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return .none }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return .none }
        switch (Int(parts[0]), Int(parts[1])) {
        case (let first?, let last?):
            guard first <= last else { return .none }
            return first < length ? .satisfiable(first...min(last, length - 1)) : .unsatisfiable
        case (let first?, nil) where parts[1].isEmpty:
            return first < length ? .satisfiable(first...(length - 1)) : .unsatisfiable
        case (nil, let suffix?) where parts[0].isEmpty:
            guard suffix > 0, length > 0 else { return .unsatisfiable }
            return .satisfiable(max(0, length - suffix)...(length - 1))
        default:
            return .none
        }
    }

    static func make(for request: HTTPRequest, resource: HTTPResource) -> HTTPResponse {
        let length = resource.body.count
        var headers: [(String, String)] = [("Content-Type", resource.contentType), ("Accept-Ranges", "bytes")]
        switch byteRange(request.headers["range"], length: length) {
        case .unsatisfiable:
            return .empty(416, "Range Not Satisfiable", headers: [("Content-Range", "bytes */\(length)")])
        case .satisfiable(let range):
            headers.append(("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(length)"))
            headers.append(("Content-Length", "\(range.count)"))
            let body = request.method == "HEAD" ? Data() : resource.body.subdata(in: range.lowerBound..<range.upperBound + 1)
            return HTTPResponse(status: 206, reason: "Partial Content", headers: headers, body: body)
        case .none:
            headers.append(("Content-Length", "\(length)"))
            return HTTPResponse(status: 200, reason: "OK", headers: headers, body: request.method == "HEAD" ? Data() : resource.body)
        }
    }
}
