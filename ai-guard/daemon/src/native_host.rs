use std::io::{self, Read, Write};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use reqwest::header::{AUTHORIZATION, ORIGIN};
use serde::Serialize;

use crate::config::AppConfig;
use crate::contracts::{
    GuardMode, NativeErrorResponse, NativeHelloResponse, NativeHostRequest, NativeStatusResponse,
    StatusResponse,
};

const NATIVE_HOST_MESSAGE_TIMEOUT: Duration = Duration::from_secs(2);
const NATIVE_HOST_STATUS_TIMEOUT: Duration = Duration::from_millis(750);

pub async fn run(origin: Option<&str>, config: AppConfig) -> Result<()> {
    let origin = origin.ok_or_else(|| anyhow!("native host origin missing"))?;
    let extension_id = origin
        .strip_prefix("chrome-extension://")
        .map(|item| item.trim_end_matches('/'))
        .ok_or_else(|| anyhow!("unexpected native host origin {origin}"))?;

    if !config.is_allowed_extension_id(extension_id) {
        write_message(&NativeErrorResponse {
            kind: "error",
            message: format!("extension {extension_id} is not allowed"),
        })?;
        return Ok(());
    }

    let request: NativeHostRequest = match read_message_with_timeout() {
        Ok(request) => request,
        Err(error) => {
            write_message(&NativeErrorResponse {
                kind: "error",
                message: format!("native bootstrap request timed out: {error}"),
            })?;
            return Ok(());
        }
    };
    let live_status = fetch_live_status(&config, origin).await.ok();
    let mode = live_status
        .as_ref()
        .map(|status| status.mode)
        .unwrap_or(GuardMode::Idle);
    let active_sources = live_status
        .as_ref()
        .map(|status| status.active_sources.clone())
        .unwrap_or_default();

    match request.kind.as_str() {
        "hello" => write_message(&NativeHelloResponse {
            kind: "hello",
            token: config.auth_token.clone(),
            base_url: config.base_url()?,
            extension_id: extension_id.to_string(),
            mode,
            blocked_hosts: config.blocking.browser_hosts.clone(),
        })?,
        "status" => write_message(&NativeStatusResponse {
            kind: "status",
            mode,
            active_sources,
        })?,
        "ping" => write_message(&serde_json::json!({ "type": "pong" }))?,
        _ => write_message(&NativeErrorResponse {
            kind: "error",
            message: format!("unsupported message type {}", request.kind),
        })?,
    }

    Ok(())
}

async fn fetch_live_status(config: &AppConfig, origin: &str) -> Result<StatusResponse> {
    let client = reqwest::Client::builder()
        .use_rustls_tls()
        .connect_timeout(NATIVE_HOST_STATUS_TIMEOUT)
        .timeout(NATIVE_HOST_STATUS_TIMEOUT)
        .build()
        .context("failed to create native host HTTP client")?;
    let response = client
        .get(format!("{}/status", config.base_url()?))
        .header(AUTHORIZATION, format!("Bearer {}", config.auth_token))
        .header(ORIGIN, origin)
        .send()
        .await
        .context("failed to query live daemon status")?
        .error_for_status()
        .context("live daemon status request returned error")?;
    response
        .json::<StatusResponse>()
        .await
        .context("failed to decode live daemon status")
}

fn read_message_with_timeout<T>() -> Result<T>
where
    T: serde::de::DeserializeOwned + Send + 'static,
{
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let _ = sender.send(read_message());
    });

    receiver
        .recv_timeout(NATIVE_HOST_MESSAGE_TIMEOUT)
        .map_err(|_| anyhow!("timed out waiting for browser request"))?
}

fn read_message<T>() -> Result<T>
where
    T: serde::de::DeserializeOwned,
{
    let mut length_buf = [0u8; 4];
    io::stdin().read_exact(&mut length_buf)?;
    let message_len = u32::from_le_bytes(length_buf) as usize;
    let mut payload = vec![0u8; message_len];
    io::stdin().read_exact(&mut payload)?;
    let message = serde_json::from_slice(&payload)?;
    Ok(message)
}

fn write_message<T>(value: &T) -> Result<()>
where
    T: Serialize,
{
    let payload = serde_json::to_vec(value)?;
    let length = payload.len() as u32;
    io::stdout().write_all(&length.to_le_bytes())?;
    io::stdout().write_all(&payload)?;
    io::stdout().flush()?;
    Ok(())
}
