import Foundation

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

    private let acceptQueue = DispatchQueue(label: "dev.melontools.system-prompt-proxy")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPort: UInt16 = 0
    private var upstreamPort: UInt16 = 0

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
        lock.lock()
        if boundPort > 0 {
            let running = boundPort
            lock.unlock()
            return running
        }
        lock.unlock()

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

        lock.lock()
        listenFD = fd
        boundPort = port
        lock.unlock()

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
        let path = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return path == "/v1/chat/completions" || path == "/v1/responses"
    }

    /// Merges `prompt` into the body. Chat Completions gets it as — or merged
    /// into — the leading system message; Responses gets it into
    /// `instructions`. Returns nil when the body is not shaped the way the
    /// endpoint promises, so the caller relays the original bytes.
    static func merge(prompt: String, path: String, body: Data) -> Data? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: body),
              var object = raw as? [String: Any]
        else { return nil }

        if path.hasSuffix("/chat/completions") {
            guard var messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
                return nil
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
                return nil
            }
        } else {
            return nil
        }

        return try? JSONSerialization.data(withJSONObject: object, options: [])
    }

    /// Model id from an OpenAI-style body; `nil` when there is nothing to look
    /// up (the relay then forwards the request untouched).
    static func modelId(in body: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: body),
              let object = raw as? [String: Any]
        else { return nil }
        return object["model"] as? String
    }

    /// Reads one model's stored prompt straight from the registry file: the
    /// store is main-actor bound and the relay runs on its own threads. The
    /// registry holds a handful of small entries, so re-reading it per request
    /// is cheaper than plumbing a cache across isolation domains.
    static func systemPrompt(for modelId: String) -> String? {
        guard let data = try? Data(contentsOf: LocalPaths.registry),
              let entries = try? JSONDecoder().decode([RegistryEntry].self, from: data)
        else { return nil }
        let wanted = canonicalModelId(modelId)
        for entry in entries where canonicalModelId(entry.id) == wanted {
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
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }

        // Long enough for a slow model to stream a whole answer.
        var timeout = timeval(tv_sec: 600, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let reader = Reader(fd: client)
        guard let request = Self.readRequest(reader) else { return }

        let upstream = currentUpstream
        guard upstream > 0 else {
            Self.respondPlain(client, status: "503 Service Unavailable", message: "Local engine is not running.")
            return
        }

        var body = request.body
        if request.method == "POST", Self.isRewritable(path: request.target),
           let modelId = Self.modelId(in: Data(body)),
           let prompt = Self.systemPrompt(for: modelId),
           let rewritten = Self.merge(prompt: prompt, path: request.target, body: Data(body)) {
            body = [UInt8](rewritten)
        }

        guard let upstreamFD = Self.connect(to: upstream) else {
            Self.respondPlain(client, status: "502 Bad Gateway", message: "Local engine is not reachable.")
            return
        }
        defer { close(upstreamFD) }

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

    private static func readRequest(_ reader: Reader) -> Request? {
        guard let headBytes = reader.takeHead(),
              let head = String(bytes: headBytes, encoding: .utf8)
        else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }

        var headers: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        let body = readBody(reader, headers: headers)
        return Request(
            method: String(parts[0]),
            target: String(parts[1]),
            headers: headers,
            body: body
        )
    }

    private static func readBody(
        _ reader: Reader,
        headers: [(name: String, value: String)]
    ) -> [UInt8] {
        if let value = headers.first(where: { $0.name == "transfer-encoding" })?.value,
           value.lowercased().contains("chunked") {
            return readChunked(reader)
        }
        guard let raw = headers.first(where: { $0.name == "content-length" })?.value,
              let length = Int(raw), length > 0, length <= 64 << 20
        else { return [] }
        return reader.take(length) ?? []
    }

    private static func readChunked(_ reader: Reader) -> [UInt8] {
        var body: [UInt8] = []
        while body.count <= 64 << 20 {
            guard let line = reader.takeLine(),
                  let sizeText = String(bytes: line, encoding: .utf8)?
                      .split(separator: ";").first.map(String.init)?
                      .trimmingCharacters(in: .whitespaces),
                  let size = Int(sizeText, radix: 16)
            else { return body }
            if size == 0 {
                _ = reader.takeLine()
                return body
            }
            guard let chunk = reader.take(size) else { return body }
            body.append(contentsOf: chunk)
            _ = reader.takeLine()
        }
        return body
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
        guard let headBytes = reader.takeHead(),
              let head = String(bytes: headBytes, encoding: .utf8)
        else { return }

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

        func takeLine() -> [UInt8]? {
            while true {
                if let index = Self.crlfIndex(buffer) {
                    let line = Array(buffer[..<index])
                    buffer.removeFirst(index + 2)
                    return line
                }
                if !fill() { return nil }
            }
        }

        func takeHead() -> [UInt8]? {
            while true {
                if let end = Self.headerEndIndex(buffer) {
                    let head = Array(buffer[..<end])
                    buffer.removeFirst(end)
                    return head
                }
                if !fill() { return nil }
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
