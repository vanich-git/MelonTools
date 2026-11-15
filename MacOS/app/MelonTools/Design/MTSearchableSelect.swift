import SwiftUI

/// Like `MTSelect`, but with a filter field inside the popover. The time-zone
/// list alone has ~600 entries; a plain menu is technically usable but not
/// realistically searchable, so this control is used for long option sets.
///
/// The list body, keyboard contract and accessibility come from `MTSelectList`;
/// only the search field and the trigger differ from `MTSelect`.
struct MTSearchableSelect<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var width: CGFloat = 320

    @State private var isPresented = false
    @FocusState private var triggerFocused: Bool

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
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
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isPresented ? MTTheme.emerald : MTTheme.textTertiary)
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
        .help(currentLabel)
        .accessibilityLabel(currentLabel)
        .accessibilityValue(expandedState)
        .accessibilityAddTraits(isPresented ? .isSelected : [])
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MTSelectList(
                options: options,
                selection: selection,
                searchable: true,
                minimumWidth: width,
                maximumWidth: MTSelectList<Value>.screenMaximum,
                onSelect: { value in
                    selection = value
                    dismiss()
                },
                onCancel: dismiss
            )
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                DispatchQueue.main.async { triggerFocused = true }
            }
        }
    }

    private func dismiss() {
        isPresented = false
        DispatchQueue.main.async { triggerFocused = true }
    }
}
