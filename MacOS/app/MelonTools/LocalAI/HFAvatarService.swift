import Foundation

/// The Hub avatar endpoints return JSON, not image bytes. Cache by owner so a
/// list with many quants from one publisher does not repeat the same requests.
actor HFAvatarService {
    static let shared = HFAvatarService()
    private var requests: [String: Task<URL?, Never>] = [:]

    func avatarURL(owner: String) async -> URL? {
        guard !owner.isEmpty else { return nil }
        if let request = requests[owner] { return await request.value }
        let request = Task<URL?, Never> {
            for type in ["organizations", "users"] {
                let url = URL(string: "https://huggingface.co/api")!
                    .appendingPathComponent(type).appendingPathComponent(owner).appendingPathComponent("avatar")
                do {
                    let (data, response) = try await NetworkProxy.session().data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
                    if let value = json?["avatarUrl"], let avatar = URL(string: value), avatar.scheme == "https" {
                        return avatar
                    }
                } catch { continue }
            }
            return nil
        }
        requests[owner] = request
        return await request.value
    }
}
