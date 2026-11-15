import Foundation
import os

/// Applies each model's stored system prompt to the requests it serves.
///
/// llama.cpp's router reads its per-model options from `models.ini` and has no
/// "system prompt" option, so the only place a per-model prompt can reach every
/// client is the request body. The gateway is pointed at this loopback
/// listener instead of the router: Chat Completions and Responses bodies get
/// the prompt merged in, every other request is relayed byte for byte.
///
/// One request per connection: the relay always answers with
/// `Connection: close`, which keeps the response framing simple at the cost of
/// a reconnect per call — irrelevant on loopback.
final class SystemPromptProxy: @unchecked Sendable {
    static let shared = SystemPromptProxy()

    /// Hard caps for one relayed request. Without them a client that opens a
    /// socket and writes junk (or one that never sends the blank line) made the
    /// reader buffer grow without bound; a body over the limit was silently
    /// truncated to an empty request instead of being rejected.
    private static let maxHead = 64 << 10
    private static let maxBody = 64 << 20

    /// Concurrent handlers. Each one can hold a buffered request — up to a
    /// 64 MiB body — and the loopback port is published in the gateway config,
    /// so an unthrottled flood of local connections could exhaust memory.
    private static let maxConnections = 32

    /// Long enough for a slow model to stream a whole answer. Applied to both
    /// sockets: a router that accepted the connection and then went silent used
    /// to hold the handler forever.
    private static let ioTimeout = timeval(tv_sec: 600, tv_usec: 0)

    /// Fixed refusal for a connection over `maxConnections`: nothing from the
    /// client is read first, so a flood allocates no request buffers.
    private static let overloadResponse: [UInt8] = Array(
        ("HTTP/1.1 503 Service Unavailable\r\n"
            + "Connection: close\r\n"
            + "Content-Length: 0\r\n\r\n").utf8
    )

    private static let logger = Logger(subsystem: "dev.melontools.app", category: "SystemPromptProxy")

    private let acceptQueue = DispatchQueue(label: "dev.melontools.system-prompt-proxy")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPort: UInt16 = 0
    private var upstreamPort: UInt16 = 0
    private var activeConnections = 0

    /// Last registry read, guarded by `promptLock`. The relay looks a prompt up
    /// on every POST, and the file only changes when settings are saved, so a
    /// `stat` plus a comparison replaces a read-and-decode per request.
    private let promptLock = NSLock()
    private var promptSnapshot: PromptSnapshot?

    private struct PromptSnapshot {
        let url: URL
        let modified: Date?
        let size: Int?
        let entries: [RegistryEntry]?
    }

    private init() {}

    // MARK: - Lifecycle

    /// Port the gateway is pointed at; 0 while the relay is not running.
    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    /// Router the relay forwards to. llama.cpp picks a free port on every
    /// launch, so the engine updates this each time it starts.
    func setUpstream(port: UInt16) {
        lock.lock()
        upstreamPort = port
        lock.unlock()
    }

    /// Binds the listener once. The port ends up in the gateway config, so a
    /// restart would leave the config pointing at a dead socket; an already
    /// running relay therefore just reports its port.
    @discardableResult
    func start() -> UInt16 {
        // The check, the bind and the assignment share one critical section:
        // with the bind outside it, two racing calls both saw `boundPort == 0`
        // and the loser leaked a second listener on an unreachable port.
        lock.lock()
        defer { lock.unlock() }
        if boundPort > 0 { return boundPort }

        guard let fd = Self.bindEphemeral() else { return 0 }
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length) == 0
            }
        }
        guard named else {
            close(fd)
            return 0
        }
        let port = UInt16(bigEndian: addr.sin_port)

        listenFD = fd
        boundPort = port
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
        return port
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        boundPort = 0
        lock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    // MARK: - Prompt plumbing

    /// Request paths whose body carries a conversation the prompt belongs in.
    static func isRewritable(path: String) -> Bool {
        let path = normalizedPath(path)
        return path == "/v1/chat/completions" || path == "/v1/responses"
    }

    /// Merges `prompt` into the body. Chat Completions gets it as — or merged
    /// into — the leading system message; Responses gets it into
    /// `instructions`. Returns nil when the body is not shaped the way the
    /// endpoint promises, so the caller relays the original bytes.
    static func merge(prompt: String, path: String, body: Data) -> Data? {
        guard let raw = try? JSONSerialization.jsonObject(with: body),
              var object = raw as? [String: Any],
              merge(prompt: prompt, path: path, into: &object)
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [])
    }

    /// Rewrites a body the relay already holds as bytes. Parsing once and
    /// returning `[UInt8]` keeps the up-to-64 MiB payload from being wrapped in
    /// `Data` for the model lookup and again for the merge — three copies of
    /// the body per POST.
    private static func rewrittenBody(_ body: [UInt8], path: String) -> [UInt8]? {
        guard let parsed = jsonObject(in: body),
              let modelId = parsed["model"] as? String,
              let prompt = systemPrompt(for: modelId)
        else { return nil }
        var object = parsed
        guard merge(prompt: prompt, path: path, into: &object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else { return nil }
        return [UInt8](data)
    }

    /// The merge itself, on an already parsed object. Returns false when there
    /// is nothing to merge into, matching `merge`'s nil contract.
    private static func merge(
        prompt: String,
        path rawPath: String,
        into object: inout [String: Any]
    ) -> Bool {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }
        // `isRewritable` strips the query; without the same normalisation here
        // `POST /v1/chat/completions?x=1` passed the gate and then silently
        // relayed the body without the system prompt.
        let path = normalizedPath(rawPath)

        if path.hasSuffix("/chat/completions") {
            guard var messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
                return false
            }
            if (messages[0]["role"] as? String) == "system" {
                if let existing = messages[0]["content"] as? String {
                    // Merge into the existing message: some chat templates only
                    // render the first system message, so a second one would be
                    // silently dropped by the model.
                    messages[0]["content"] = existing.isEmpty ? prompt : prompt + "\n\n" + existing
                } else {
                    // Content parts (vision): keep them and add the prompt as
                    // its own leading message instead of rewriting the parts.
                    messages.insert(["role": "system", "content": prompt], at: 0)
                }
            } else {
                messages.insert(["role": "system", "content": prompt], at: 0)
            }
            object["messages"] = messages
        } else if path.hasSuffix("/responses") {
            if object["instructions"] == nil {
                object["instructions"] = prompt
            } else if let instructions = object["instructions"] as? String {
                object["instructions"] = instructions.isEmpty ? prompt : prompt + "\n\n" + instructions
            } else {
                // Some other shape (array of parts) — leave it alone rather
                // than corrupt a request we do not understand.
                return false
            }
        } else {
            return false
        }

        return true
    }

    /// Parses a request body without copying it: the borrowed buffer outlives
    /// the parse, and JSONSerialization copies only what it keeps.
    private static func jsonObject(in body: [UInt8]) -> [String: Any]? {
        body.withUnsafeBytes { raw -> [String: Any]? in
            guard let base = raw.baseAddress else { return nil }
            let data = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                count: raw.count,
                deallocator: .none
            )
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// Model id from an OpenAI-style body; `nil` when there is nothing to look
    /// up (the relay then forwards the request untouched).
    static func modelId(in body: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: body),
              let object = raw as? [String: Any]
        else { return nil }
        return object["model"] as? String
    }

    /// Query string is not part of the route decision.
    private static func normalizedPath(_ rawPath: String) -> String {
        rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
    }

    /// Reads one model's stored prompt straight from the registry file: the
    /// store is main-actor bound and the relay runs on its own threads. The
    /// decoded registry is cached until the file's stamp changes, so a rewrite
    /// from the settings sheet is visible on the next request.
    static func systemPrompt(for modelId: String) -> String? {
        shared.storedPrompt(for: modelId)
    }

    private func storedPrompt(for modelId: String) -> String? {
        let url = LocalPaths.registry
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = attributes?[.size] as? Int

        promptLock.lock()
        defer { promptLock.unlock() }
        if promptSnapshot?.url != url
            || promptSnapshot?.modified != modified
            || promptSnapshot?.size != size {
            let data = try? Data(contentsOf: url)
            promptSnapshot = PromptSnapshot(
                url: url,
                modified: modified,
                size: size,
                entries: data.flatMap { try? JSONDecoder().decode([RegistryEntry].self, from: $0) }
            )
        }
        guard let entries = promptSnapshot?.entries else { return nil }
        let wanted = Self.canonicalModelId(modelId)
        for entry in entries where Self.canonicalModelId(entry.id) == wanted {
            let prompt = entry.userSettings?.systemPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (prompt?.isEmpty == false) ? prompt : nil
        }
        return nil
    }

    private struct RegistryEntry: Decodable {
        let id: String
        let userSettings: Settings?

        struct Settings: Decodable {
            let systemPrompt: String?
        }
    }

    /// Clients may address a local model by its `local/` alias.
    private static func canonicalModelId(_ id: String) -> String {
        id.hasPrefix("local/") ? String(id.dropFirst("local/".count)) : id
    }

    // MARK: - Sockets

    private static func bindEphemeral() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func connect(to port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // Same reason as the client sockets: a router that closes early must
        // surface as a write error, not as a SIGPIPE that kills the app.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Installs the relay's I/O timeout on a socket. Both directions are set:
    /// a stalled peer must fail the handler instead of parking it forever.
    private static func setTimeouts(_ fd: Int32) {
        var timeout = ioTimeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reserves one handler slot. `false` means the relay already serves
    /// `maxConnections` requests and the client must be refused unread.
    private func reserveConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < Self.maxConnections else { return false }
        activeConnections += 1
        return true
    }

    private func releaseConnection() {
        lock.lock()
        activeConnections -= 1
        lock.unlock()
    }

    private var currentUpstream: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return upstreamPort
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            lock.unlock()
            guard fd >= 0 else { return }

            var clientAddress = sockaddr()
            var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &clientAddress, &clientLength)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // A client that hangs up mid-response would otherwise raise SIGPIPE
            // and take the whole app down.
            var noSigPipe: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
            guard reserveConnection() else {
                // Answer and close without reading anything: under a flood the
                // relay must not allocate a reader, a body buffer or a thread
                // for a connection it cannot serve.
                _ = Self.writeAll(client, Self.overloadResponse)
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                self.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        defer {
            close(client)
            releaseConnection()
        }

        // Long enough for a slow model to stream a whole answer.
        Self.setTimeouts(client)

        let reader = Reader(fd: client)
        let request: Request
        switch Self.readRequest(reader) {
        case .closed:
            return
        case .tooLarge:
            Self.respondPlain(
                client,
                status: "413 Payload Too Large",
                message: "The request head or body exceeds the relay limit."
            )
            return
        case .ok(let parsed):
            request = parsed
        }

        let upstream = currentUpstream
        guard upstream > 0 else {
            Self.respondPlain(client, status: "503 Service Unavailable", message: "Local engine is not running.")
            return
        }

        var body = request.body
        if request.method == "POST", Self.isRewritable(path: request.target) {
            body = Self.rewrittenBody(request.body, path: request.target) ?? request.body
        }

        guard let upstreamFD = Self.connect(to: upstream) else {
            Self.respondPlain(client, status: "502 Bad Gateway", message: "Local engine is not reachable.")
            return
        }
        defer { close(upstreamFD) }
        Self.setTimeouts(upstreamFD)

        let head = Self.buildRequestHead(request, bodyLength: body.count, upstream: upstream)
        guard Self.writeAll(upstreamFD, Array(head.utf8)),
              body.isEmpty || Self.writeAll(upstreamFD, body)
        else { return }

        Self.relayResponse(Reader(fd: upstreamFD), to: client)
    }

    // MARK: - HTTP parsing

    private struct Request {
        let method: String
        let target: String
        let headers: [(name: String, value: String)]
        let body: [UInt8]
    }

    private enum RequestRead {
        case ok(Request)
        case tooLarge
        case closed
    }

    private enum BodyRead {
        case body([UInt8])
        case tooLarge
        case incomplete
    }

    private static func readRequest(_ reader: Reader) -> RequestRead {
        let headBytes: [UInt8]
        switch reader.takeHead(limit: maxHead) {
        case .head(let bytes):
            headBytes = bytes
        case .tooLarge:
            return .tooLarge
        case .closed:
            return .closed
        }
        guard let head = String(bytes: headBytes, encoding: .utf8) else { return .closed }

        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .closed }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return .closed }

        var headers: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        let body: [UInt8]
        switch readBody(reader, headers: headers) {
        case .body(let bytes):
            body = bytes
        case .tooLarge:
            return .tooLarge
        case .incomplete:
            return .closed
        }
        return .ok(Request(
            method: String(parts[0]),
            target: String(parts[1]),
            headers: headers,
            body: body
        ))
    }

    private static func readBody(
        _ reader: Reader,
        headers: [(name: String, value: String)]
    ) -> BodyRead {
        if let value = headers.first(where: { $0.name == "transfer-encoding" })?.value,
           value.lowercased().contains("chunked") {
            return readChunked(reader)
        }
        guard let raw = headers.first(where: { $0.name == "content-length" })?.value else {
            return .body([])
        }
        guard let length = Int(raw), length >= 0 else { return .body([]) }
        // A body that does not fit is refused instead of being forwarded as an
        // empty request the gateway would answer with a confusing 400.
        guard length <= maxBody else { return .tooLarge }
        guard length > 0 else { return .body([]) }
        guard let bytes = reader.take(length) else { return .incomplete }
        return .body(bytes)
    }

    private static func readChunked(_ reader: Reader) -> BodyRead {
        var body: [UInt8] = []
        while true {
            let line: [UInt8]
            switch reader.takeLine(limit: maxHead) {
            case .line(let bytes):
                line = bytes
            case .tooLarge:
                return .tooLarge
            case .closed:
                return .incomplete
            }
            guard let sizeText = String(bytes: line, encoding: .utf8)?
                .split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces),
                let size = Int(sizeText, radix: 16), size >= 0
            else { return .incomplete }
            if size == 0 {
                // Trailer section: bounded, terminable by a blank line.
                while true {
                    switch reader.takeLine(limit: maxHead) {
                    case .line(let trailer):
                        if trailer.isEmpty { return .body(body) }
                    case .tooLarge:
                        return .tooLarge
                    case .closed:
                        return .incomplete
                    }
                }
            }
            guard body.count + size <= maxBody else { return .tooLarge }
            guard let chunk = reader.take(size) else { return .incomplete }
            body.append(contentsOf: chunk)
            switch reader.takeLine(limit: maxHead) {
            case .line:
                break
            case .tooLarge:
                return .tooLarge
            case .closed:
                return .incomplete
            }
        }
    }

    private static func buildRequestHead(
        _ request: Request,
        bodyLength: Int,
        upstream: UInt16
    ) -> String {
        // Framing and hop-by-hop headers are ours to decide: the body may have
        // been rewritten, and one request per connection keeps the relay simple.
        let dropped: Set<String> = [
            "content-length", "transfer-encoding", "connection", "keep-alive",
            "proxy-connection", "expect", "upgrade", "host",
        ]
        var out = "\(request.method) \(request.target) HTTP/1.1\r\n"
        for (name, value) in request.headers where !dropped.contains(name) {
            out += "\(name): \(value)\r\n"
        }
        out += "Host: 127.0.0.1:\(upstream)\r\n"
        out += "Content-Length: \(bodyLength)\r\n"
        out += "Connection: close\r\n\r\n"
        return out
    }

    // MARK: - Response relay

    private static func relayResponse(_ reader: Reader, to client: Int32) {
        let headBytes: [UInt8]
        switch reader.takeHead(limit: maxHead) {
        case .head(let bytes):
            headBytes = bytes
        case .tooLarge:
            // A response head larger than the relay's own request cap cannot be
            // relayed without buffering an unbounded amount of memory, and it
            // cannot be parsed either; fail the exchange instead.
            Self.logger.error("upstream response head exceeds \(Self.maxHead) bytes; answering 502")
            Self.respondPlain(
                client,
                status: "502 Bad Gateway",
                message: "Local engine sent an oversized response head."
            )
            return
        case .closed:
            return
        }
        guard let head = String(bytes: headBytes, encoding: .utf8) else { return }

        var lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return }
        lines.removeFirst()

        var headers: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        // The client asked for a keep-alive connection; this relay closes after
        // one exchange, and saying so is cheaper than framing every response.
        var rewritten = statusLine + "\r\n"
        let hopByHop = ["connection", "keep-alive", "proxy-connection"]
        for (name, value) in headers where !hopByHop.contains(name.lowercased()) {
            rewritten += "\(name): \(value)\r\n"
        }
        rewritten += "Connection: close\r\n\r\n"
        guard writeAll(client, Array(rewritten.utf8)) else { return }

        let chunked = headers.contains {
            $0.name.lowercased() == "transfer-encoding" && $0.value.lowercased().contains("chunked")
        }
        if chunked {
            relayChunked(reader, to: client)
        } else if let raw = headers.first(where: { $0.name.lowercased() == "content-length" })?.value,
                  let length = Int(raw) {
            relayBody(reader, to: client, length: length)
        } else {
            relayToEOF(reader, to: client)
        }
    }

    private static func relayChunked(_ reader: Reader, to client: Int32) {
        while true {
            guard let line = reader.takeLine() else { return }
            guard writeAll(client, line + [13, 10]) else { return }
            let text = String(bytes: line, encoding: .utf8) ?? ""
            let sizeText = (text.split(separator: ";").first.map(String.init) ?? text)
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16) else { return }
            if size == 0 {
                // Trailers, if any, end with an empty line.
                while let trailer = reader.takeLine() {
                    let written = writeAll(client, trailer + [13, 10])
                    if !written || trailer.isEmpty { return }
                }
                return
            }
            guard let chunk = reader.take(size) else { return }
            guard writeAll(client, chunk) else { return }
            guard let terminator = reader.takeLine() else { return }
            guard writeAll(client, terminator + [13, 10]) else { return }
        }
    }

    private static func relayBody(_ reader: Reader, to client: Int32, length: Int) {
        var remaining = length
        while remaining > 0 {
            let step = min(remaining, 16_384)
            guard let chunk = reader.take(step) else { return }
            guard writeAll(client, chunk) else { return }
            remaining -= chunk.count
        }
    }

    private static func relayToEOF(_ reader: Reader, to client: Int32) {
        while let chunk = reader.takeUpTo(16_384), !chunk.isEmpty {
            guard writeAll(client, chunk) else { return }
        }
    }

    private static func respondPlain(_ client: Int32, status: String, message: String) {
        let body = #"{"error":{"message":"\#(message)"}}"#
        let response = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        _ = writeAll(client, Array(response.utf8))
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if written < 0, errno == EINTR { continue }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    /// Buffered reader over a socket. Everything the relay needs — headers,
    /// Content-Length bodies, chunked bodies — goes through it, so a partially
    /// read buffer never loses bytes between parsing steps.
    private final class Reader {
        private let fd: Int32
        private var buffer: [UInt8] = []
        private var eof = false

        init(fd: Int32) {
            self.fd = fd
        }

        private func fill() -> Bool {
            guard !eof else { return false }
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let readCount = read(fd, &chunk, chunk.count)
            if readCount <= 0 {
                eof = true
                return false
            }
            buffer.append(contentsOf: chunk[0..<readCount])
            return true
        }

        func take(_ count: Int) -> [UInt8]? {
            while buffer.count < count {
                if !fill() { return nil }
            }
            let out = Array(buffer.prefix(count))
            buffer.removeFirst(count)
            return out
        }

        func takeUpTo(_ count: Int) -> [UInt8]? {
            if buffer.isEmpty, !fill() { return nil }
            let size = min(count, buffer.count)
            let out = Array(buffer.prefix(size))
            buffer.removeFirst(size)
            return out
        }

        enum LineResult {
            case line([UInt8])
            case tooLarge
            case closed
        }

        enum HeadResult {
            case head([UInt8])
            case tooLarge
            case closed
        }

        func takeLine(limit: Int) -> LineResult {
            while true {
                if let index = Self.crlfIndex(buffer) {
                    guard index <= limit else { return .tooLarge }
                    let line = Array(buffer[..<index])
                    buffer.removeFirst(index + 2)
                    return .line(line)
                }
                if buffer.count > limit { return .tooLarge }
                if !fill() { return .closed }
            }
        }

        func takeLine() -> [UInt8]? {
            if case .line(let line) = takeLine(limit: .max) { return line }
            return nil
        }

        func takeHead(limit: Int) -> HeadResult {
            while true {
                if let end = Self.headerEndIndex(buffer) {
                    guard end <= limit else { return .tooLarge }
                    let head = Array(buffer[..<end])
                    buffer.removeFirst(end)
                    return .head(head)
                }
                if buffer.count > limit { return .tooLarge }
                if !fill() { return .closed }
            }
        }

        private static func crlfIndex(_ bytes: [UInt8]) -> Int? {
            guard bytes.count >= 2 else { return nil }
            for index in 0..<(bytes.count - 1) where bytes[index] == 13 && bytes[index + 1] == 10 {
                return index
            }
            return nil
        }

        /// Index just past the blank line that ends a header block.
        private static func headerEndIndex(_ bytes: [UInt8]) -> Int? {
            guard bytes.count >= 4 else { return nil }
            for index in 0..<(bytes.count - 3)
            where bytes[index] == 13 && bytes[index + 1] == 10
                && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
                return index + 4
            }
            return nil
        }
    }
}
