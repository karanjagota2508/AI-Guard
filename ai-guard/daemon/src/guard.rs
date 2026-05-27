use std::time::{Duration, Instant};

use parking_lot::RwLock;
use tracing::info;

use crate::contracts::GuardMode;

#[derive(Debug, Clone)]
pub struct GuardSnapshot {
    pub mode: GuardMode,
    pub active_sources: Vec<String>,
}

#[derive(Debug)]
struct GuardState {
    mode: GuardMode,
    browser_activity_deadline: Option<Instant>,
    desktop_activity_deadline: Option<Instant>,
}

pub struct GuardController {
    browser_ttl: Duration,
    desktop_ttl: Duration,
    inner: RwLock<GuardState>,
}

impl GuardController {
    pub fn new(browser_ttl: Duration, desktop_ttl: Duration) -> Self {
        Self {
            browser_ttl,
            desktop_ttl,
            inner: RwLock::new(GuardState {
                mode: GuardMode::Idle,
                browser_activity_deadline: None,
                desktop_activity_deadline: None,
            }),
        }
    }

    pub fn note_browser_activity(&self, visible: bool) -> GuardSnapshot {
        let mut state = self.inner.write();
        state.browser_activity_deadline = if visible {
            Some(Instant::now() + self.browser_ttl)
        } else {
            None
        };
        self.recompute_locked(&mut state)
    }

    pub fn note_desktop_activity(&self, active: bool) -> GuardSnapshot {
        let mut state = self.inner.write();
        state.desktop_activity_deadline = if active {
            Some(Instant::now() + self.desktop_ttl)
        } else {
            None
        };
        self.recompute_locked(&mut state)
    }

    pub fn snapshot(&self) -> GuardSnapshot {
        let mut state = self.inner.write();
        self.recompute_locked(&mut state)
    }

    pub fn mode(&self) -> GuardMode {
        self.snapshot().mode
    }

    fn recompute_locked(&self, state: &mut GuardState) -> GuardSnapshot {
        let now = Instant::now();
        let browser_active = state
            .browser_activity_deadline
            .is_some_and(|deadline| deadline > now);
        let desktop_active = state
            .desktop_activity_deadline
            .is_some_and(|deadline| deadline > now);

        let mut active_sources = Vec::new();
        if browser_active {
            active_sources.push("claude_web".to_string());
        }
        if desktop_active {
            active_sources.push("claude_desktop".to_string());
        }

        let next_mode = if active_sources.is_empty() {
            GuardMode::Idle
        } else {
            GuardMode::Active
        };

        if next_mode != state.mode {
            info!(?next_mode, ?active_sources, "guard mode changed");
            state.mode = next_mode;
        }

        GuardSnapshot {
            mode: state.mode,
            active_sources,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::thread;

    use super::GuardController;
    use crate::contracts::GuardMode;

    #[test]
    fn enters_active_mode_when_browser_activity_is_noted() {
        let controller = GuardController::new(
            std::time::Duration::from_millis(50),
            std::time::Duration::from_millis(50),
        );

        let snapshot = controller.note_browser_activity(true);
        assert_eq!(snapshot.mode, GuardMode::Active);
        assert_eq!(snapshot.active_sources, vec!["claude_web"]);
    }

    #[test]
    fn returns_to_idle_when_activity_expires() {
        let controller = GuardController::new(
            std::time::Duration::from_millis(20),
            std::time::Duration::from_millis(20),
        );

        controller.note_browser_activity(true);
        thread::sleep(std::time::Duration::from_millis(35));

        let snapshot = controller.snapshot();
        assert_eq!(snapshot.mode, GuardMode::Idle);
        assert!(snapshot.active_sources.is_empty());
    }

    #[test]
    fn keeps_both_sources_when_browser_and_desktop_are_active() {
        let controller = GuardController::new(
            std::time::Duration::from_millis(50),
            std::time::Duration::from_millis(50),
        );

        controller.note_browser_activity(true);
        let snapshot = controller.note_desktop_activity(true);
        assert_eq!(snapshot.mode, GuardMode::Active);
        assert_eq!(snapshot.active_sources.len(), 2);
    }
}
