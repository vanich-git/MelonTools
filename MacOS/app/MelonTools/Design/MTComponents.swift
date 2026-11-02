import SwiftUI

// MARK: - Page scaffold

/// Apple-style page header: mono kicker in the melon accent, SF Pro title, secondary subtitle.
struct MTPageHeader: View {
    let kicker: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s1) {
            Text(kicker.uppercased())
                .font(MTTheme.mono(10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(MTTheme.gold)
            Text(title)
                .font(MTTheme.display(27))
                .foregroundStyle(MTTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
        .padding(.bottom, MTTheme.s4)
    }
}

// MARK: - Card & Bento Surfaces

struct MTCard<Content: View>: View {
    var title: String? = nil
    var systemImage: String? = nil
    var accent: Color? = nil
    var isBento: Bool = true
    /// Stretch the plate to the full height of its bento row, so two cards side
    /// by side end on the same baseline instead of leaving a hole under the
    /// shorter one.
    var fillsHeight: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            if let title {
                HStack(spacing: MTTheme.s2) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(accent ?? MTTheme.gold)
                    }
                    Text(title)
                        .font(MTTheme.body(13, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    Spacer()
                }
            }
            content
            if fillsHeight { Spacer(minLength: 0) }
        }
        .padding(MTTheme.s4)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .modifier(CardBackingModifier(accent: accent, isBento: isBento))
    }
}

private struct CardBackingModifier: ViewModifier {
    let accent: Color?
    let isBento: Bool

    func body(content: Content) -> some View {
        if isBento {
            content.mtBentoCard(accent: accent)
        } else {
            content.mtCardSurface()
        }
    }
}

// MARK: - Status dot + pill

struct MTStatusDot: View {
    let status: MTStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
    }
}

struct MTStatusPill: View {
    let text: String
    let status: MTStatus

    var body: some View {
        HStack(spacing: 5) {
            MTStatusDot(status: status, size: 6)
            Text(text)
                .font(MTTheme.mono(10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(status.color.opacity(0.12))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(status.color.opacity(0.3), lineWidth: 0.75)
        )
        .foregroundStyle(status.color)
    }
}

// MARK: - Key/Value row (doctor-style table)

struct MTKeyValueRow: View {
    let key: String
    let value: String
    var status: MTStatus? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MTTheme.s3) {
            Text(key)
                .font(MTTheme.mono(11))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(width: 120, alignment: .leading)
            if let status {
                MTStatusDot(status: status, size: 6)
            }
            Text(value)
                .font(MTTheme.mono(11))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Buttons

struct MTPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MTTheme.onGold)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.subheadline.weight(.semibold))
                }
                Text(title)
            }
        }
        .buttonStyle(MTSolidButtonStyle(prominent: true))
        .disabled(isLoading)
    }
}

struct MTSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.subheadline.weight(.semibold))
                }
                Text(title)
            }
        }
        .buttonStyle(MTSolidButtonStyle())
        .disabled(isLoading)
    }
}

struct MTGlassButton: View {
    let title: String
    var systemImage: String? = nil
    var size: MTButtonSize = .regular
    var tint: Color? = nil
    var prominent: Bool = false
    var isLoading: Bool = false
    let action: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        size: MTButtonSize = .regular,
        tint: Color? = nil,
        prominent: Bool = false,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.tint = tint
        self.prominent = prominent
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: size == .small ? 4 : 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: size == .small ? 10.5 : 12, weight: .semibold))
                }
                Text(title)
            }
        }
        .buttonStyle(MTGlassButtonStyle(tint: tint, prominent: prominent, size: size))
        .disabled(isLoading)
    }
}

// MARK: - Quota ring

struct MTQuotaRing: View {
    /// 0...1, nil = unknown
    let fraction: Double?
    var label: String? = nil
    var size: CGFloat = 44
    var ringTint: Color? = nil
    var strokeWidth: CGFloat? = nil

    private var color: Color {
        if let ringTint { return ringTint }
        guard let f = fraction else { return MTTheme.textTertiary }
        if f > 0.5 { return MTTheme.emerald }
        if f > 0.15 { return MTTheme.amber }
        return MTTheme.ruby
    }

    var body: some View {
        let text: String = {
            if let label { return label }
            if let fraction { return "\(Int((fraction * 100).rounded()))%" }
            return "—"
        }()
        let width = strokeWidth ?? max(3.5, size * 0.09)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: width)
            if let f = fraction {
                Circle()
                    .trim(from: 0, to: max(0.01, min(1, f)))
                    .stroke(
                        LinearGradient(
                            colors: [color.opacity(0.7), color],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            Text(text)
                .font(MTTheme.mono(max(9, size * 0.22), weight: .semibold))
                .foregroundStyle(MTTheme.textPrimary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Meter + bento stat tile

/// Horizontal meter: a pure-SwiftUI capsule bar with glass depth.
struct MTMeter: View {
    /// 0...1, nil = unknown.
    let fraction: Double?
    var tint: Color = MTTheme.gold
    var height: CGFloat = 5

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            if let fraction {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .scaleEffect(x: min(1, max(0, fraction)), y: 1, anchor: .leading)
            }
        }
        .frame(height: height)
    }
}

/// A bento stat tile: mono caption, large value, optional meter and footnote.
struct MTMetricTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var fraction: Double? = nil
    var tint: Color = MTTheme.gold
    var valueColor: Color? = nil
    var reservesMeterSpace: Bool = false

    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            Text(title.uppercased())
                .font(MTTheme.mono(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(MTTheme.textTertiary)
            Text(value)
                .font(MTTheme.display(valueSize, weight: .semibold))
                .foregroundStyle(valueColor ?? MTTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let fraction {
                MTMeter(fraction: fraction, tint: tint)
            } else if reservesMeterSpace {
                Color.clear.frame(height: 5)
                    .accessibilityHidden(true)
            }
            if let caption {
                Text(caption)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty state

struct MTEmptyState: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 30

    var body: some View {
        VStack(spacing: MTTheme.s2) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .light))
                .foregroundStyle(MTTheme.gold.opacity(0.75))
            Text(title)
                .font(MTTheme.body(13, weight: .medium))
                .foregroundStyle(MTTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MTTheme.s6)
    }
}
