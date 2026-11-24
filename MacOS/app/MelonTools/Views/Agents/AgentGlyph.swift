import AppKit
import SwiftUI

/// Vendor marks shipped in `Resources/agent-<id>.png`.
///
/// The catalogue stores a flat PNG per agent. Marks that are a single colour
/// are drawn as a template and tinted with the group accent; marks that carry
/// their own palette keep it.
enum AgentLogo {
    /// Marks whose colour is part of the identity. Everything else is a flat
    /// silhouette that reads better tinted.
    private static let colored: Set<String> = [
        "aider", "amp", "antigravity", "chatbox", "chatgpt", "cherry", "codex",
        "continue", "crush", "droid", "goose", "jetbrains", "kiro", "lobe",
        "openhands", "openwebui", "void", "vscode",
    ]

    private static let cache = NSCache<NSString, NSImage>()

    static func image(for id: String) -> NSImage? {
        if let cached = cache.object(forKey: id as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: "agent-\(id)", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: id as NSString)
        return image
    }

    static func isColored(_ id: String) -> Bool { colored.contains(id) }
}

/// The leading tile of an agent row and the large mark of its detail card.
struct AgentGlyph: View {
    let agent: AgentDefinition
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            if !AgentLogo.isColored(agent.id) {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
            mark
        }
        .frame(width: size, height: size)
        .overlay {
            if !AgentLogo.isColored(agent.id) {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        if let image = AgentLogo.image(for: agent.id) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(size * (AgentLogo.isColored(agent.id) ? 0 : 0.16))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: agent.systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(agent.tint)
        }
    }
}
