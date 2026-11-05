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
    let downloads: Int
    let likes: Int
    let license: String?
    let ggufFiles: [HFGGUFFile]
}

/// Service interacting with Hugging Face Hub APIs.
enum HuggingFaceService {
    private static let baseURL = URL(string: "https://huggingface.co/api")!

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
            case .trendingScore: return "Trending"
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

        let (data, response) = try await NetworkProxy.session().data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "HuggingFaceService", code: status, userInfo: [NSLocalizedDescriptionKey: "Hugging Face returned status code \(status)"])
        }

        let decoder = JSONDecoder()
        return try decoder.decode([HFModelSearchResult].self, from: data)
    }

    /// Extracts `owner/repo` from a pasted link or bare identifier.
    ///
    /// Users paste `https://huggingface.co/Qwen/Qwen3.5-2B-GGUF`, a trailing
    /// `/tree/main/...` path, or just the id; all of them must resolve.
    static func repositoryID(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let range = text.range(of: "huggingface.co/") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Drop a trailing sub-path such as `tree/main/file.gguf`.
        for marker in ["/tree/", "/blob/", "/resolve/", "?"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
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

        let (data, response) = try await NetworkProxy.session().data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "HuggingFaceService", code: status, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch model details (status: \(status))"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HuggingFaceService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
        }

        let author = json["author"] as? String ?? (repoId.split(separator: "/").first.map(String.init) ?? "Unknown")
        let description = (json["cardData"] as? [String: Any])?["description"] as? String ?? ""
        let downloads = json["downloads"] as? Int ?? 0
        let likes = json["likes"] as? Int ?? 0
        let license = (json["cardData"] as? [String: Any])?["license"] as? String

        var ggufFiles: [HFGGUFFile] = []
        let siblings = json["siblings"] as? [[String: Any]] ?? []

        for sibling in siblings {
            guard let rfilename = sibling["rfilename"] as? String,
                  rfilename.lowercased().hasSuffix(".gguf") else {
                continue
            }

            // `#` and `?` in a repository file name used to become URL
            // fragment/query and fetched a different object (or 404).
            guard let downloadURL = downloadURL(repoId: repoId, rfilename: rfilename) else { continue }
            let quant = extractQuantization(from: rfilename)
            // LFS-backed files carry their size under `lfs`, while small or
            // non-LFS siblings only report a top-level `size`. Reading just the
            // LFS branch leaves GGUF entries at zero bytes, which breaks the
            // progress bar and shows "0 KB" for the total.
            let size = ggufFileSize(fromSibling: sibling)

            let estimation = await LocalHardwareService.shared.estimateMemory(
                weightsSize: size > 0 ? size : 4 * 1024 * 1024 * 1024
            )

            let lfs = sibling["lfs"] as? [String: Any]
            ggufFiles.append(HFGGUFFile(
                rfilename: rfilename,
                size: size,
                downloadURL: downloadURL,
                quantization: quant,
                estimation: estimation,
                sha256: (lfs?["sha256"] as? String)?.lowercased(),
                shard: LocalModelStore.shardInfo(for: rfilename)
            ))
        }

        return HFModelDetails(
            id: repoId,
            author: author,
            description: description,
            downloads: downloads,
            likes: likes,
            license: license,
            ggufFiles: ggufFiles.sorted(by: { $0.size < $1.size })
        )
    }

    /// Percent-encoded resolve URL for one repository file.
    ///
    /// Built from components rather than string interpolation: a file called
    /// `model#1.gguf` otherwise produced a URL whose path stopped at `model`
    /// and whose fragment carried the rest.
    static func downloadURL(repoId: String, rfilename: String) -> URL? {
        let repo = repoId.split(separator: "/").map(String.init)
        guard repo.count == 2 else { return nil }
        let fileComponents = rfilename.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !fileComponents.isEmpty,
              fileComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        func encode(_ component: String) -> String? {
            component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
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
        let siblings = files.filter { $0.shard?.base == shard.base && $0.shard?.total == shard.total }
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
