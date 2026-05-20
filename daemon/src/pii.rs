use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use regex::Regex;
use reqwest::Client;
use serde_json::Value;

use crate::config::AppConfig;
use crate::contracts::{
    PiiEngineRequest, PiiEngineResponse, ScanAction, ScanResponse, UltibotAnonymizeRequest,
    UltibotAnonymizeResponse, UltibotDetectResponse, UltibotDetection, UltibotOperatorConfig,
};

static EMAIL_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b").unwrap());
static SSN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\b\d{3}-\d{2}-\d{4}\b").unwrap());
static PHONE_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\b(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b").unwrap()
});
static CARD_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\b(?:\d[ -]*?){13,16}\b").unwrap());
static IPV4_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\b(?:\d{1,3}\.){3}\d{1,3}\b").unwrap());
static AWS_KEY_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\bAKIA[0-9A-Z]{16}\b").unwrap());

pub struct PiiClient {
    client: Client,
    engine_url: String,
    anonymize_url: Option<String>,
    fail_closed: bool,
}

impl PiiClient {
    pub fn new(config: &AppConfig) -> Result<Self> {
        let client = Client::builder()
            .timeout(config.scan_timeout())
            .build()
            .context("failed to build HTTP client for PII engine")?;

        Ok(Self {
            client,
            engine_url: config.pii_engine_url.clone(),
            anonymize_url: config.pii_anonymize_url.clone(),
            fail_closed: config.fail_closed,
        })
    }

    pub async fn scan(&self, text: &str) -> ScanResponse {
        match self.scan_inner(text).await {
            Ok(response) => response,
            Err(error) => {
                let message = format!("PII scan failed: {error}");
                if self.fail_closed {
                    ScanResponse {
                        action: ScanAction::Block,
                        redacted_text: String::new(),
                        reason: message,
                    }
                } else {
                    ScanResponse {
                        action: ScanAction::Allow,
                        redacted_text: text.to_string(),
                        reason: message,
                    }
                }
            }
        }
    }

    async fn scan_inner(&self, text: &str) -> Result<ScanResponse> {
        let response = self
            .client
            .post(&self.engine_url)
            .json(&PiiEngineRequest {
                text: text.to_string(),
            })
            .send()
            .await
            .with_context(|| format!("failed to reach PII engine {}", self.engine_url))?;

        let response = response
            .error_for_status()
            .context("PII engine returned an error status")?;

        let payload: Value = response
            .json()
            .await
            .context("PII engine returned invalid JSON")?;

        if payload.get("detected").is_some() {
            let detect_payload: UltibotDetectResponse = serde_json::from_value(payload)
                .context("PII engine returned invalid detect payload")?;
            return self
                .translate_detect_list_response(text, detect_payload.detected)
                .await;
        }

        let payload: PiiEngineResponse =
            serde_json::from_value(payload).context("PII engine returned invalid JSON shape")?;

        let action = payload.action.unwrap_or({
            if payload.contains_pii {
                ScanAction::Block
            } else {
                ScanAction::Allow
            }
        });

        let severity = payload.severity.unwrap_or_else(|| "unknown".to_string());
        let reason = payload.reason.unwrap_or_else(|| match action {
            ScanAction::Allow => "PII engine allowed prompt".to_string(),
            ScanAction::Block => format!("Prompt blocked by PII engine (severity: {severity})"),
            ScanAction::Redact => format!("Prompt redacted by PII engine (severity: {severity})"),
        });

        let redacted_text = match action {
            ScanAction::Allow => text.to_string(),
            ScanAction::Block => String::new(),
            ScanAction::Redact => payload
                .redacted_text
                .filter(|item| !item.is_empty())
                .unwrap_or_else(|| local_redact(text)),
        };

        Ok(ScanResponse {
            action,
            redacted_text,
            reason,
        })
    }

    async fn translate_detect_list_response(
        &self,
        text: &str,
        detected: Vec<UltibotDetection>,
    ) -> Result<ScanResponse> {
        if detected.is_empty() {
            return Ok(ScanResponse {
                action: ScanAction::Allow,
                redacted_text: text.to_string(),
                reason: "PII engine found no sensitive entities".to_string(),
            });
        }

        let severity = classify_severity(&detected);
        let action = match severity {
            "critical" | "high" => ScanAction::Block,
            _ => ScanAction::Redact,
        };

        let redacted_text = match action {
            ScanAction::Allow => text.to_string(),
            ScanAction::Block => String::new(),
            ScanAction::Redact => self
                .redact_detected_entities(text, &detected)
                .await
                .unwrap_or_else(|_| local_redact(text)),
        };

        Ok(ScanResponse {
            action,
            redacted_text,
            reason: format!(
                "PII detected by local engine: {} entities, severity {}",
                detected.len(),
                severity
            ),
        })
    }

    async fn redact_detected_entities(
        &self,
        text: &str,
        detected: &[UltibotDetection],
    ) -> Result<String> {
        let Some(anonymize_url) = &self.anonymize_url else {
            return Ok(local_redact(text));
        };

        let response = self
            .client
            .post(anonymize_url)
            .json(&UltibotAnonymizeRequest {
                text: text.to_string(),
                detect_results: detected.to_vec(),
                global_operator: UltibotOperatorConfig {
                    operator_type: "replace".to_string(),
                    new_value: "<REDACTED>".to_string(),
                },
            })
            .send()
            .await
            .with_context(|| format!("failed to reach PII anonymize endpoint {anonymize_url}"))?;

        let response = response
            .error_for_status()
            .context("PII anonymize endpoint returned an error status")?;

        let payload: UltibotAnonymizeResponse = response
            .json()
            .await
            .context("PII anonymize endpoint returned invalid JSON")?;
        Ok(payload.text)
    }
}

fn classify_severity(detected: &[UltibotDetection]) -> &'static str {
    let mut severity = "low";

    for item in detected {
        match item.entity_type.to_ascii_uppercase().as_str() {
            "CREDIT_CARD"
            | "CRYPTO"
            | "IBAN_CODE"
            | "US_BANK_NUMBER"
            | "US_ITIN"
            | "US_PASSPORT"
            | "PASSWORD" => return "critical",
            "EMAIL_ADDRESS"
            | "PHONE_NUMBER"
            | "US_SSN"
            | "IP_ADDRESS"
            | "PERSON"
            | "LOCATION"
            | "MEDICAL_LICENSE"
            | "DRIVER_LICENSE" => severity = "medium",
            _ => {}
        }
    }

    severity
}

fn local_redact(text: &str) -> String {
    let mut output = text.to_string();
    output = EMAIL_RE.replace_all(&output, "[REDACTED_EMAIL]").into_owned();
    output = SSN_RE.replace_all(&output, "[REDACTED_SSN]").into_owned();
    output = PHONE_RE.replace_all(&output, "[REDACTED_PHONE]").into_owned();
    output = CARD_RE.replace_all(&output, "[REDACTED_CARD]").into_owned();
    output = IPV4_RE.replace_all(&output, "[REDACTED_IP]").into_owned();
    output = AWS_KEY_RE.replace_all(&output, "[REDACTED_AWS_KEY]").into_owned();
    output
}
