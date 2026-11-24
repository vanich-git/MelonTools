import SwiftUI

// MARK: - Grouped list

/// A grouped list plate: one rounded surface whose rows are separated by a
/// hairline, the shape Magpie and the macOS Settings panes use. Rows never draw
/// their own background, so the plate reads as a single control.
struct MTListCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .fill(MTTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
        )
    }
}

/// Hairline between two rows of an `MTListCard`.
struct MTRowSeparator: View {
    var inset: CGFloat = MTTheme.s3

    var body: some View {
        Rectangle()
            .fill(MTTheme.borderColor.opacity(0.6))
            .frame(height: 0.75)
            .padding(.leading, inset)
    }
}

// MARK: - Row

/// One clickable row of a grouped list: leading glyph, title with an optional
/// second line, arbitrary trailing content and a chevron. The whole row is the
/// hit target, and hover paints the same soft highlight the sidebar uses.
struct MTRow<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    /// Replaces the SF Symbol tile when the row wants a vendor mark.
    var leading: AnyView? = nil
    var accent: Color = MTTheme.textSecondary
    var showsChevron: Bool = true
    var isEnabled: Bool = true
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    @State private var hovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
        .onHover { hovered = $0 && action != nil }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MTTheme.textTertiary)
    }

    private var row: some View {
        HStack(spacing: MTTheme.s3) {
            if let leading {
                leading
            } else if let systemImage {
                MTGlyphTile(systemImage: systemImage, accent: accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MTTheme.body(12.5, weight: .medium))
                    .foregroundStyle(isEnabled ? MTTheme.textPrimary : MTTheme.textSecondary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(MTTheme.mono(9.5))
                        .foregroundStyle(MTTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: MTTheme.s2)
            trailing
            // The chevron is a promise that the row opens something. A row
            // without an action used to draw it anyway, so it looked clickable
            // and did nothing when hit. Only advertise what the row can do.
            if showsChevron, action != nil {
                chevron
            }
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, 9)
        .background(hovered ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.62)
    }
}

extension MTRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        accent: Color = MTTheme.textSecondary,
        showsChevron: Bool = true,
        isEnabled: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            accent: accent,
            showsChevron: showsChevron,
            isEnabled: isEnabled,
            action: action,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - Glyph tile

/// A brand or symbol mark in a rounded square, the leading element of a row.
struct MTGlyphTile: View {
    var systemImage: String
    var accent: Color = MTTheme.textSecondary
    var size: CGFloat = 28
    var monogram: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(accent.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(accent.opacity(0.25), lineWidth: 0.5)
            )
            .overlay {
                if let monogram, !monogram.isEmpty {
                    Text(monogram)
                        .font(MTTheme.body(size * 0.46, weight: .semibold))
                        .foregroundStyle(accent)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Badges

/// Small capsule label: "off", "self", "42 models", a plan name.
struct MTBadge: View {
    var text: String
    var tint: Color = MTTheme.textTertiary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(MTTheme.mono(9, weight: .semibold))
            .foregroundStyle(filled ? MTTheme.onGold : tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(filled ? tint : tint.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(filled ? Color.clear : tint.opacity(0.25), lineWidth: 0.5)
            )
    }
}

/// Status dot plus a masked key, the trailing element of a provider row.
struct MTKeyPill: View {
    var status: MTStatus
    var key: String
    var placeholder: String = L("No key")

    private var masked: String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return placeholder }
        guard trimmed.count > 8 else { return "••••" }
        return String(trimmed.prefix(4)) + "…" + String(trimmed.suffix(4))
    }

    var body: some View {
        HStack(spacing: 5) {
            MTStatusDot(status: status, size: 6)
            Text(masked)
                .font(MTTheme.mono(9.5))
                .foregroundStyle(key.isEmpty ? MTTheme.textTertiary : MTTheme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(key.isEmpty ? placeholder : L("Key configured"))
    }
}

// MARK: - Section heading inside a card

/// Mono uppercase heading used to split a card into labelled groups.
struct MTCardSectionTitle: View {
    var text: String
    var systemImage: String? = nil
    var accent: Color = MTTheme.cyan

    var body: some View {
        HStack(spacing: MTTheme.s2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text(text.uppercased())
                .font(MTTheme.mono(9, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(MTTheme.textTertiary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Selector chips

/// Horizontal segmented chips, the section switcher of a provider page.
struct MTChipPicker<Item: Hashable>: View {
    var items: [Item]
    var title: (Item) -> String
    @Binding var selection: Item
    var accent: Color = MTTheme.cyan
    @State private var hovered: Item?

    var body: some View {
        HStack(spacing: MTTheme.s1 + 2) {
            ForEach(items, id: \.self) { item in
                let isOn = item == selection
                Button {
                    selection = item
                } label: {
                    Text(title(item))
                        .font(MTTheme.body(11.5, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? MTTheme.textPrimary : MTTheme.textSecondary)
                        .padding(.horizontal, MTTheme.s3)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                isOn ? accent.opacity(0.20)
                                : (hovered == item ? Color.primary.opacity(0.09) : Color.primary.opacity(0.05))
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                isOn ? accent.opacity(0.45) : MTTheme.borderColor.opacity(0.6),
                                lineWidth: 0.75
                            )
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = item
                    } else if hovered == item {
                        hovered = nil
                    }
                }
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}
