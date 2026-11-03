import AppKit
import SwiftUI

/// Two resting layouts: everything inside a pill under the cut-out, or the
/// hourly and weekly totals in two wings beside it.
enum NotchHUDCompactStyle: String, CaseIterable {
    case inside
    case sides

    var title: String {
        switch self {
        case .inside: return L("Under the notch")
        case .sides: return L("Beside the notch")
        }
    }
}

/// Shared state of the top-of-screen island: which shape it draws and whether
/// the screen it hangs from has a camera notch.
@MainActor
final class NotchHUDModel: ObservableObject {
    @Published fileprivate(set) var isExpanded = false
    /// Height of the camera cut-out. The island paints behind it so its top
    /// blends into the notch instead of ending under it.
    @Published fileprivate(set) var topInset: CGFloat = 0
    /// Width of the cut-out: the narrow neck the card hangs from.
    @Published fileprivate(set) var notchWidth: CGFloat = 0
    /// Width of the resting island, a little wider than a narrow notch.
    @Published fileprivate(set) var compactWidth: CGFloat = 185
    @Published fileprivate(set) var compactStyle: NotchHUDCompactStyle = .inside
}

/// Where the island sits and how big it is in each state.
///
/// Pure geometry, separate from AppKit, so the notch measurement and the
/// collapsed/expanded frames can be unit-tested without a screen.
struct NotchHUDGeometry: Equatable {
    static let compactHeight: CGFloat = 30
    static let expandedSize = CGSize(width: 420, height: 242)
    static let fallbackNotchWidth: CGFloat = 184
    static let minimumCompactWidth: CGFloat = 176
    static let maximumCompactWidth: CGFloat = 260

    /// Height of the resting side bar. Without a cut-out it falls back to the
    /// normal compact height instead of collapsing to zero.
    static func sideBarHeight(topInset: CGFloat) -> CGFloat {
        max(topInset, compactHeight)
    }
    let hasNotch: Bool
    let notchWidth: CGFloat
    let compactWidth: CGFloat
    /// Height of the cut-out the island paints behind, 0 without a notch.
    let topInset: CGFloat
    /// Top edge of the screen: the island starts at the very top.
    let anchorY: CGFloat

    init(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryLeft: CGRect?,
        auxiliaryRight: CGRect?
    ) {
        // `safeAreaInsets.top` is the menu bar height on every display, with
        // or without a camera cut-out. Only the auxiliary areas prove a notch.
        hasNotch = safeAreaTop > 0 && auxiliaryLeft != nil && auxiliaryRight != nil
        if hasNotch, let left = auxiliaryLeft, let right = auxiliaryRight {
            let measured = screenFrame.width - left.width - right.width
            notchWidth = measured > 0 && measured < screenFrame.width
                ? measured
                : Self.fallbackNotchWidth
        } else {
            notchWidth = Self.fallbackNotchWidth
        }

        // The island is meant to read as part of the top edge, not as a
        // floating window below it. It starts at the very top of the screen;
        // on a notched Mac the cut-out area is painted too, so the panel's top
        // blends into the black notch instead of ending beneath it.
        topInset = hasNotch ? safeAreaTop : 0
        anchorY = screenFrame.maxY

        compactWidth = hasNotch
            ? min(max(notchWidth, Self.minimumCompactWidth), Self.maximumCompactWidth)
            : Self.minimumCompactWidth
    }

    /// The panel keeps the open size at all times. SwiftUI animates the card
    /// inside it, so the top edge never moves and the window itself does not
    /// have to be resized frame by frame.
    func windowFrame(screenFrame: CGRect) -> CGRect {
        let size = CGSize(
            width: Self.expandedSize.width,
            height: Self.expandedSize.height + topInset
        )
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: anchorY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

/// A borderless, non-activating panel that never steals focus from the app the
/// user is working in. It joins every Space (including full-screen apps) and
/// floats above the menu bar level.
final class NotchHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit normally pushes a window out from under the menu bar. The island
    /// is meant to sit in that strip, so the system constraint is bypassed.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Owns the island window: installs it on the screen that has the notch,
/// follows display changes, and expands it under the pointer.
@MainActor
final class NotchHUDController {
    static let shared = NotchHUDController()
    static let enabledDefaultsKey = "notchHUDEnabled"
    static let styleDefaultsKey = "notchHUDCompactStyle"
    /// Width of one wing in the side-by-side resting layout.
    static let wingWidth: CGFloat = 76
    /// Extra margin around the card so a pointer resting on the edge does not
    /// flap between the compact and expanded states.
    private static let pointerSlop: CGFloat = 4

    private var panel: NotchHUDPanel?
    private let model = NotchHUDModel()
    private var geometry: NotchHUDGeometry?
    private var screenObserver: NSObjectProtocol?
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var openMainWindowAction: (() -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastPointerCheck: TimeInterval = 0

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    var compactStyle: NotchHUDCompactStyle {
        UserDefaults.standard.string(forKey: Self.styleDefaultsKey)
            .flatMap(NotchHUDCompactStyle.init(rawValue:)) ?? .inside
    }

    func setCompactStyle(_ style: NotchHUDCompactStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: Self.styleDefaultsKey)
        withAnimation(.easeInOut(duration: 0.28)) {
            model.compactStyle = style
        }
        evaluatePointer()
    }

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Lifecycle

    func start() {
        guard !AppRuntime.isTesting else { return }
        guard isEnabled else { return }
        installIfNeeded()
        panel?.orderFrontRegardless()
    }

    /// Wired by `MainView` so the island can reopen a window SwiftUI may have
    /// released when the user closed it.
    func registerOpenMainWindow(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        guard !AppRuntime.isTesting else { return }
        if enabled {
            installIfNeeded()
            relayout(animated: false)
            panel?.orderFrontRegardless()
            startPointerTracking()
            evaluatePointer()
        } else {
            cancelPointerWork()
            setExpanded(false)
            stopPointerTracking()
            panel?.orderOut(nil)
        }
    }

    private func installIfNeeded() {
        guard panel == nil else { return }
        guard let screen = Self.targetScreen() else { return }
        let geometry = Self.geometry(for: screen)
        self.geometry = geometry
        let frame = geometry.windowFrame(screenFrame: screen.frame)
        model.topInset = geometry.topInset
        model.notchWidth = geometry.notchWidth
        model.compactWidth = geometry.compactWidth
        model.compactStyle = compactStyle
        let panel = NotchHUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: NotchHUDView(model: model))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(frame, display: false)

        self.panel = panel
        observeScreenChanges()
        startPointerTracking()
        evaluatePointer()
    }

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.relayout(animated: false)
            }
        }
    }

    // MARK: - Geometry

    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func geometry(for screen: NSScreen) -> NotchHUDGeometry {
        NotchHUDGeometry(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeft: screen.auxiliaryTopLeftArea,
            auxiliaryRight: screen.auxiliaryTopRightArea
        )
    }

    private func relayout(animated: Bool = true) {
        guard let panel, let screen = Self.targetScreen() else { return }
        let geometry = Self.geometry(for: screen)
        self.geometry = geometry
        model.topInset = geometry.topInset
        model.notchWidth = geometry.notchWidth
        model.compactWidth = geometry.compactWidth

        let target = geometry.windowFrame(screenFrame: screen.frame)
        panel.setFrame(target, display: true)
        evaluatePointer()
    }

    // MARK: - Expansion

    func setExpanded(_ expanded: Bool) {
        guard model.isExpanded != expanded else { return }
        // One timing for both directions: the window frame and the SwiftUI
        // cross-fade run for the same 0.28 s on the same curve.
        withAnimation(.easeInOut(duration: 0.28)) {
            model.isExpanded = expanded
        }
        relayout()
    }

    // MARK: - Pointer

    /// Hover cannot be handled by SwiftUI alone: the window is larger than the
    /// card (it always has the open size), so the transparent margins must not
    /// swallow clicks. A global mouse monitor decides whether the pointer is
    /// over the card and switches `ignoresMouseEvents` accordingly.
    private func startPointerTracking() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            // The handler is delivered on the main thread; assume it instead
            // of creating a Task for every mouse move.
            MainActor.assumeIsolated {
                self?.pointerMoved()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.pointerMoved()
            return event
        }
    }

    private func stopPointerTracking() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    /// Pointer checks are throttled to ~30 Hz. A 120 Hz trackpad would
    /// otherwise rebuild the hit-test rectangles hundreds of times per second.
    private func pointerMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerCheck >= 0.033 else { return }
        lastPointerCheck = now
        evaluatePointer()
    }

    private func evaluatePointer() {
        guard let panel, let geometry else { return }
        let location = NSEvent.mouseLocation
        let frame = panel.frame
        let compactRect: CGRect
        if model.compactStyle == .sides {
            let wings = Self.wingWidth * 2 + 8
            let width = geometry.notchWidth + wings
            let height = NotchHUDGeometry.sideBarHeight(topInset: geometry.topInset)
            compactRect = CGRect(
                x: frame.midX - width / 2,
                y: frame.maxY - height,
                width: width,
                height: height
            )
        } else {
            let height = NotchHUDGeometry.compactHeight + geometry.topInset
            compactRect = CGRect(
                x: frame.midX - geometry.compactWidth / 2,
                y: frame.maxY - height,
                width: geometry.compactWidth,
                height: height
            )
        }

        if model.isExpanded {
            let inside = frame.insetBy(dx: -Self.pointerSlop, dy: -Self.pointerSlop).contains(location)
            panel.ignoresMouseEvents = !inside
            if inside {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.collapseWork = nil
                    self?.setExpanded(false)
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        } else {
            let inside = compactRect.insetBy(dx: -Self.pointerSlop, dy: -Self.pointerSlop).contains(location)
            panel.ignoresMouseEvents = !inside
            if inside {
                guard expandWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    self?.expandWork = nil
                    self?.setExpanded(true)
                }
                expandWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            } else {
                expandWork?.cancel()
                expandWork = nil
            }
        }
    }

    private func cancelPointerWork() {
        expandWork?.cancel()
        expandWork = nil
        collapseWork?.cancel()
        collapseWork = nil
    }

    // MARK: - Actions

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })
            ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.title == "Melon Tools" })
        if let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }
        openMainWindowAction?()
    }
}
