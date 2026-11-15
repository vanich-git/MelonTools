import Foundation

/// One downloadable archive of an official llama.cpp build.
struct RuntimeCatalogAsset: Identifiable, Equatable {
    let name: String
    let size: Int64
    let sha256: String
    let downloadURL: URL

    var id: String { name }
}

/// A llama.cpp GitHub release that has both macOS slices.
struct RuntimeCatalogRelease: Identifiable, Equatable {
    let tag: String
    let title: String
    let publishedAt: Date?
    let arm64: RuntimeCatalogAsset
    let x64: RuntimeCatalogAsset

    var id: String { tag }
    var totalBytes: Int64 { arm64.size + x64.size }
}

/// Reads the official `ggml-org/llama.cpp` release list.
///
/// The digest of every asset comes from the same GitHub API response, so a
/// download is checked against the publisher's metadata instead of a value
/// copied into the app. Releases without both macOS slices or without a
/// SHA-256 digest are not offered at all.
@MainActor
final class RuntimeCatalogService: ObservableObject {
    @Published private(set) var releases: [RuntimeCatalogRelease] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var loadedAt: Date?
    private static let apiURL = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30")!

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, !releases.isEmpty, let loadedAt,
           Date().timeIntervalSince(loadedAt) < 300 {
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            var request = URLRequest(url: Self.apiURL)
            request.timeoutInterval = 25
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MelonTools/6.0.0", forHTTPHeaderField: "User-Agent")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (data, response) = try await NetworkProxy.session().data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RuntimePackageInstaller.failure(L("GitHub returned an invalid response."))
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                throw RuntimePackageInstaller.failure(
                    L("GitHub API rate limit reached. Try again in a few minutes.")
                )
            }
            guard http.statusCode == 200 else {
                throw RuntimePackageInstaller.failure(L("GitHub API request failed."))
            }
            releases = try Self.parse(data)
            loadedAt = Date()
            if releases.isEmpty {
                error = L("No downloadable macOS runtimes found in recent releases.")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Kept separate from the network call so the filtering rules are testable.
    nonisolated static func parse(_ data: Data) throws -> [RuntimeCatalogRelease] {
        let payloads = try JSONDecoder().decode([ReleasePayload].self, from: data)
        let releases: [RuntimeCatalogRelease] = payloads.compactMap { payload in
            // llama.cpp publishes its nightly builds as GitHub prereleases,
            // so only drafts are excluded.
            guard !payload.draft else { return nil }
            let tag = payload.tagName
            let armName = "llama-\(tag)-bin-macos-arm64.tar.gz"
            let x64Name = "llama-\(tag)-bin-macos-x64.tar.gz"
            guard let armPayload = payload.assets.first(where: { $0.name == armName }),
                  let x64Payload = payload.assets.first(where: { $0.name == x64Name }),
                  let armDigest = sha256(from: armPayload.digest),
                  let x64Digest = sha256(from: x64Payload.digest),
                  let armURL = httpsURL(armPayload.browserDownloadURL),
                  let x64URL = httpsURL(x64Payload.browserDownloadURL),
                  armPayload.size > 0, x64Payload.size > 0 else {
                return nil
            }
            return RuntimeCatalogRelease(
                tag: tag,
                title: payload.name,
                publishedAt: parseDate(payload.publishedAt),
                arm64: RuntimeCatalogAsset(name: armName, size: armPayload.size,
                                           sha256: armDigest, downloadURL: armURL),
                x64: RuntimeCatalogAsset(name: x64Name, size: x64Payload.size,
                                         sha256: x64Digest, downloadURL: x64URL)
            )
        }
        return Array(releases.prefix(20))
    }

    nonisolated private static func sha256(from digest: String?) -> String? {
        guard let digest else { return nil }
        let value = digest.lowercased()
        guard value.hasPrefix("sha256:") else { return nil }
        let hex = String(value.dropFirst("sha256:".count))
        guard RuntimePackageInstaller.validDigest(hex) else { return nil }
        return hex
    }

    nonisolated private static func httpsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }

    nonisolated private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private struct ReleasePayload: Decodable {
    let tagName: String
    let name: String
    let publishedAt: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [AssetPayload]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }
}

private struct AssetPayload: Decodable {
    let name: String
    let size: Int64
    let digest: String?
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case digest
        case browserDownloadURL = "browser_download_url"
    }
}
