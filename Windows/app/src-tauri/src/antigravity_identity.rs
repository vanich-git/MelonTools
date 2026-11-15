//! The one place the Antigravity client identity is defined.
//!
//! Google compares the client we claim to be against the client it shipped, so
//! the version and the changelist must stay a matched pair taken from the
//! official build. The pair is calibrated, never discovered: bumping the
//! version without its changelist is a stronger tell than being one release
//! behind, because no real build ever emits a mismatched pair.
//!
//! Keep this module in sync with `AntigravityClientIdentity` in the macOS app
//! and `internal/misc/antigravity_version.go` in the shared engine.

/// Official sibling app used for the desktop quota probe. Antigravity reads as
/// the same client on both platforms, so only the `os_type`/`arch` segment moves.
pub const HUB_VERSION: &str = "2.28.0";

/// Changelist shipped with [`HUB_VERSION`].
pub const HUB_CHANGELIST: &str = "1008300195";

/// Full User-Agent for calls made from this process.
///
/// `cl` is present because the official build always sends it: a User-Agent
/// carrying a version but no changelist is a shape the real client never
/// produces.
pub fn user_agent() -> String {
    format!(
        "antigravity/hub/{HUB_VERSION} (aidev_client; os_type={}; arch={}; cl={HUB_CHANGELIST})",
        std::env::consts::OS,
        std::env::consts::ARCH
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_agent_carries_version_and_changelist() {
        let ua = user_agent();
        assert!(ua.starts_with("antigravity/hub/2.28.0 (aidev_client; "));
        assert!(ua.contains(" cl=1008300195)"));
    }

    #[test]
    fn user_agent_matches_the_host_platform() {
        let ua = user_agent();
        assert!(ua.contains(&format!("os_type={}", std::env::consts::OS)));
        assert!(ua.contains(&format!("arch={}", std::env::consts::ARCH)));
    }

    /// The bug this module exists to prevent: three components on one machine
    /// advertising three different versions of the same client.
    #[test]
    fn version_and_changelist_are_a_known_pair() {
        assert_eq!((HUB_VERSION, HUB_CHANGELIST), ("2.28.0", "1008300195"));
    }
}
