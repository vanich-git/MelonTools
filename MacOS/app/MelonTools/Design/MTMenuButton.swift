import AppKit
import SwiftUI

/// One row of an `MTMenuButton` dropdown.
struct MTMenuEntry: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String?
    /// Rendered in the danger tint and separated from the rest.
    var isDestructive: Bool = false
    var isDivider: Bool = false
    var action: () -> Void = {}

    static var divider: MTMenuEntry {
        MTMenuEntry(title: "", isDivider: true)
    }

    static func item(
        _ title: String,
        systemImage: String? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> MTMenuEntry {
        MTMenuEntry(title: title, systemImage: systemImage, isDestructive: destructive, action: action)
    }
}

/// Dropdown in the Melon Tools design language.
///
/// Backed by a native `Menu` rather than a hand-drawn overlay: an overlay is
/// clipped by its scroll container and is painted under later siblings, which
/// hid options and let rows show through the panel. `Menu` renders above all
/// content, sizes itself to every item and handles Escape, keyboard selection
/// and outside clicks.
struct MTMenuButton: View {
    var systemImage: String = "ellipsis"
    var title: String?
    var tint: Color = MTTheme.textSecondary
    var entries: [MTMenuEntry]

    @State private var isPresented = false
    @State private var hoveredEntry: UUID?
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                if let title {
                    Text(title)
                        .font(MTTheme.body(11, weight: .medium))
                }
            }
            .foregroundStyle(tint)
            .frame(height: 24)
            .padding(.horizontal, title == nil ? 8 : 12)
            .background(
                Capsule()
                    .fill(
                        isPresented ? Color.primary.opacity(0.1)
                        : (isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(isPresented ? MTTheme.emerald.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            menuPanel
        }
        .accessibilityLabel(title ?? L("More"))
    }

    private var menuPanel: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(entries) { entry in
                if entry.isDivider {
                    Divider()
                        .overlay(Color.primary.opacity(0.08))
                        .padding(.vertical, 4)
                } else {
                    Button {
                        isPresented = false
                        entry.action()
                    } label: {
                        HStack(spacing: 8) {
                            if let icon = entry.systemImage {
                                Image(systemName: icon)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 16, alignment: .leading)
                            }
                            Text(entry.title)
                                .font(MTTheme.body(11.5))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(entry.isDestructive ? MTTheme.danger : MTTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Capsule()
                                .fill(hoveredEntry == entry.id ? Color.primary.opacity(0.08) : Color.clear)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredEntry = $0 ? entry.id : nil }
                }
            }
        }
        .padding(6)
        .frame(width: 280)
        .background(MTTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MTTheme.borderColor.opacity(0.8), lineWidth: 1)
        )
        .onExitCommand { isPresented = false }
    }
}

/// Keys the popover pickers understand.
///
/// Resolving an AppKit event here keeps the keyboard contract testable
/// without a window: the monitor below only forwards what this returns.
enum MTSelectKey: Equatable {
    case up
    case down
    case home
    case end
    case commit
    case cancel
    case character(Character)

    static func resolve(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> MTSelectKey? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 115: return .home
        case 119: return .end
        case 36, 76: return .commit
        case 53: return .cancel
        default: break
        }
        // Cmd/Control/Option chords belong to the app, not to the picker.
        guard !modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option) else { return nil }
        guard let characters, let first = characters.first, !first.isNewline else { return nil }
        return .character(first)
    }
}

/// Installs a local key monitor only while the popover is on screen.
///
/// The popover is a separate window whose first responder is either the search
/// field or the list itself, so a window monitor is the one place that sees
/// every navigation key regardless of which subview holds focus. While the
/// search field is being edited, printable characters are left alone and only
/// navigation keys are consumed.
private struct MTSelectKeyMonitor: NSViewRepresentable {
    var onKey: (MTSelectKey) -> Bool

    func makeNSView(context: Context) -> NSView { View(onKey: onKey) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? View)?.onKey = onKey
    }

    final class View: NSView {
        var onKey: (MTSelectKey) -> Bool
        private var monitor: Any?

        init(onKey: @escaping (MTSelectKey) -> Bool) {
            self.onKey = onKey
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit { removeMonitor() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                guard let key = MTSelectKey.resolve(
                    keyCode: event.keyCode,
                    characters: event.charactersIgnoringModifiers,
                    modifiers: event.modifierFlags
                ) else { return event }
                // The search field owns plain characters; everything else is
                // the picker's, including Return and Escape.
                if case .character = key, window.firstResponder is NSTextView {
                    return event
                }
                return self.onKey(key) ? nil : event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// The list body shared by `MTSelect` and `MTSearchableSelect`.
///
/// One component owns highlight (keyboard focus), selection (the committed
/// value), type-ahead, scrolling and the accessibility contract, so the two
/// triggers cannot drift into different behaviours.
struct MTSelectList<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    /// Optional second line per option, for lists that need file names or
    /// sizes under the title. `nil` keeps the compact single-line row.
    var detail: ((Value) -> String)? = nil
    var selection: Value
    var searchable: Bool
    var minimumWidth: CGFloat
    var maximumWidth: CGFloat
    var onSelect: (Value) -> Void
    var onCancel: () -> Void

    @State private var query = ""
    /// Position inside `visibleOptions`, not inside `options`.
    @State private var highlighted = 0
    /// Bumped only by keyboard navigation. Hover moves the highlight too, and
    /// scrolling on every highlight change made the list chase the pointer
    /// instead of the trackpad.
    @State private var scrollRequest = 0
    @State private var typeAheadBuffer = ""
    @State private var typeAheadAt = Date.distantPast
    @FocusState private var searchFocused: Bool

    private var visibleIndices: [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchable, !trimmed.isEmpty else { return Array(options.indices) }
        return options.indices.filter {
            options[$0].label.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var highlightedOption: (value: Value, label: String)? {
        let indices = visibleIndices
        guard indices.indices.contains(highlighted) else { return nil }
        return options[indices[highlighted]]
    }

    private var panelWidth: CGFloat {
        let measured = Self.panelWidth(
            labels: options.map { $0.label },
            minimum: minimumWidth,
            maximum: maximumWidth
        )
        return detail == nil ? measured : min(max(measured, 420), maximumWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if searchable {
                TextField(L("Search..."), text: $query)
                    .textFieldStyle(.mtInput(size: .small))
                    .font(MTTheme.body(11.5))
                    .focused($searchFocused)
                    .onSubmit { commitHighlighted() }
                    .onChange(of: query) { _, _ in highlighted = 0 }
                Divider().overlay(Color.primary.opacity(0.08))
            }
            listBody
        }
        .padding(searchable ? 8 : 6)
        .frame(width: panelWidth)
        .background(MTTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MTTheme.borderColor.opacity(0.8), lineWidth: 1)
        )
        .background(MTSelectKeyMonitor(onKey: handleKey))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(searchable ? L("Searchable options") : L("Options"))
        .onAppear {
            highlighted = selectedPosition()
            if searchable {
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }

    private var listBody: some View {
        Group {
            if visibleIndices.isEmpty {
                Text(L("Nothing found"))
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(visibleIndices.enumerated()), id: \.offset) { position, index in
                                row(position: position, index: index)
                                    .id(position)
                            }
                        }
                    }
                    .frame(height: listHeight)
                    .onAppear {
                        // After the outer onAppear has synced the highlight.
                        DispatchQueue.main.async { scrollToHighlight(proxy) }
                    }
                    .onChange(of: scrollRequest) { _, _ in scrollToHighlight(proxy) }
                }
            }
        }
    }

    private var rowHeight: CGFloat { detail == nil ? 24 : 38 }

    private var listHeight: CGFloat {
        let visible = max(visibleIndices.count, 1)
        return min(CGFloat(visible), 9) * rowHeight + 4
    }

    private func row(position: Int, index: Int) -> some View {
        let option = options[index]
        let isSelected = option.value == selection
        let isHighlighted = position == highlighted
        return Button {
            select(option.value)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? MTTheme.emerald : Color.clear)
                    .frame(width: 3, height: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(MTTheme.body(11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? MTTheme.textPrimary : MTTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail {
                        Text(detail(option.value))
                            .font(MTTheme.body(9.5))
                            .foregroundStyle(MTTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(MTTheme.emerald)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Capsule()
                    .fill(
                        isHighlighted ? Color.primary.opacity(0.10)
                        : (isSelected ? MTTheme.emerald.opacity(0.16) : Color.clear)
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { highlighted = position }
        }
        .help(option.label)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Interaction

    private func select(_ value: Value) {
        onSelect(value)
    }

    private func commitHighlighted() {
        guard let option = highlightedOption else {
            onCancel()
            return
        }
        select(option.value)
    }

    private func selectedPosition() -> Int {
        let indices = visibleIndices
        if let position = indices.firstIndex(where: { options[$0].value == selection }) {
            return position
        }
        return 0
    }

    private func handleKey(_ key: MTSelectKey) -> Bool {
        switch key {
        case .up:
            moveHighlight(by: -1)
        case .down:
            moveHighlight(by: 1)
        case .home:
            highlighted = 0
            requestScroll()
        case .end:
            highlighted = max(visibleIndices.count - 1, 0)
            requestScroll()
        case .commit:
            commitHighlighted()
        case .cancel:
            onCancel()
        case .character(let character):
            guard !searchable else { return false }
            applyTypeAhead(character)
        }
        return true
    }

    private func moveHighlight(by delta: Int) {
        let count = visibleIndices.count
        guard count > 0 else { return }
        let next = highlighted + delta
        if next < 0 {
            highlighted = count - 1
        } else if next >= count {
            highlighted = 0
        } else {
            highlighted = next
        }
        requestScroll()
    }

    private func applyTypeAhead(_ character: Character) {
        let now = Date()
        if now.timeIntervalSince(typeAheadAt) > Self.typeAheadTimeout {
            typeAheadBuffer = ""
        }
        typeAheadBuffer.append(character)
        typeAheadAt = now
        let labels = visibleIndices.map { options[$0].label }
        guard let target = Self.typeAheadTarget(
            input: typeAheadBuffer,
            labels: labels,
            from: highlighted
        ) else { return }
        highlighted = target
        requestScroll()
    }

    /// Keyboard-driven scroll. The scroll view reads this instead of
    /// `highlighted`, so a hover that changes the highlight leaves the offset
    /// alone and the trackpad keeps ownership of scrolling.
    private func requestScroll() {
        scrollRequest &+= 1
    }

    private func scrollToHighlight(_ proxy: ScrollViewProxy) {
        guard visibleIndices.indices.contains(highlighted) else { return }
        proxy.scrollTo(highlighted)
    }

    // MARK: - Pure helpers

    /// How long a type-ahead prefix stays open: a pause starts a new word.
    /// Computed because a generic type cannot hold a stored static.
    static var typeAheadTimeout: TimeInterval { 0.7 }

    /// Row a type-ahead keystroke jumps to, scanning forward from `from` and
    /// wrapping around, like a native menu.
    static func typeAheadTarget(input: String, labels: [String], from: Int) -> Int? {
        let needle = input.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, !labels.isEmpty else { return nil }
        let start = labels.indices.contains(from) ? from : 0
        for offset in 1...labels.count {
            let candidate = (start + offset) % labels.count
            if labels[candidate].range(of: needle, options: [.caseInsensitive, .anchored]) != nil {
                return candidate
            }
        }
        return nil
    }

    /// Panel width follows the longest label and never exceeds the screen.
    ///
    /// `lineLimit(1)` still truncates inside the row, but a select whose rows
    /// clip "Fits with limits" to "Fits with l…" is a bug, so the panel grows
    /// to the content up to the cap. The full label stays available as
    /// `help`/`accessibilityLabel` either way.
    static func panelWidth(labels: [String], minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5)
        let longest = labels.reduce(CGFloat(0)) { partial, label in
            max(partial, (label as NSString).size(withAttributes: [.font: font]).width)
        }
        // Marker, checkmark, row padding and the panel border.
        let content = longest + 46
        return min(max(content, minimum), max(minimum, maximum))
    }

    /// The panel never grows past the visible screen, even for pathological
    /// labels: it keeps a margin on both sides.
    static func screenCap(visibleWidth: CGFloat, preferred: CGFloat = 460) -> CGFloat {
        max(240, min(preferred, visibleWidth - 120))
    }

    static var screenMaximum: CGFloat {
        screenCap(visibleWidth: NSScreen.main?.visibleFrame.width ?? 1440)
    }

}

/// Dropdown selector in the Melon Tools design language.
///
/// A custom popover rather than a native `Menu`: the list must use the app's
/// surface, show a strong selected row and never inherit the system menu's
/// translucent appearance. A popover is its own window, so it is not clipped by
/// the surrounding ScrollView and is painted above every later sibling — the
/// two failure modes of the old hand-drawn overlay. Keyboard, type-ahead and
/// accessibility live in `MTSelectList`, shared with `MTSearchableSelect`.
struct MTSelect<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var width: CGFloat = 196
    /// Optional second line per option, forwarded to `MTSelectList`.
    var detail: ((Value) -> String)? = nil

    @State private var isPresented = false
    @State private var hovering = false
    @FocusState private var triggerFocused: Bool

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? "—"
    }

    private var expandedState: String {
        isPresented ? L("expanded") : L("collapsed")
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(MTTheme.body(11.5))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isPresented ? MTTheme.emerald : MTTheme.textTertiary)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: 26)
            .background(
                Capsule()
                    .fill(
                        isPresented ? MTTheme.emerald.opacity(0.1)
                        : (hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isPresented ? MTTheme.emerald.opacity(0.7) : Color.primary.opacity(0.09),
                        lineWidth: isPresented ? 1.2 : 1
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(triggerFocused ? MTTheme.cyan.opacity(0.9) : Color.clear, lineWidth: 2)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($triggerFocused)
        .onHover { hovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MTSelectList(
                options: options,
                detail: detail,
                selection: selection,
                searchable: false,
                minimumWidth: max(width, detail == nil ? 220 : 420),
                maximumWidth: MTSelectList<Value>.screenMaximum,
                onSelect: { value in
                    selection = value
                    dismiss()
                },
                onCancel: dismiss
            )
        }
        .help(currentLabel)
        .accessibilityLabel(currentLabel)
        .accessibilityValue(expandedState)
        .accessibilityAddTraits(isPresented ? .isSelected : [])
        .onChange(of: isPresented) { _, presented in
            if !presented {
                // Focus goes back to the trigger, so the next arrow key keeps
                // working after a pick instead of falling to the window.
                DispatchQueue.main.async { triggerFocused = true }
            }
        }
    }

    private func dismiss() {
        isPresented = false
        DispatchQueue.main.async { triggerFocused = true }
    }
}

/// Segmented control in the Melon Tools design language.
///
/// `Picker(.segmented)` is drawn by AppKit with the system accent colour, which
/// stands out inside the app's dark cards.
struct MTSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var width: CGFloat?
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(MTTheme.body(11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? MTTheme.textPrimary : MTTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(
                                    isSelected ? Color.primary.opacity(0.12)
                                    : (hovered == option.value ? Color.primary.opacity(0.08) : Color.clear)
                                )
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = option.value
                    } else if hovered == option.value {
                        hovered = nil
                    }
                }
            }
        }
        .padding(2)
        .frame(width: width)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
