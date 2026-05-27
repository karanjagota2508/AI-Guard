use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PiiConfig {
    #[serde(default = "default_pii_enabled")]
    pub enabled: bool,
    #[serde(default = "default_pii_confidence_score")]
    pub confidence_score: f64,
    #[serde(default = "default_pii_action")]
    pub action: String,
}

fn default_pii_enabled() -> bool { true }
fn default_pii_confidence_score() -> f64 { 0.35 }
fn default_pii_action() -> String { "redact".to_string() }

impl Default for PiiConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            confidence_score: 0.35,
            action: "redact".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub listen_address: String,
    pub auth_token: String,
    pub pii_engine_url: String,
    pub pii_anonymize_url: Option<String>,
    pub managed_pii: Option<ManagedPiiConfig>,
    #[serde(default)]
    pub pii: PiiConfig,
    pub scan_timeout_ms: u64,
    pub fail_closed: bool,
    pub browser_heartbeat_ttl_ms: u64,
    pub desktop_activity_ttl_ms: u64,
    pub process_poll_ms: u64,
    pub extension_ids: Vec<String>,
    pub claude: ClaudeConfig,
    pub blocking: BlockingConfig,
    pub package: PackageConfig,
    pub logging: LoggingConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClaudeConfig {
    pub web_hosts: Vec<String>,
    pub desktop_processes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockingConfig {
    pub browser_hosts: Vec<String>,
    pub process_names: Vec<String>,
    pub exempt_process_names: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageConfig {
    #[serde(default)]
    pub chrome_extension_id: String,
    #[serde(default)]
    pub edge_extension_id: String,
    #[serde(default)]
    pub chrome_update_url: String,
    #[serde(default)]
    pub edge_update_url: String,
    #[serde(default)]
    pub extension_id: Option<String>,
    pub extension_version: String,
    pub extension_crx_path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoggingConfig {
    pub directory: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagedPiiConfig {
    pub enabled: bool,
    pub executable: PathBuf,
    pub args: Vec<String>,
    pub working_directory: PathBuf,
    pub health_url: String,
    pub startup_timeout_ms: u64,
    pub restart_delay_ms: u64,
    pub env: BTreeMap<String, String>,
    pub stdout_log_path: Option<PathBuf>,
    pub stderr_log_path: Option<PathBuf>,
}

impl AppConfig {
    pub fn load(path: &Path) -> Result<Self> {
        let raw = fs::read_to_string(path)
            .with_context(|| format!("failed to read config file {}", path.display()))?;
        let mut config: AppConfig = serde_json::from_str(&raw)
            .with_context(|| format!("failed to parse config file {}", path.display()))?;
        config.package.normalize();
        let config_dir = path
            .parent()
            .ok_or_else(|| anyhow!("config path {} has no parent directory", path.display()))?;
        config.package.extension_crx_path =
            resolve_path(config_dir, &config.package.extension_crx_path);
        config.logging.directory = resolve_path(config_dir, &config.logging.directory);
        if let Some(managed_pii) = config.managed_pii.as_mut() {
            managed_pii.executable = resolve_command_path(config_dir, &managed_pii.executable);
            managed_pii.working_directory =
                resolve_path(config_dir, &managed_pii.working_directory);
            managed_pii.stdout_log_path = managed_pii
                .stdout_log_path
                .as_ref()
                .map(|value| resolve_path(config_dir, value));
            managed_pii.stderr_log_path = managed_pii
                .stderr_log_path
                .as_ref()
                .map(|value| resolve_path(config_dir, value));
        }
        Ok(config)
    }

    pub fn listen_socket_addr(&self) -> Result<SocketAddr> {
        self.listen_address
            .parse()
            .with_context(|| format!("invalid listen address {}", self.listen_address))
    }

    pub fn browser_heartbeat_ttl(&self) -> Duration {
        Duration::from_millis(self.browser_heartbeat_ttl_ms)
    }

    pub fn desktop_activity_ttl(&self) -> Duration {
        Duration::from_millis(self.desktop_activity_ttl_ms)
    }

    pub fn process_poll_interval(&self) -> Duration {
        Duration::from_millis(self.process_poll_ms)
    }

    pub fn scan_timeout(&self) -> Duration {
        Duration::from_millis(self.scan_timeout_ms)
    }

    pub fn allowed_origins(&self) -> Vec<String> {
        self.extension_ids
            .iter()
            .map(|id| format!("chrome-extension://{id}"))
            .collect()
    }

    pub fn is_allowed_origin(&self, origin: &str) -> bool {
        let normalized = origin.trim_end_matches('/');
        self.allowed_origins().iter().any(|item| item == normalized)
    }

    pub fn is_allowed_extension_id(&self, extension_id: &str) -> bool {
        self.extension_ids.iter().any(|item| item == extension_id)
    }

    pub fn base_url(&self) -> Result<String> {
        let addr = self.listen_socket_addr()?;
        Ok(format!("http://127.0.0.1:{}", addr.port()))
    }
}

impl PackageConfig {
    fn normalize(&mut self) {
        if self.chrome_extension_id.trim().is_empty() {
            if let Some(legacy) = self.extension_id.clone() {
                self.chrome_extension_id = legacy;
            }
        }

        if self.edge_extension_id.trim().is_empty() {
            if let Some(legacy) = self.extension_id.clone() {
                self.edge_extension_id = legacy;
            }
        }
    }
}

impl ManagedPiiConfig {
    pub fn startup_timeout(&self) -> Duration {
        Duration::from_millis(self.startup_timeout_ms)
    }

    pub fn restart_delay(&self) -> Duration {
        Duration::from_millis(self.restart_delay_ms)
    }
}

pub fn default_config_path() -> PathBuf {
    if let Ok(explicit) = env::var("AI_GUARD_CONFIG") {
        return PathBuf::from(explicit);
    }

    let exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("."));
    let exe_dir = exe.parent().unwrap_or_else(|| Path::new("."));
    let sibling = exe_dir.join("config").join("ai-guard.json");
    if sibling.exists() {
        return sibling;
    }

    exe_dir
        .join("..")
        .join("config")
        .join("ai-guard.example.json")
}

fn resolve_path(base_dir: &Path, value: &Path) -> PathBuf {
    if value.is_absolute() {
        value.to_path_buf()
    } else {
        base_dir.join(value)
    }
}

fn resolve_command_path(base_dir: &Path, value: &Path) -> PathBuf {
    if value.is_absolute() || value.parent().is_none() {
        value.to_path_buf()
    } else {
        base_dir.join(value)
    }
}
