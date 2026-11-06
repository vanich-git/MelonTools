//! A separate, non-activating window beside the primary Explorer notification
//! area. Nothing is injected into Explorer and no taskbar space is reserved:
//! when the native geometry is unavailable or unsafe, the widget stays hidden.

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
                    let _ = visibility(&window, false);
                }
            }
        });
    }
    #[cfg(not(windows))]
    let _ = app;
}

/// Place and show an existing widget only when native taskbar/tray visibility,
/// monitor bounds and foreground coverage all permit it. `false` means hidden
/// or unsupported, never a successful approximation at a desktop corner.
pub fn reposition(app: &AppHandle) -> Result<bool, String> {
    let Some(window) = app.get_webview_window(LABEL) else {
        return Ok(false);
    };
    #[cfg(windows)]
    {
        let result = (|| {
            let Some(placement) = native::placement(&window) else {
                return Ok(false);
            };
            let size = tauri::PhysicalSize::new(placement.width as u32, placement.height as u32);
            let position = tauri::PhysicalPosition::new(placement.x, placement.y);
            if window.inner_size().map_err(|e| e.to_string())? != size
                || window.outer_position().map_err(|e| e.to_string())? != position
            {
                // Do not briefly resize the previous visible location over the
                // tray while changing DPI, monitor or taskbar orientation.
                visibility(&window, false)?;
                window.set_size(size).map_err(|e| e.to_string())?;
                window.set_position(position).map_err(|e| e.to_string())?;
            }
            visibility(&window, true)?;
            Ok(true)
        })();
        if !matches!(result, Ok(true)) {
            // A failed move/resize must not leave the previous overlay behind.
            visibility(&window, false)?;
        }
        result
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

    #[derive(Debug, PartialEq, Eq)]
    pub struct Placement {
        pub x: i32,
        pub y: i32,
        pub width: i32,
        pub height: i32,
    }

    /// All rectangles and the result are physical desktop pixels. The scale
    /// belongs to the destination taskbar, not the widget's previous monitor.
    pub fn place(monitor: Rect, taskbar: Rect, tray: Rect, scale: f64) -> Option<Placement> {
        if !scale.is_finite()
            || !(0.5..=8.0).contains(&scale)
            || !monitor.valid()
            || !monitor.contains(taskbar)
            || !taskbar.contains(tray)
        {
            return None;
        }
        let px = |logical: f64| (logical * scale).round() as i32;
        let inset = px(2.0).max(1);
        let gap = px(4.0).max(1);
        let min_height = px(24.0);
        let horizontal = taskbar.width() >= taskbar.height();
        let placement = if horizontal {
            // A partially slid-offscreen auto-hide taskbar, a 1–2px reveal
            // strip, or an undocked/floating rectangle is not a safe host.
            if taskbar.left != monitor.left
                || taskbar.right != monitor.right
                || (taskbar.top != monitor.top && taskbar.bottom != monitor.bottom)
            {
                return None;
            }
            let height = px(40.0).min(taskbar.height() - 2 * inset);
            let width = px(174.0).min(tray.left - taskbar.left - gap - inset);
            if height < min_height || width < px(96.0) {
                return None;
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
                return None;
            }
            let width = px(174.0).min(taskbar.width() - 2 * inset);
            let height = px(40.0).min(tray.top - taskbar.top - gap - inset);
            if width < px(32.0) || height < min_height {
                return None;
            }
            Placement {
                x: taskbar.left + (taskbar.width() - width) / 2,
                y: tray.top - gap - height,
                width,
                height,
            }
        };
        Some(placement)
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
                Some(Placement {
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
                Some(Placement {
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
            assert!(place(MONITOR, bar, tray, 2.0).is_none());
            assert_eq!(
                place(MONITOR, bar, tray, 1.0),
                Some(Placement {
                    x: 1462,
                    y: 1036,
                    width: 174,
                    height: 40
                })
            );
        }

        #[test]
        fn insufficient_room_hides_instead_of_overlapping_tray() {
            assert!(place(
                MONITOR,
                rect(0, 1032, 1920, 1080),
                rect(90, 1032, 1920, 1080),
                1.0
            )
            .is_none());
            assert!(place(MONITOR, rect(0, 0, 62, 1080), rect(0, 20, 62, 1080), 1.0).is_none());
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
        fn hidden_reveal_strip_offscreen_and_missing_tray_are_unsafe() {
            assert!(place(
                MONITOR,
                rect(0, 1078, 1920, 1080),
                rect(1640, 1078, 1920, 1080),
                1.0
            )
            .is_none());
            assert!(place(
                MONITOR,
                rect(0, 1078, 1920, 1126),
                rect(1640, 1078, 1920, 1126),
                1.0
            )
            .is_none());
            assert!(place(MONITOR, rect(0, 1032, 1920, 1080), rect(0, 0, 0, 0), 1.0).is_none());
            assert!(place(
                MONITOR,
                rect(0, 1032, 1920, 1080),
                rect(1640, 1020, 1920, 1080),
                1.0
            )
            .is_none());
        }

        #[test]
        fn invalid_dpi_and_undocked_taskbar_are_unsafe() {
            let bar = rect(0, 1032, 1920, 1080);
            let tray = rect(1640, 1032, 1920, 1080);
            for scale in [0.0, -1.0, f64::NAN, f64::INFINITY] {
                assert!(place(MONITOR, bar, tray, scale).is_none());
            }
            assert!(place(
                MONITOR,
                rect(0, 500, 1920, 548),
                rect(1640, 500, 1920, 548),
                1.0
            )
            .is_none());
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
        GetWindowLongW, GetWindowRect, GWL_EXSTYLE, IsChild, IsWindowVisible, IsZoomed,
        WS_EX_TRANSPARENT,
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

    /// Shell surfaces that float above the desktop while open but do not really
    /// cover the taskbar. Windows 11 draws Start, search, the notification
    /// centre and Task View in full-screen XAML hosts: their window rect spans
    /// the whole monitor, so the geometry check read "a window covers the
    /// taskbar" and the widget disappeared the moment Start was clicked.
    fn is_shell_overlay(hwnd: HWND) -> bool {
        let mut class = [0u16; 64];
        let length = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) };
        let class = String::from_utf16_lossy(&class[..length.max(0) as usize]);
        if matches!(
            class.as_str(),
            "Windows.UI.Core.CoreWindow"
                | "XamlExplorerHostIslandWindow"
                | "Windows.Internal.Shell.TabProxyWindow"
                | "MultitaskingViewFrame"
                | "ForegroundStaging"
                | "TopLevelWindowForOverflowXamlIsland"
                | "NotifyIconOverflowWindow"
        ) {
            return true;
        }
        // A click-through veil (transparent layered host) paints nothing over
        // the bar, so it must not count as coverage either.
        unsafe { GetWindowLongW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TRANSPARENT != 0 }
    }

    pub fn placement(window: &tauri::WebviewWindow) -> Option<Placement> {
        // Rediscover both windows every time (Explorer restarts invalidate HWNDs).
        let taskbar = unsafe { FindWindowW(windows_sys::w!("Shell_TrayWnd"), null()) };
        if taskbar.is_null() || unsafe { IsWindowVisible(taskbar) } == 0 {
            return None;
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
        if tray.is_null() || unsafe { IsWindowVisible(tray) } == 0 {
            return None;
        }
        let monitor = unsafe { MonitorFromWindow(taskbar, MONITOR_DEFAULTTONULL) };
        if monitor.is_null() {
            return None;
        }
        let mut info = MONITORINFO {
            cbSize: size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if unsafe { GetMonitorInfoW(monitor, &mut info) } == 0 {
            return None;
        }
        let monitor = from_rect(info.rcMonitor);
        let taskbar_rect = rect(taskbar)?;
        let tray_rect = rect(tray)?;
        let foreground = unsafe { GetForegroundWindow() };
        let own = window.hwnd().ok()?.0 as HWND;
        if !foreground.is_null()
            && foreground != own
            && foreground != taskbar
            && unsafe { IsChild(taskbar, foreground) } == 0
            && !is_desktop(foreground)
            && !is_shell_overlay(foreground)
            && geometry::covers_taskbar(
                rect(foreground)?,
                monitor,
                taskbar_rect,
                unsafe { IsZoomed(foreground) } != 0,
            )
        {
            return None;
        }
        geometry::place(monitor, taskbar_rect, tray_rect, scale)
    }
}
