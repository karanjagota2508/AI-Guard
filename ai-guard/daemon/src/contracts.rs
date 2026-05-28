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

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ScanDecisionKind {
    Clean,
    PiiDetected,
    ScanError,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanRequest {
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanResponse {
    pub action: ScanAction,
    pub decision_kind: ScanDecisionKind,
    pub redacted_text: String,
    pub reason: String,
    #[serde(default)]
    pub detected_entity: Option<String>,
}

impl ScanResponse {
    pub fn clean(redacted_text: String, reason: impl Into<String>) -> Self {
        Self {
            action: ScanAction::Allow,
            decision_kind: ScanDecisionKind::Clean,
            redacted_text,
            reason: reason.into(),
            detected_entity: None,
        }
    }

    pub fn pii_detected(
        action: ScanAction,
        redacted_text: String,
        reason: impl Into<String>,
        detected_entity: Option<String>,
    ) -> Self {
        Self {
            action,
            decision_kind: ScanDecisionKind::PiiDetected,
            redacted_text,
            reason: reason.into(),
            detected_entity,
        }
    }

    pub fn scan_error(
        action: ScanAction,
        redacted_text: String,
        reason: impl Into<String>,
    ) -> Self {
        Self {
            action,
            decision_kind: ScanDecisionKind::ScanError,
            redacted_text,
            reason: reason.into(),
            detected_entity: None,
        }
    }
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
    pub score_threshold: f64,
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

#[cfg(test)]
mod tests {
    use super::UltibotOperatorConfig;

    #[test]
    fn anonymize_operator_serializes_with_type_field_name() {
        let payload = serde_json::to_value(UltibotOperatorConfig {
            operator_type: "redact".to_string(),
            new_value: "<REDACTED>".to_string(),
        })
        .unwrap();

        assert_eq!(payload.get("type").and_then(|value| value.as_str()), Some("redact"));
        assert!(payload.get("operator_type").is_none());
    }
}
