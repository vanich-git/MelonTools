import SwiftUI

struct HFRepositoryRow: View {
    let repo: HFModelSearchResult

    var body: some View {
        HStack(spacing: 8) {
            HFRepositoryAvatar(owner: repo.author ?? String(repo.id.split(separator: "/").first ?? ""))
            VStack(alignment: .leading, spacing: 3) {
                Text(repo.displayName)
                    .font(MTTheme.body(11.5, weight: .semibold))
                    .lineLimit(1)
                Text(repo.description.flatMap { $0.isEmpty ? nil : $0 } ?? repo.author ?? repo.id)
                    .font(MTTheme.body(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let likes = repo.likes { Label(likes.formatted(.number.notation(.compactName)), systemImage: "star") }
                    if let downloads = repo.downloads { Label(downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down") }
                    Spacer(minLength: 0)
                    if let date = Self.date(repo.lastModified) {
                        Text(date, style: .relative).lineLimit(1)
                    }
                }
                .font(MTTheme.body(9.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .help(repo.id)
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: iso) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: iso)
    }
}
