//! A separate, non-activating window beside the primary Explorer notification
//! area. Nothing is injected into Explorer and no taskbar space is reserved:
//! placement is conservative: an unreadable tick keeps the last position for
//! one grace tick, a shell surface in the foreground never hides the widget,
//! and a definitive failure hides it at once unless a shell surface owns the
//! foreground.

use tauri::{AppHandle, Emitter, Manager};

const LABEL: &str = "taskbar-widget";
#[cfg(windows)]
const WIDTH: f64 = 174.0;
#[cfg(windows)]
const HEIGHT: f64 = 40.0;

fn visibility(window: &tauri::WebviewWindow, visible: bool) -> Result<(), String> {
    let was_visible = window.is_visible().map_err(|e| e.to_string())?;
    if was_visible != visible {
        if visible {
            window.show()
        } else {
            window.hide()
        }
        .map_err(|e| e.to_string())?;
        let _ = window.emit("taskbar-widget-visibility", visible);
    }
    Ok(())
}

/// Disable by hiding, not destroying, so re-enabling reuses the WebView and its
/// single watcher. The settings value is authoritative on subsequent ticks.
pub fn set_visible(app: &AppHandle, visible: bool) {
    if !visible {
        // Disabling is an explicit reset: a later enable must not inherit a
        // failure streak from before the widget was turned off.
        #[cfg(windows)]
        {
            native::reset_failure_streak();
            native::forget_placement();
        }
        if let Some(window) = app.get_webview_window(LABEL) {
            let _ = visibility(&window, false);
        }
        return;
    }
    #[cfg(windows)]
    {
        if app.get_webview_window(LABEL).is_none() {
            let result = tauri::WebviewWindowBuilder::new(
                app,
                LABEL,
                tauri::WebviewUrl::App("taskbar-widget.html".into()),
            )
            .title("Melon Tools Taskbar Widget")
            .inner_size(WIDTH, HEIGHT)
            .decorations(false)
            .transparent(true)
            .always_on_top(true)
            .skip_taskbar(true)
            .focusable(false)
            .focused(false)
            .resizable(false)
            .shadow(false)
            .visible(false)
            .on_page_load(|window, payload| {
                if matches!(payload.event(), tauri::webview::PageLoadEvent::Finished) {
                    // The first placement may precede JS listener registration,
                    // or the window may have started hidden for safety.
                    let _ = window.emit(
                        "taskbar-widget-visibility",
                        window.is_visible().unwrap_or(false),
                    );
                }
            })
            .build();
            if let Err(error) = result {
                eprintln!("taskbar widget window: {error}");
                return;
            }
        }
        start(app);
        if let Err(error) = reposition(app) {
            eprintln!("taskbar widget placement: {error}");
        }
    }
    #[cfg(not(windows))]
    {
        // Do not create an unrelated floating window on unsupported hosts.
        if let Some(window) = app.get_webview_window(LABEL) {
            let _ = visibility(&window, false);
        }
    }
}

/// Start at most one watcher. Normally called automatically by `set_visible`.
/// Disabling only hides the window; actual destruction stops this watcher.
pub fn start(app: &AppHandle) {
    #[cfg(windows)]
    {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc, OnceLock,
        };
        static RUNNING: OnceLock<AtomicBool> = OnceLock::new();
        let Some(window) = app.get_webview_window(LABEL) else {
            return;
        };
        let running = RUNNING.get_or_init(|| AtomicBool::new(false));
        if running.swap(true, Ordering::AcqRel) {
            return;
        }
        let alive = Arc::new(AtomicBool::new(true));
        let window_alive = alive.clone();
        window.on_window_event(move |event| {
            if matches!(event, tauri::WindowEvent::Destroyed) {
                window_alive.store(false, Ordering::Release);
                running.store(false, Ordering::Release);
            }
        });
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                // Taskbar moves and Explorer restarts tolerate two seconds;
                // an unreadable tick is retried once by the failure grace, so
                // polling faster would only multiply process lookups.
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                if !alive.load(Ordering::Acquire) {
                    break;
                }
                let visible = app
                    .try_state::<crate::AppState>()
                    .map(|state| state.settings().taskbar_widget_visible)
                    .unwrap_or(false);
                if visible {
                    // Re-resolve Explorer HWNDs every tick: they change after a
                    // restart, and auto-hide/fullscreen can change independently.
                    let _ = reposition(&app);
                } else if let Some(window) = app.get_webview_window(LABEL) {
                    native::reset_failure_streak();
                    let _ = visibility(&window, false);
                }
            }
        });
    }
    #[cfg(not(windows))]
    let _ = app;
}

/// Place and show an existing widget only when native taskbar/tray visibility,
/// monitor bounds and foreground coverage all permit it. `false` means the
/// widget was not placed. A single unreadable tick keeps the last position and
/// is retried; a shell foreground keeps it while that surface is active; a
/// definitive failure with an ordinary foreground hides it at once.
pub fn reposition(app: &AppHandle) -> Result<bool, String> {
    let Some(window) = app.get_webview_window(LABEL) else {
        return Ok(false);
    };
    #[cfg(windows)]
    {
        let (placement, shell_foreground) = match native::placement(&window) {
            Ok(placement) => placement,
            Err(geometry::Unavailable::Retain(reason)) => {
                // Start/Search owns the foreground and Explorer may be between
                // taskbar layouts: keep the last position without hiding while
                // that surface is up. Count the tick anyway, so a failure that
                // persists through it does not get a fresh grace on close.
                native::log_unavailable(reason);
                native::record_retained_failure();
                if native::restore_last(&window) {
                    return Ok(true);
                }
                return Ok(false);
            }
            Err(geometry::Unavailable::Transient(reason)) => {
                // An unreadable tick is not proof that the bar is gone. Retry
                // once, then stop showing a stale widget.
                native::log_unavailable(reason);
                if native::transient_failure_should_hide() {
                    visibility(&window, false)?;
                }
                return Ok(false);
            }
            Err(geometry::Unavailable::Hide(reason)) => {
                // A definitive failure: there is no safe position to keep.
                native::log_unavailable(reason);
                native::reset_failure_streak();
                visibility(&window, false)?;
                return Ok(false);
            }
        };
        let size = tauri::PhysicalSize::new(placement.width as u32, placement.height as u32);
        let position = tauri::PhysicalPosition::new(placement.x, placement.y);
        let unchanged = match (window.inner_size(), window.outer_position()) {
            (Ok(current_size), Ok(current_position)) => {
                current_size == size && current_position == position
            }
            (Err(error), _) | (_, Err(error)) => {
                // A failed bounds read is not proof that the widget is in the
                // wrong place; count it through the same grace as placement.
                native::log_unavailable("could not read widget bounds");
                if native::transient_failure_should_hide() {
                    visibility(&window, false)?;
                }
                return Err(error.to_string());
            }
        };
        if !unchanged {
            // One atomic move/resize, without hiding the widget: a DPI,
            // monitor or taskbar change must not blink through a hidden state.
            if let Err(error) = native::set_bounds(&window, &placement) {
                native::log_unavailable("could not move the widget");
                if native::transient_failure_should_hide() {
                    visibility(&window, false)?;
                }
                return Err(error);
            }
        }
        visibility(&window, true)?;
        native::reset_failure_streak();
        native::log_available();
        // The taskbar is topmost and takes the top of the topmost band when
        // Start/Search closes. Re-assert the widget above it, but never while
        // a shell surface is up: the shell flyout must stay on top. Re-read
        // the foreground because a flyout can open between placement and this
        // call, and raising over it would block its bottom-right controls.
        if !shell_foreground && !native::shell_surface_active() {
            if let Err(error) = native::raise_to_top(&window) {
                eprintln!("taskbar widget z-order: {error}");
            }
        }
        Ok(true)
    }
    #[cfg(not(windows))]
    {
        visibility(&window, false)?;
        Ok(false)
    }
}

#[cfg(any(windows, test))]
mod geometry {
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub struct Rect {
        pub left: i32,
        pub top: i32,
        pub right: i32,
        pub bottom: i32,
    }

    impl Rect {
        fn width(self) -> i32 {
            self.right.saturating_sub(self.left)
        }

        fn height(self) -> i32 {
            self.bottom.saturating_sub(self.top)
        }

        fn valid(self) -> bool {
            self.width() > 0 && self.height() > 0
        }

        fn contains(self, other: Self) -> bool {
            other.valid()
                && self.left <= other.left
                && self.top <= other.top
                && self.right >= other.right
                && self.bottom >= other.bottom
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct Placement {
        pub x: i32,
        pub y: i32,
        pub width: i32,
        pub height: i32,
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum PlaceError {
        /// DPI or rectangles are contradictory; a later tick may read them
        /// correctly, so this is not proof that the bar cannot host the widget.
        Unreadable,
        /// Readable geometry leaves no room beside the tray.
        NoRoom,
    }

    /// All rectangles and the result are physical desktop pixels. The scale
    /// belongs to the destination taskbar, not the widget's previous monitor.
    pub fn place(
        monitor: Rect,
        taskbar: Rect,
        tray: Rect,
        scale: f64,
    ) -> Result<Placement, PlaceError> {
        if !scale.is_finite()
            || !(0.5..=8.0).contains(&scale)
            || !monitor.valid()
            || !monitor.contains(taskbar)
            || !taskbar.contains(tray)
        {
            return Err(PlaceError::Unreadable);
        }
        let px = |logical: f64| (logical * scale).round() as i32;
        let inset = px(2.0).max(1);
        let gap = px(4.0).max(1);
        let min_height = px(24.0);
        let horizontal = taskbar.width() >= taskbar.height();
        let placement = if horizontal {
            // A partially slid-offscreen or undocked rectangle is
            // contradictory, not proof of a missing bar: retry it once.
            if taskbar.left != monitor.left
                || taskbar.right != monitor.right
                || (taskbar.top != monitor.top && taskbar.bottom != monitor.bottom)
            {
                return Err(PlaceError::Unreadable);
            }
            let height = px(40.0).min(taskbar.height() - 2 * inset);
            let width = px(174.0).min(tray.left - taskbar.left - gap - inset);
            if height < min_height || width < px(96.0) {
                return Err(PlaceError::NoRoom);
            }
            Placement {
                x: tray.left - gap - width,
                y: taskbar.top + (taskbar.height() - height) / 2,
                width,
                height,
            }
        } else {
            if taskbar.top != monitor.top
                || taskbar.bottom != monitor.bottom
                || (taskbar.left != monitor.left && taskbar.right != monitor.right)
            {
                return Err(PlaceError::Unreadable);
            }
            let width = px(174.0).min(taskbar.width() - 2 * inset);
            let height = px(40.0).min(tray.top - taskbar.top - gap - inset);
            if width < px(32.0) || height < min_height {
                return Err(PlaceError::NoRoom);
            }
            Placement {
                x: taskbar.left + (taskbar.width() - width) / 2,
                y: tray.top - gap - height,
                width,
                height,
            }
        };
        Ok(placement)
    }

    /// One grace tick for a failure that does not prove there is no safe place.
    /// A second consecutive failure hides a stale widget.
    #[derive(Debug, Default)]
    pub struct Failures {
        consecutive: u32,
    }

    impl Failures {
        pub const LIMIT: u32 = 2;

        /// Record an indeterminate failure; `true` once the grace tick is over.
        pub fn record_transient(&mut self) -> bool {
            if self.consecutive < Self::LIMIT {
                self.consecutive += 1;
            }
            self.consecutive >= Self::LIMIT
        }

        pub fn reset(&mut self) {
            self.consecutive = 0;
        }

        /// A shell surface suppresses the hide, not the failure: keep counting
        /// so the first ordinary tick after it closes does not start a fresh
        /// grace for a failure that was present all along.
        pub fn record_while_retained(&mut self) {
            self.record_transient();
        }
    }

    #[derive(Debug, PartialEq, Eq)]
    pub enum Unavailable {
        /// A definitive failure: hide at once instead of leaving a stale widget.
        Hide(&'static str),
        /// A shell surface owns the foreground: keep the current position.
        Retain(&'static str),
        /// A read or lookup failed: retry once before hiding.
        Transient(&'static str),
    }

    /// Classify a failed lookup. A shell surface owns the foreground and keeps
    /// the widget through every failure; otherwise a transient read is retried
    /// once and a definitive failure hides at once.
    pub fn unavailable(shell: bool, transient: bool, reason: &'static str) -> Unavailable {
        match (shell, transient) {
            (true, _) => Unavailable::Retain(reason),
            (false, true) => Unavailable::Transient(reason),
            (false, false) => Unavailable::Hide(reason),
        }
    }

    /// Shell surfaces floating above the taskbar. Their rectangles can span
    /// the whole monitor while they paint above the bar, so a pure geometry
    /// check would treat them as covering the taskbar. A generic
    /// `Windows.UI.Core.CoreWindow` is deliberately not enough: fullscreen UWP
    /// apps use that class too, and must keep the fullscreen hide. It only
    /// counts for Explorer, which hosts some shell flyouts. `WS_EX_TRANSPARENT`
    /// is hit-test transparency, not proof that a window paints nothing, so it
    /// is not used as an overlay signal either.
    pub fn shell_surface(class: &str, process: Option<&str>, topmost: bool) -> bool {
        if matches!(
            class,
            "XamlExplorerHostIslandWindow"
                | "Windows.Internal.Shell.TabProxyWindow"
                | "MultitaskingViewFrame"
                | "ForegroundStaging"
                | "TopLevelWindowForOverflowXamlIsland"
                | "NotifyIconOverflowWindow"
        ) {
            return true;
        }
        match process {
            Some(
                "startmenuexperiencehost.exe"
                | "shellexperiencehost.exe"
                | "searchhost.exe"
                | "searchapp.exe"
                | "textinputhost.exe",
            ) => true,
            Some("explorer.exe") => topmost || class == "Windows.UI.Core.CoreWindow",
            _ => false,
        }
    }

    /// A missing rectangle proves coverage risk only while the same
    /// foreground window is still alive. If it died or focus moved while the
    /// rectangle was being read, the tick is indeterminate: retry it instead
    /// of hiding a widget that may have nowhere to go for one tick.
    pub fn rect_failure_is_proof(same_foreground: bool, alive: bool) -> bool {
        same_foreground && alive
    }

    /// A foreground window only hides the widget when it really covers the
    /// bar. Shell surfaces (Start, Search, Task View, notifications) paint
    /// above the taskbar without owning it, so classification, not z-order,
    /// decides whether they are exempt.
    pub fn foreground_hides(covers: bool, shell: bool) -> bool {
        covers && !shell
    }

    /// A taskbar that is momentarily unplaceable while a shell surface owns the
    /// foreground is not proof that the bar is unusable: keep the last position.
    /// With any other foreground, a placement failure means the bar genuinely
    /// cannot host the widget, so hide instead of leaving it floating.
    pub fn unplaceable_hides(shell_foreground: bool) -> bool {
        !shell_foreground
    }

    /// Classify a geometry failure. Contradictory DPI/rectangles may be a bad
    /// read and get the grace tick; readable geometry with no room hides unless
    /// a shell surface owns the foreground, where it is retained.
    pub fn place_failure(shell: bool, error: PlaceError) -> Unavailable {
        match error {
            PlaceError::Unreadable => unavailable(shell, true, "taskbar geometry is inconsistent"),
            PlaceError::NoRoom if unplaceable_hides(shell) => {
                Unavailable::Hide("no room beside the tray")
            }
            PlaceError::NoRoom => Unavailable::Retain("taskbar is momentarily unplaceable"),
        }
    }

    /// Fullscreen windows cover the monitor or the entire taskbar and extend
    /// into its desktop. With auto-hide enabled, ordinary maximized windows can
    /// cover that same rectangle, but must not suppress the revealed taskbar.
    pub fn covers_taskbar(foreground: Rect, monitor: Rect, taskbar: Rect, maximized: bool) -> bool {
        !maximized
            && (foreground.contains(monitor)
                || (foreground.contains(taskbar)
                    && (foreground.width() > taskbar.width()
                        || foreground.height() > taskbar.height())))
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn rect(left: i32, top: i32, right: i32, bottom: i32) -> Rect {
            Rect {
                left,
                top,
                right,
                bottom,
            }
        }

        const MONITOR: Rect = Rect {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1080,
        };

        #[test]
        fn bottom_taskbar_places_immediately_left_of_tray() {
            let p = place(
                MONITOR,
                rect(0, 1032, 1920, 1080),
                rect(1640, 1032, 1920, 1080),
                1.0,
            )
            .unwrap();
            assert_eq!(
                p,
                Placement {
                    x: 1462,
                    y: 1036,
                    width: 174,
                    height: 40
                }
            );
            assert!(p.x + p.width < 1640);
        }

        #[test]
        fn top_taskbar_adapts_to_short_height() {
            assert_eq!(
                place(MONITOR, rect(0, 0, 1920, 32), rect(1650, 0, 1920, 32), 1.0),
                Ok(Placement {
                    x: 1472,
                    y: 2,
                    width: 174,
                    height: 28
                })
            );
        }

        #[test]
        fn left_and_right_vertical_bars_stay_above_tray() {
            for (left, right) in [(0, 62), (1858, 1920)] {
                let p = place(
                    MONITOR,
                    rect(left, 0, right, 1080),
                    rect(left, 880, right, 1080),
                    1.0,
                )
                .unwrap();
                assert_eq!(
                    p,
                    Placement {
                        x: left + 2,
                        y: 836,
                        width: 58,
                        height: 40
                    }
                );
                assert!(p.y + p.height < 880);
            }
        }

        #[test]
        fn negative_monitor_origin_and_high_dpi_use_physical_pixels() {
            assert_eq!(
                place(
                    rect(-2560, -1440, 0, 0),
                    rect(-2560, -72, 0, 0),
                    rect(-450, -72, 0, 0),
                    1.5
                ),
                Ok(Placement {
                    x: -717,
                    y: -66,
                    width: 261,
                    height: 60
                })
            );
        }

        #[test]
        fn destination_dpi_allows_migration_from_previous_high_dpi_monitor() {
            let bar = rect(0, 1032, 1920, 1080);
            let tray = rect(1640, 1032, 1920, 1080);
            // Source window's old 200% DPI would reject a 48px destination bar.
            assert_eq!(
                place(MONITOR, bar, tray, 2.0).unwrap_err(),
                PlaceError::NoRoom
            );
            assert_eq!(
                place(MONITOR, bar, tray, 1.0),
                Ok(Placement {
                    x: 1462,
                    y: 1036,
                    width: 174,
                    height: 40
                })
            );
        }

        #[test]
        fn insufficient_room_hides_instead_of_overlapping_tray() {
            assert_eq!(
                place(
                    MONITOR,
                    rect(0, 1032, 1920, 1080),
                    rect(90, 1032, 1920, 1080),
                    1.0
                )
                .unwrap_err(),
                PlaceError::NoRoom
            );
            assert_eq!(
                place(MONITOR, rect(0, 0, 62, 1080), rect(0, 20, 62, 1080), 1.0).unwrap_err(),
                PlaceError::NoRoom
            );
        }

        #[test]
        fn horizontal_width_can_shrink_without_overlapping_tray() {
            let p = place(
                MONITOR,
                rect(0, 1032, 1920, 1080),
                rect(140, 1032, 1920, 1080),
                1.0,
            )
            .unwrap();
            assert_eq!(p.width, 134);
            assert_eq!(p.x, 2);
        }

        #[test]
        fn hidden_reveal_strip_is_no_room_but_bad_reads_are_unreadable() {
            assert_eq!(
                place(
                    MONITOR,
                    rect(0, 1078, 1920, 1080),
                    rect(1640, 1078, 1920, 1080),
                    1.0
                )
                .unwrap_err(),
                PlaceError::NoRoom
            );
            assert_eq!(
                place(
                    MONITOR,
                    rect(0, 1078, 1920, 1126),
                    rect(1640, 1078, 1920, 1126),
                    1.0
                )
                .unwrap_err(),
                PlaceError::Unreadable
            );
            assert_eq!(
                place(MONITOR, rect(0, 1032, 1920, 1080), rect(0, 0, 0, 0), 1.0).unwrap_err(),
                PlaceError::Unreadable
            );
            assert_eq!(
                place(
                    MONITOR,
                    rect(0, 1032, 1920, 1080),
                    rect(1640, 1020, 1920, 1080),
                    1.0
                )
                .unwrap_err(),
                PlaceError::Unreadable
            );
        }

        #[test]
        fn invalid_dpi_and_undocked_taskbar_are_unreadable() {
            let bar = rect(0, 1032, 1920, 1080);
            let tray = rect(1640, 1032, 1920, 1080);
            for scale in [0.0, -1.0, f64::NAN, f64::INFINITY] {
                assert_eq!(
                    place(MONITOR, bar, tray, scale).unwrap_err(),
                    PlaceError::Unreadable
                );
            }
            assert_eq!(
                place(
                    MONITOR,
                    rect(0, 500, 1920, 548),
                    rect(1640, 500, 1920, 548),
                    1.0
                )
                .unwrap_err(),
                PlaceError::Unreadable
            );
        }

        #[test]
        fn place_failures_distinguish_bad_reads_from_no_room() {
            assert_eq!(
                place_failure(true, PlaceError::Unreadable),
                Unavailable::Retain("taskbar geometry is inconsistent")
            );
            assert_eq!(
                place_failure(false, PlaceError::Unreadable),
                Unavailable::Transient("taskbar geometry is inconsistent")
            );
            assert_eq!(
                place_failure(true, PlaceError::NoRoom),
                Unavailable::Retain("taskbar is momentarily unplaceable")
            );
            assert_eq!(
                place_failure(false, PlaceError::NoRoom),
                Unavailable::Hide("no room beside the tray")
            );
        }

        #[test]
        fn unreadable_place_failure_gets_grace_before_hiding() {
            let error = place(
                MONITOR,
                rect(0, 1032, 1920, 1080),
                rect(1640, 1032, 1920, 1080),
                0.0,
            )
            .unwrap_err();
            assert_eq!(error, PlaceError::Unreadable);
            assert_eq!(
                place_failure(false, error),
                Unavailable::Transient("taskbar geometry is inconsistent")
            );
            let mut failures = Failures::default();
            assert!(!failures.record_transient());
            assert!(failures.record_transient());
        }

        #[test]
        fn retained_failures_are_counted_and_not_reset() {
            let mut failures = Failures::default();
            assert!(!failures.record_transient());
            failures.record_while_retained();
            assert_eq!(failures.consecutive, Failures::LIMIT);
            assert!(failures.record_transient());
        }

        #[test]
        fn shell_retain_does_not_grant_a_fresh_grace_after_close() {
            let mut failures = Failures::default();
            assert!(!failures.record_transient());
            failures.record_while_retained();
            // The shell tick counted the failure: the first ordinary tick
            // after Start closes is already the second failure.
            assert!(failures.record_transient());
        }

        #[test]
        fn dead_or_replaced_foreground_is_not_proof_of_coverage() {
            assert!(rect_failure_is_proof(true, true));
            assert!(!rect_failure_is_proof(false, true));
            assert!(!rect_failure_is_proof(true, false));
            assert!(!rect_failure_is_proof(false, false));
        }

        #[test]
        fn shell_overlays_do_not_hide_the_widget_but_real_coverage_does() {
            assert!(foreground_hides(true, false));
            assert!(!foreground_hides(true, true));
            assert!(!foreground_hides(false, false));
            // Closing Start returns the foreground to an ordinary window whose
            // work area excludes the taskbar, so there is no coverage.
            assert!(!foreground_hides(false, true));
        }

        #[test]
        fn shell_surface_requires_a_shell_process_and_core_window_is_not_enough() {
            let core = "Windows.UI.Core.CoreWindow";
            assert!(shell_surface(
                core,
                Some("startmenuexperiencehost.exe"),
                false
            ));
            assert!(shell_surface(core, Some("explorer.exe"), false));
            // A fullscreen UWP app uses the same class as Start, but must not
            // be treated as a shell surface or the widget stays over it.
            assert!(!shell_surface(core, Some("game.exe"), false));
            assert!(!shell_surface(core, None, true));
            assert!(shell_surface("MultitaskingViewFrame", None, false));
            assert!(shell_surface("", Some("searchhost.exe"), false));
            // Topmost alone is not proof: an ordinary elevated tool can be
            // topmost without being part of the shell.
            assert!(!shell_surface("CabinetWClass", Some("other.exe"), true));
            assert!(shell_surface("CabinetWClass", Some("explorer.exe"), true));
        }

        #[test]
        fn start_overlay_spanning_the_monitor_does_not_hide_the_widget() {
            let bar = rect(0, 1032, 1920, 1080);
            // A shell host can span the whole monitor. Its rectangle looks like
            // fullscreen coverage, but it paints above the taskbar instead of
            // owning it, so classification must exempt it.
            assert!(covers_taskbar(MONITOR, MONITOR, bar, false));
            assert!(!foreground_hides(true, true));
        }

        #[test]
        fn unplaceable_taskbar_keeps_the_widget_only_while_shell_is_foreground() {
            assert!(unplaceable_hides(false));
            assert!(!unplaceable_hides(true));
        }

        #[test]
        fn transient_failures_hide_only_after_the_grace_tick() {
            let mut failures = Failures::default();
            assert!(!failures.record_transient());
            assert!(failures.record_transient());
            assert!(failures.record_transient());
            failures.reset();
            assert!(!failures.record_transient());
        }

        #[test]
        fn shell_foreground_retains_failures_but_ordinary_proof_hides() {
            assert_eq!(unavailable(true, true, "x"), Unavailable::Retain("x"));
            assert_eq!(unavailable(false, true, "x"), Unavailable::Transient("x"));
            assert_eq!(unavailable(true, false, "x"), Unavailable::Retain("x"));
            assert_eq!(unavailable(false, false, "x"), Unavailable::Hide("x"));
        }

        #[test]
        fn fullscreen_covers_bar_but_maximized_work_area_does_not() {
            let bar = rect(0, 1032, 1920, 1080);
            assert!(covers_taskbar(MONITOR, MONITOR, bar, false));
            assert!(covers_taskbar(
                rect(-8, -8, 1928, 1088),
                MONITOR,
                bar,
                false
            ));
            assert!(!covers_taskbar(rect(0, 0, 1920, 1032), MONITOR, bar, true));
            assert!(!covers_taskbar(
                rect(1920, 0, 3840, 1080),
                MONITOR,
                bar,
                false
            ));
            assert!(!covers_taskbar(bar, MONITOR, bar, false));
        }

        #[test]
        fn maximized_window_with_autohide_does_not_suppress_revealed_bar() {
            let bar = rect(0, 1032, 1920, 1080);
            assert!(!covers_taskbar(MONITOR, MONITOR, bar, true));
            assert!(!covers_taskbar(
                rect(-8, -8, 1928, 1088),
                MONITOR,
                bar,
                true
            ));
        }
    }
}

#[cfg(windows)]
mod native {
    use super::geometry::{self, Placement, Rect};
    use std::mem::size_of;
    use std::ptr::null;
    use windows_sys::Win32::Foundation::{HWND, RECT};
    use windows_sys::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONULL,
    };
    use windows_sys::Win32::UI::HiDpi::GetDpiForWindow;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        FindWindowExW, FindWindowW, GetClassNameW, GetForegroundWindow, GetShellWindow,
        GetWindowLongW, GetWindowRect, GetWindowThreadProcessId, IsChild, IsWindow,
        IsWindowVisible, IsZoomed, SetWindowPos, GWL_EXSTYLE, HWND_TOPMOST, SWP_NOACTIVATE,
        SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, WS_EX_TOPMOST,
    };

    fn rect(hwnd: HWND) -> Option<Rect> {
        let mut rect = RECT::default();
        // HWNDs are borrowed from Explorer/foreground queries; never retained
        // across ticks or owned/closed by this module.
        if unsafe { GetWindowRect(hwnd, &mut rect) } == 0 {
            return None;
        }
        Some(from_rect(rect))
    }

    fn from_rect(rect: RECT) -> Rect {
        Rect {
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
        }
    }

    fn is_desktop(hwnd: HWND) -> bool {
        if hwnd == unsafe { GetShellWindow() } {
            return true;
        }
        let mut class = [0u16; 64];
        let length = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) };
        let class = String::from_utf16_lossy(&class[..length.max(0) as usize]);
        matches!(class.as_str(), "Progman" | "WorkerW")
    }

    /// Read the shell-surface inputs here; the decision itself is pure and
    /// covered by tests in `geometry`.
    fn is_shell_surface(hwnd: HWND) -> bool {
        let mut class = [0u16; 64];
        let length = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) };
        let class = String::from_utf16_lossy(&class[..length.max(0) as usize]);
        geometry::shell_surface(&class, process_name(hwnd).as_deref(), is_topmost(hwnd))
    }

    fn is_topmost(hwnd: HWND) -> bool {
        unsafe { GetWindowLongW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOPMOST != 0 }
    }

    /// Lower-case executable name of the window's owning process, or `None`
    /// when the process cannot be queried (elevated process, gone meanwhile).
    fn process_name(hwnd: HWND) -> Option<String> {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{
            OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
        };

        let mut pid = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
        if pid == 0 {
            return None;
        }
        let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if process.is_null() {
            return None;
        }
        let mut path = [0u16; 260];
        let mut length = path.len() as u32;
        let ok = unsafe { QueryFullProcessImageNameW(process, 0, path.as_mut_ptr(), &mut length) };
        unsafe { CloseHandle(process) };
        if ok == 0 {
            return None;
        }
        let path = String::from_utf16_lossy(&path[..length as usize]);
        let name = path.rsplit(['\\', '/']).next().unwrap_or_default();
        Some(name.to_ascii_lowercase())
    }

    pub fn placement(
        window: &tauri::WebviewWindow,
    ) -> Result<(Placement, bool), geometry::Unavailable> {
        let own = window
            .hwnd()
            .map_err(|_| geometry::Unavailable::Hide("no widget hwnd"))?
            .0 as HWND;
        let foreground = unsafe { GetForegroundWindow() };
        // Rediscover both windows every time (Explorer restarts invalidate HWNDs).
        let taskbar = unsafe { FindWindowW(windows_sys::w!("Shell_TrayWnd"), null()) };
        // Classify the foreground before any geometry failure can return: a
        // shell surface must keep the widget even when a taskbar/tray read
        // fails for one tick.
        let mut shell_foreground = false;
        if !foreground.is_null() && foreground != own && !is_desktop(foreground) {
            let on_taskbar = !taskbar.is_null()
                && (foreground == taskbar || unsafe { IsChild(taskbar, foreground) } != 0);
            if !on_taskbar {
                shell_foreground = is_shell_surface(foreground);
            }
        }
        if taskbar.is_null() || unsafe { IsWindow(taskbar) } == 0 {
            return Err(geometry::unavailable(shell_foreground, true, "no taskbar"));
        }
        if unsafe { IsWindowVisible(taskbar) } == 0 {
            // Visibility is an explicit state, not a failed read: a bar that
            // Windows reports hidden has no place for the widget.
            return Err(geometry::unavailable(
                shell_foreground,
                false,
                "taskbar hidden",
            ));
        }
        // The widget may still be on a previous monitor. Using its current
        // scale can reject the new taskbar's height and prevent migration
        // forever, so query DPI from the destination HWND instead.
        let scale = unsafe { GetDpiForWindow(taskbar) } as f64 / 96.0;
        let tray = unsafe {
            FindWindowExW(
                taskbar,
                std::ptr::null_mut(),
                windows_sys::w!("TrayNotifyWnd"),
                null(),
            )
        };
        if tray.is_null() || unsafe { IsWindow(tray) } == 0 {
            return Err(geometry::unavailable(shell_foreground, true, "no tray"));
        }
        if unsafe { IsWindowVisible(tray) } == 0 {
            return Err(geometry::unavailable(
                shell_foreground,
                false,
                "tray hidden",
            ));
        }
        let monitor = unsafe { MonitorFromWindow(taskbar, MONITOR_DEFAULTTONULL) };
        if monitor.is_null() {
            return Err(geometry::unavailable(shell_foreground, true, "no monitor"));
        }
        let mut info = MONITORINFO {
            cbSize: size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if unsafe { GetMonitorInfoW(monitor, &mut info) } == 0 {
            return Err(geometry::unavailable(
                shell_foreground,
                true,
                "no monitor info",
            ));
        }
        let monitor = from_rect(info.rcMonitor);
        let taskbar_rect = rect(taskbar)
            .ok_or_else(|| geometry::unavailable(shell_foreground, true, "no taskbar rect"))?;
        let tray_rect = rect(tray)
            .ok_or_else(|| geometry::unavailable(shell_foreground, true, "no tray rect"))?;
        if !shell_foreground
            && !foreground.is_null()
            && foreground != own
            && foreground != taskbar
            && unsafe { IsChild(taskbar, foreground) } == 0
            && !is_desktop(foreground)
        {
            let Some(bounds) = rect(foreground) else {
                // The window can die or lose focus between classification and
                // this read. Re-read both before treating the missing
                // rectangle as proof of coverage; a replaced/dead foreground
                // is an indeterminate tick, not an immediate hide.
                let same = unsafe { GetForegroundWindow() } == foreground;
                let alive = unsafe { IsWindow(foreground) } != 0;
                if !geometry::rect_failure_is_proof(same, alive) {
                    return Err(geometry::unavailable(
                        shell_foreground,
                        true,
                        "foreground changed while reading",
                    ));
                }
                // A live, still-foreground window without a rectangle cannot
                // be cleared of covering the bar; hide rather than paint a
                // widget over a possible fullscreen window.
                return Err(geometry::Unavailable::Hide("no foreground rect"));
            };
            let covers = geometry::covers_taskbar(
                bounds,
                monitor,
                taskbar_rect,
                unsafe { IsZoomed(foreground) } != 0,
            );
            if geometry::foreground_hides(covers, false) {
                return Err(geometry::Unavailable::Hide("foreground covers the taskbar"));
            }
        }
        let placement = geometry::place(monitor, taskbar_rect, tray_rect, scale)
            .map_err(|error| geometry::place_failure(shell_foreground, error))?;
        *last_placement()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(placement);
        Ok((placement, shell_foreground))
    }

    fn last_placement() -> &'static std::sync::Mutex<Option<Placement>> {
        use std::sync::{Mutex, OnceLock};
        static LAST: OnceLock<Mutex<Option<Placement>>> = OnceLock::new();
        LAST.get_or_init(|| Mutex::new(None))
    }

    /// Show the widget at its last good bounds when a shell surface suppresses
    /// a fresh placement. Without this a widget hidden by an earlier tick stays
    /// hidden until the shell closes and geometry becomes readable again.
    pub fn restore_last(window: &tauri::WebviewWindow) -> bool {
        if window.is_visible().unwrap_or(false) {
            return true;
        }
        let placement = *last_placement()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(placement) = placement else {
            return false;
        };
        if set_bounds(window, &placement).is_err() {
            return false;
        }
        super::visibility(window, true).is_ok()
    }

    pub fn forget_placement() {
        *last_placement()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    }

    /// Re-read the foreground right before a z-order change. A shell flyout
    /// that opened after `placement` must not be covered by the widget.
    pub fn shell_surface_active() -> bool {
        let foreground = unsafe { GetForegroundWindow() };
        !foreground.is_null() && is_shell_surface(foreground)
    }

    /// Put the widget back at the top of the topmost band without activating
    /// it. Called only when no shell surface owns the foreground.
    pub fn raise_to_top(window: &tauri::WebviewWindow) -> Result<(), String> {
        let hwnd = window.hwnd().map_err(|error| error.to_string())?.0 as HWND;
        let ok = unsafe {
            SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            )
        };
        if ok == 0 {
            Err(format!(
                "SetWindowPos failed: {}",
                std::io::Error::last_os_error()
            ))
        } else {
            Ok(())
        }
    }

    /// Move and resize in one call while preserving z-order and activation.
    pub fn set_bounds(window: &tauri::WebviewWindow, placement: &Placement) -> Result<(), String> {
        let hwnd = window.hwnd().map_err(|e| e.to_string())?.0 as HWND;
        let ok = unsafe {
            SetWindowPos(
                hwnd,
                std::ptr::null_mut(),
                placement.x,
                placement.y,
                placement.width,
                placement.height,
                SWP_NOACTIVATE | SWP_NOZORDER,
            )
        };
        if ok == 0 {
            Err(format!(
                "SetWindowPos failed: {}",
                std::io::Error::last_os_error()
            ))
        } else {
            Ok(())
        }
    }

    fn failure_streak() -> &'static std::sync::Mutex<geometry::Failures> {
        use std::sync::{Mutex, OnceLock};
        static STREAK: OnceLock<Mutex<geometry::Failures>> = OnceLock::new();
        STREAK.get_or_init(|| Mutex::new(geometry::Failures::default()))
    }

    /// Record an unreadable geometry tick; `true` once the grace tick is over.
    pub fn transient_failure_should_hide() -> bool {
        let mut streak = failure_streak().lock().unwrap_or_else(|e| e.into_inner());
        streak.record_transient()
    }

    /// Keep counting failures that a shell surface suppresses, without hiding.
    pub fn record_retained_failure() {
        let mut streak = failure_streak().lock().unwrap_or_else(|e| e.into_inner());
        streak.record_while_retained();
    }

    pub fn reset_failure_streak() {
        let mut streak = failure_streak().lock().unwrap_or_else(|e| e.into_inner());
        streak.reset();
    }

    fn last_unavailable() -> &'static std::sync::Mutex<Option<&'static str>> {
        use std::sync::{Mutex, OnceLock};
        static LAST: OnceLock<Mutex<Option<&'static str>>> = OnceLock::new();
        LAST.get_or_init(|| Mutex::new(None))
    }

    /// Log a placement failure only when it starts, so a per-tick message does
    /// not flood the log while the taskbar is legitimately unavailable.
    pub fn log_unavailable(reason: &'static str) {
        let mut last = last_unavailable().lock().unwrap_or_else(|e| e.into_inner());
        if *last != Some(reason) {
            eprintln!("taskbar widget placement unavailable: {reason}");
            *last = Some(reason);
        }
    }

    pub fn log_available() {
        let mut last = last_unavailable().lock().unwrap_or_else(|e| e.into_inner());
        *last = None;
    }
}
