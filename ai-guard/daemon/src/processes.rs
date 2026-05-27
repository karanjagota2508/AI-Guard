use std::collections::HashSet;
use std::time::Duration;

use anyhow::Result;
use sysinfo::{Pid, ProcessesToUpdate, System};
use tokio::time;
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use crate::config::AppConfig;
use crate::contracts::GuardMode;
use crate::runtime::AppState;

pub async fn run_process_monitor(
    state: AppState,
    cancel: CancellationToken,
    interval: Duration,
) -> Result<()> {
    let mut ticker = time::interval(interval);
    let mut system = System::new_all();

    loop {
        tokio::select! {
            _ = cancel.cancelled() => break,
            _ = ticker.tick() => {
                system.refresh_processes(ProcessesToUpdate::All, true);
                sync_desktop_activity(&state, &system);
                if state.guard.mode() == GuardMode::Active {
                    enforce_process_blocking(&state.config, &system);
                }
            }
        }
    }

    Ok(())
}

fn sync_desktop_activity(state: &AppState, system: &System) {
    let foreground = foreground_process_name(system);
    let claude_active = foreground
        .as_deref()
        .filter(|name| matches_process(name, &state.config.claude.desktop_processes))
        .is_some()
        || any_matching_process(system, &state.config.claude.desktop_processes);

    let snapshot = state.guard.note_desktop_activity(claude_active);
    debug!(mode = ?snapshot.mode, "desktop activity sync complete");
}

fn enforce_process_blocking(config: &AppConfig, system: &System) {
    let blocked: Vec<String> = config
        .blocking
        .process_names
        .iter()
        .map(|item| normalize_process_name(item))
        .collect();
    let exempt: HashSet<String> = config
        .blocking
        .exempt_process_names
        .iter()
        .map(|item| normalize_process_name(item))
        .collect();
    let self_pid = std::process::id();

    for (pid, process) in system.processes() {
        let pid_u32 = pid.as_u32();
        if pid_u32 == self_pid {
            continue;
        }

        let raw_name = process.name().to_string_lossy().to_string();
        let normalized = normalize_process_name(&raw_name);
        if exempt.contains(&normalized) {
            continue;
        }

        if blocked
            .iter()
            .any(|candidate| normalized == *candidate || (candidate.len() >= 4 && normalized.starts_with(candidate)))
        {
            warn!(
                pid = pid_u32,
                process = raw_name,
                "blocking disallowed process"
            );
            let _ = process.kill();
        }
    }
}

fn any_matching_process(system: &System, process_names: &[String]) -> bool {
    system
        .processes()
        .values()
        .any(|process| matches_process(&process.name().to_string_lossy(), process_names))
}

fn matches_process(name: &str, candidates: &[String]) -> bool {
    let normalized = normalize_process_name(name);
    candidates.iter().any(|candidate| {
        let expected = normalize_process_name(candidate);
        if normalized == expected {
            return true;
        }
        if expected.len() >= 4 && normalized.starts_with(&expected) {
            return true;
        }
        false
    })
}

fn normalize_process_name(value: &str) -> String {
    let name_without_exe = if value.len() > 4 && value.to_ascii_lowercase().ends_with(".exe") {
        &value[..value.len() - 4]
    } else {
        value
    };
    name_without_exe
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_lowercase()
}

#[cfg(windows)]
fn foreground_process_name(system: &System) -> Option<String> {
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.0.is_null() {
            return None;
        }

        let mut process_id = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut process_id));
        if process_id == 0 {
            return None;
        }

        let pid = Pid::from_u32(process_id);
        system
            .process(pid)
            .map(|process| process.name().to_string_lossy().to_string())
    }
}

#[cfg(not(windows))]
fn foreground_process_name(_system: &System) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::{matches_process, normalize_process_name};

    #[test]
    fn normalizes_process_name_without_punctuation() {
        assert_eq!(normalize_process_name("LM Studio.exe"), "lmstudio");
    }

    #[test]
    fn matches_process_with_prefix_normalization() {
        assert!(matches_process("Cursor.exe", &[String::from("Cursor")]));
        assert!(matches_process("Ollama App", &[String::from("Ollama")]));
    }

    #[test]
    fn short_process_candidate_requires_exact_match() {
        assert!(matches_process("jan.exe", &[String::from("jan")]));
        assert!(!matches_process("janitor.exe", &[String::from("jan")]));
    }

    #[test]
    fn does_not_match_unrelated_process() {
        assert!(!matches_process("notepad.exe", &[String::from("Cursor")]));
    }
}
