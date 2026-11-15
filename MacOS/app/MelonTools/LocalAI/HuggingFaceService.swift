import Foundation

/// Item in Hugging Face model search results.
struct HFModelSearchResult: Identifiable, Codable, Equatable, Hashable {
    let id: String // e.g. "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF"
    let author: String?
    let description: String?
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let tags: [String]?
    let privateRepo: Bool?
    /// `gated` is `false`, `"auto"` or `"manual"`; anything other than false
    /// means the repository needs an accepted licence.
    let gated: Bool?

    init(
        id: String,
        author: String?,
        description: String?,
        downloads: Int?,
        likes: Int?,
        lastModified: String?,
        tags: [String]?,
        privateRepo: Bool?,
        gated: Bool? = nil
    ) {
        self.id = id
        self.author = author
        self.description = description
        self.downloads = downloads
        self.likes = likes
        self.lastModified = lastModified
        self.tags = tags
        self.privateRepo = privateRepo
        self.gated = gated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads)
        likes = try container.decodeIfPresent(Int.self, forKey: .likes)
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        privateRepo = try container.decodeIfPresent(Bool.self, forKey: .privateRepo)
        // `gated` arrives as a bool or as "auto"/"manual".
        if let flag = try? container.decodeIfPresent(Bool.self, forKey: .gated) {
            gated = flag
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .gated) {
            gated = text.lowercased() != "false"
        } else {
            gated = nil
        }
    }

    var displayName: String {
        if let name = id.split(separator: "/").last {
            return String(name)
        }
        return id
    }

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case description
        case downloads
        case likes
        case lastModified
        case tags
        case privateRepo = "private"
        case gated
    }
}

/// A specific GGUF file available in a Hugging Face repository.
struct HFGGUFFile: Identifiable, Equatable {
    var id: String { rfilename }
    let rfilename: String
    let size: UInt64
    let downloadURL: URL
    let quantization: String
    let estimation: MemoryEstimation
    /// Authoritative LFS digest, when Hugging Face publishes one.
    var sha256: String?
    /// Part number of a split model, so the catalog can offer the whole set
    /// instead of one unusable shard.
    var shard: LocalModelStore.ShardInfo?

    /// All files of the same split model inside one repository.
    var isShard: Bool { shard != nil }

    var formattedSize: String {
        LocalHardwareService.formatBytes(size)
    }
}

/// Detailed information about a Hugging Face model repository.
struct HFModelDetails: Identifiable, Equatable {
    let id: String
    let author: String
    let description: String
    let downloads: Int?
    let likes: Int?
    let license: String?
    let ggufFiles: [HFGGUFFile]
    var architecture: String? = nil
    var parameterCount: UInt64? = nil
    var capabilities: [String] = []
    var lastModified: String? = nil
}

/// Service interacting with Hugging Face Hub APIs.
enum HuggingFaceService {
    private static let baseURL = URL(string: "https://huggingface.co/api")!

    // MARK: - Transport

    /// Hub metadata is small, so a stuck request must fail fast instead of
    /// holding the catalogue for the session default.
    private static let requestTimeout: TimeInterval = 30
    /// One retry only, and only for throttling or a server-side failure.
    private static let retryDelay: UInt64 = 1_000_000_000

    /// One Hub round trip. The body stays with the status so a failure can
    /// explain itself instead of collapsing into "status code N".
    private struct HubReply {
        let data: Data
        let status: Int
        let url: URL

        var isSuccess: Bool { (200...299).contains(status) }
        var isTransient: Bool { status == 429 || (500...599).contains(status) }

        var error: NSError {
            let body = String(decoding: data.prefix(512), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = body.isEmpty
                ? "Hugging Face returned status code \(status)"
                : "Hugging Face returned status code \(status): \(body)"
            return NSError(
                domain: "HuggingFaceService",
                code: status,
                userInfo: [
                    NSLocalizedDescriptionKey: description,
                    NSURLErrorKey: url,
                    "HTTPStatus": status
                ]
            )
        }
    }

    /// Sends one Hub request, retrying a throttled or failed one exactly once.
    private static func reply(for request: URLRequest) async throws -> HubReply {
        var request = request
        request.timeoutInterval = Self.requestTimeout
        var reply = try await send(request)
        if !reply.isSuccess, reply.isTransient {
            try await Task.sleep(nanoseconds: Self.retryDelay)
            reply = try await send(request)
        }
        return reply
    }

    private static func send(_ request: URLRequest) async throws -> HubReply {
        let (data, response) = try await NetworkProxy.session().data(for: request)
        guard let http = response as? HTTPURLResponse, let url = request.url else {
            throw URLError(.badServerResponse)
        }
        return HubReply(data: data, status: http.statusCode, url: url)
    }

    /// Sort orders Hugging Face exposes for its model index (§7.2).
    enum SortOrder: String, CaseIterable, Identifiable {
        case downloads
        case likes
        case lastModified
        case trendingScore

        var id: String { rawValue }

        var title: String {
            switch self {
            case .downloads: return "Downloads"
            case .likes: return "Likes"
            case .lastModified: return "Recently updated"
            case .trendingScore: return "Recommended"
            }
        }
    }

    /// Search models on Hugging Face Hub with GGUF filter.
    ///
    /// - Parameter offset: result offset for pagination; the catalog loads
    ///   further pages with "Load more" instead of pulling the whole index.
    static func searchModels(
        query: String,
        limit: Int = 30,
        sort: SortOrder = .downloads,
        offset: Int = 0,
        token: String? = nil
    ) async throws -> [HFModelSearchResult] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("models"),
            resolvingAgainstBaseURL: true
        ) else {
            throw URLError(.badURL)
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "full", value: "true"),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if offset > 0 {
            queryItems.append(URLQueryItem(name: "offset", value: "\(offset)"))
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: trimmed))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let reply = try await Self.reply(for: request)
        guard reply.isSuccess else { throw reply.error }

        let decoder = JSONDecoder()
        return try decoder.decode([HFModelSearchResult].self, from: reply.data)
    }

    /// Extracts `owner/repo` from a pasted link or bare identifier.
    ///
    /// Users paste `https://huggingface.co/Qwen/Qwen3.5-2B-GGUF`, a trailing
    /// `/tree/main/...` path, or just the id; all of them must resolve.
    static func repositoryID(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.contains("://") {
            guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http",
                  url.host?.lowercased() == "huggingface.co" else { return nil }
            text = url.path
        } else if text.hasPrefix("huggingface.co/") {
            text = String(text.dropFirst("huggingface.co/".count))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Drop a trailing sub-path such as `tree/main/file.gguf`.
        for marker in ["/tree/", "/blob/", "/resolve/", "?"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        let parts = text.split(separator: "/").map(String.init)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count >= 2,
              parts.prefix(2).allSatisfy({ part in
                  !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy(allowed.contains)
              }) else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Fetch details and enumerate GGUF files for a repository.
    static func fetchModelDetails(
        repoId: String,
        token: String? = nil
    ) async throws -> HFModelDetails {
        // `blobs=true` is what makes the API include per-file `size`/`lfs`
        // metadata. Without it every GGUF sibling reports no size at all,
        // which is what left downloads stuck at 0% with a "0 KB" total.
        var components = URLComponents(
            url: baseURL.appendingPathComponent("models").appendingPathComponent(repoId),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = components?.url else {
            throw NSError(domain: "HuggingFaceService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid model details URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let reply = try await Self.reply(for: request)
        guard reply.isSuccess else { throw reply.error }

        return try await parseModelDetails(reply.data, repoId: repoId)
    }

    /// Keeps absent Hub metadata absent. No model-name or weight-size inference.
    static func parseModelDetails(_ data: Data, repoId: String) async throws -> HFModelDetails {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let card = json["cardData"] as? [String: Any] ?? [:]
        let config = json["config"] as? [String: Any] ?? [:]
        let gguf = json["gguf"] as? [String: Any] ?? [:]
        let safetensors = json["safetensors"] as? [String: Any] ?? [:]
        let tags = json["tags"] as? [String] ?? []
        let siblings = json["siblings"] as? [[String: Any]] ?? []
        let sizes = Dictionary(siblings.compactMap { sibling -> (String, UInt64)? in
            guard let name = sibling["rfilename"] as? String else { return nil }
            return (name, ggufFileSize(fromSibling: sibling))
        }, uniquingKeysWith: { first, _ in first })
        var files: [HFGGUFFile] = []
        for sibling in siblings {
            guard let name = sibling["rfilename"] as? String,
                  name.lowercased().hasSuffix(".gguf"),
                  let url = downloadURL(repoId: repoId, rfilename: name) else { continue }
            let shard = LocalModelStore.shardInfo(for: name)
            let size = sizes[name] ?? 0
            // Evaluate the complete split model, never one deceptively small shard.
            let groupSizes = shard.map { shard in
                sizes.filter { entry in
                    let part = LocalModelStore.shardInfo(for: entry.key)
                    return part?.base == shard.base && part?.total == shard.total
                        && (entry.key as NSString).deletingLastPathComponent == (name as NSString).deletingLastPathComponent
                }.map(\.value)
            } ?? [size]
            let total = groupSizes.contains(0) ? 0 : groupSizes.reduce(0, +)
            let estimation = await LocalHardwareService.shared.estimateMemory(weightsSize: total)
            let lfs = sibling["lfs"] as? [String: Any]
            files.append(HFGGUFFile(
                rfilename: name, size: size, downloadURL: url,
                quantization: extractQuantization(from: name), estimation: estimation,
                sha256: (lfs?["sha256"] as? String)?.lowercased(), shard: shard
            ))
        }
        let architecture = gguf["architecture"] as? String
            ?? config["model_type"] as? String
            ?? (config["architectures"] as? [String])?.first
        let parameters = (gguf["total"] as? NSNumber)?.uint64Value
            ?? (safetensors["total"] as? NSNumber)?.uint64Value
        let capabilities = ["text-generation", "image-text-to-text", "text-to-image", "automatic-speech-recognition", "feature-extraction", "tool-use", "reasoning"]
            .filter { tags.contains($0) || (json["pipeline_tag"] as? String) == $0 }
        return HFModelDetails(
            id: repoId,
            author: json["author"] as? String ?? String(repoId.split(separator: "/").first ?? ""),
            description: card["description"] as? String ?? json["description"] as? String ?? "",
            downloads: json["downloads"] as? Int, likes: json["likes"] as? Int,
            license: card["license"] as? String ?? tags.first(where: { $0.hasPrefix("license:") }).map { String($0.dropFirst(8)) },
            ggufFiles: files.sorted { $0.size < $1.size },
            architecture: architecture, parameterCount: parameters, capabilities: capabilities,
            lastModified: json["lastModified"] as? String
        )
    }

    static func fetchReadme(repoId: String, token: String? = nil) async throws -> String {
        guard let url = downloadURL(repoId: repoId, rfilename: "README.md") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let reply = try await Self.reply(for: request)
        if reply.status == 404 { return "" }
        guard reply.isSuccess else { throw reply.error }
        guard let text = String(data: reply.data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return text
    }

    /// Percent-encoded resolve URL for one repository file.
    ///
    /// Built from components rather than string interpolation: a file called
    /// `model#1.gguf` otherwise produced a URL whose path stopped at `model`
    /// and whose fragment carried the rest.
    static func downloadURL(repoId: String, rfilename: String) -> URL? {
        let repo = repoId.split(separator: "/").map(String.init)
        guard repo.count == 2, repositoryID(from: repoId) == repoId else { return nil }
        let fileComponents = rfilename.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !fileComponents.isEmpty,
              fileComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        func encode(_ component: String) -> String? {
            component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))
        }
        guard let owner = encode(repo[0]), let name = encode(repo[1]) else { return nil }
        var path = "/\(owner)/\(name)/resolve/main"
        for component in fileComponents {
            guard let encoded = encode(component) else { return nil }
            path += "/\(encoded)"
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.percentEncodedPath = path
        return components.url
    }

    /// Files that belong to the same split model as `file`.
    static func splitGroup(for file: HFGGUFFile, in files: [HFGGUFFile]) -> [HFGGUFFile] {
        guard let shard = file.shard else { return [file] }
        let directory = (file.rfilename as NSString).deletingLastPathComponent
        let siblings = files.filter {
            $0.shard?.base == shard.base && $0.shard?.total == shard.total
                && ($0.rfilename as NSString).deletingLastPathComponent == directory
        }
        return siblings.isEmpty ? [file] : siblings.sorted { ($0.shard?.index ?? 0) < ($1.shard?.index ?? 0) }
    }

    /// Byte size of one `siblings` entry. Hugging Face reports it under `lfs`
    /// for large files and at the top level otherwise; either may be missing.
    static func ggufFileSize(fromSibling sibling: [String: Any]) -> UInt64 {
        let lfs = sibling["lfs"] as? [String: Any]
        return (lfs?["size"] as? NSNumber)?.uint64Value
            ?? (sibling["size"] as? NSNumber)?.uint64Value
            ?? 0
    }

    static func extractQuantization(from filename: String) -> String {
        let quants = ["Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_0", "Q4_1", "Q4_K_S", "Q4_K_M", "Q5_0", "Q5_1", "Q5_K_S", "Q5_K_M", "Q6_K", "Q8_0", "F16", "BF16", "IQ3_M", "IQ4_XS"]
        let upper = filename.uppercased()
        // Longest match first: "F16" is a substring of "BF16", so the
        // declared order would mislabel every BF16 file as F16.
        for q in quants.sorted(by: { $0.count > $1.count }) {
            if upper.contains(q) {
                return q
            }
        }
        return "GGUF"
    }
}
