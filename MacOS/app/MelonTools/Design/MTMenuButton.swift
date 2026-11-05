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
            .frame(height: 22)
            .padding(.horizontal, title == nil ? 6 : 9)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPresented ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isPresented ? MTTheme.emerald.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(hoveredEntry == entry.id ? Color.primary.opacity(0.08) : Color.clear)
                        )
                        .contentShape(Rectangle())
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
    var selection: Value
    var searchable: Bool
    var minimumWidth: CGFloat
    var maximumWidth: CGFloat
    var onSelect: (Value) -> Void
    var onCancel: () -> Void

    @State private var query = ""
    /// Position inside `visibleOptions`, not inside `options`.
    @State private var highlighted = 0
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
        Self.panelWidth(
            labels: options.map { $0.label },
            minimum: minimumWidth,
            maximum: maximumWidth
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if searchable {
                TextField(L("Search..."), text: $query)
                    .textFieldStyle(.roundedBorder)
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
                    .onChange(of: highlighted) { _, _ in scrollToHighlight(proxy) }
                }
            }
        }
    }

    private var listHeight: CGFloat {
        let visible = max(visibleIndices.count, 1)
        return min(CGFloat(visible), 9) * 24 + 4
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
                Text(option.label)
                    .font(MTTheme.body(11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? MTTheme.textPrimary : MTTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(MTTheme.emerald)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHighlighted ? Color.primary.opacity(0.10)
                        : (isSelected ? MTTheme.emerald.opacity(0.16) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
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
        case .end:
            highlighted = max(visibleIndices.count - 1, 0)
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
    }

    private func scrollToHighlight(_ proxy: ScrollViewProxy) {
        guard visibleIndices.indices.contains(highlighted) else { return }
        proxy.scrollTo(highlighted, anchor: .center)
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

    @State private var isPresented = false
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
            .padding(.horizontal, 8)
            .frame(width: width, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPresented ? MTTheme.emerald.opacity(0.1) : Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isPresented ? MTTheme.emerald.opacity(0.7) : Color.primary.opacity(0.09),
                                lineWidth: isPresented ? 1.2 : 1
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($triggerFocused)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MTSelectList(
                options: options,
                selection: selection,
                searchable: false,
                minimumWidth: max(width, 220),
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
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }
}
