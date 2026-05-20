use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum GuardMode {
    Idle,
    Active,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ScanAction {
    Allow,
    Block,
    Redact,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanRequest {
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanResponse {
    pub action: ScanAction,
    pub redacted_text: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivityRequest {
    pub page_url: String,
    pub tab_visible: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusResponse {
    pub mode: GuardMode,
    pub active_sources: Vec<String>,
    pub blocked_hosts: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PiiEngineRequest {
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PiiEngineResponse {
    pub contains_pii: bool,
    pub severity: Option<String>,
    pub action: Option<ScanAction>,
    pub redacted_text: Option<String>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UltibotDetectResponse {
    pub detected: Vec<UltibotDetection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UltibotDetection {
    pub entity_type: String,
    pub start: usize,
    pub end: usize,
    pub score: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UltibotAnonymizeRequest {
    pub text: String,
    pub detect_results: Vec<UltibotDetection>,
    pub global_operator: UltibotOperatorConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UltibotOperatorConfig {
    #[serde(rename = "type")]
    pub operator_type: String,
    pub new_value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UltibotAnonymizeResponse {
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeHostRequest {
    #[serde(rename = "type")]
    pub kind: String,
    pub extension_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeHelloResponse {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub token: String,
    pub base_url: String,
    pub extension_id: String,
    pub mode: GuardMode,
    pub blocked_hosts: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeStatusResponse {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub mode: GuardMode,
    pub active_sources: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeErrorResponse {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub message: String,
}
