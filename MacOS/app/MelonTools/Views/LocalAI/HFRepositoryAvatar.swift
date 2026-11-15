import SwiftUI

struct HFRepositoryAvatar: View {
    let owner: String
    var size: CGFloat = 30
    @State private var avatarURL: URL?

    var body: some View {
        AsyncImage(url: avatarURL) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Text(String(owner.prefix(1)).uppercased())
                .font(MTTheme.body(size * 0.45, weight: .semibold))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.06))
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
        .task(id: owner) {
            let url = await HFAvatarService.shared.avatarURL(owner: owner)
            guard !Task.isCancelled else { return }
            avatarURL = url
        }
    }
}
