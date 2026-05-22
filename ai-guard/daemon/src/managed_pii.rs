use std::fs::{self, OpenOptions};
use std::process::Stdio;

use anyhow::{Context, Result, anyhow, bail};
use reqwest::Client;
use tokio::process::{Child, Command};
use tokio::time::{Instant, sleep};
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};

use crate::config::ManagedPiiConfig;

const HEALTH_POLL_INTERVAL_MS: u64 = 1500;
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

pub async fn run(config: ManagedPiiConfig, cancel: CancellationToken) -> Result<()> {
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .context("failed to build managed PII health client")?;

    let mut child: Option<Child> = None;

    loop {
        if cancel.is_cancelled() {
            break;
        }

        if probe_health(&client, &config.health_url).await {
            tokio::select! {
                _ = cancel.cancelled() => break,
                _ = sleep(std::time::Duration::from_millis(HEALTH_POLL_INTERVAL_MS)) => {}
            }
            continue;
        }

        if let Some(running_child) = child.as_mut() {
            if let Some(status) = running_child
                .try_wait()
                .context("failed to inspect managed PII child status")?
            {
                warn!(?status, "managed PII process exited; will restart");
                child = None;
                tokio::select! {
                    _ = cancel.cancelled() => break,
                    _ = sleep(config.restart_delay()) => {}
                }
                continue;
            }
        }

        if child.is_none() {
            info!(
                executable = %config.executable.display(),
                working_directory = %config.working_directory.display(),
                "starting managed PII agent"
            );
            let mut spawned_child = spawn_child(&config)?;
            wait_for_startup(&client, &config, &mut spawned_child, &cancel).await?;
            info!("managed PII agent is healthy");
            child = Some(spawned_child);
        } else {
            warn!("managed PII agent is unhealthy but still running");
            tokio::select! {
                _ = cancel.cancelled() => break,
                _ = sleep(config.restart_delay()) => {}
            }
        }
    }

    if let Some(mut child) = child {
        info!("stopping managed PII agent");
        terminate_child(&mut child).await;
    }

    Ok(())
}

async fn wait_for_startup(
    client: &Client,
    config: &ManagedPiiConfig,
    child: &mut Child,
    cancel: &CancellationToken,
) -> Result<()> {
    let deadline = Instant::now() + config.startup_timeout();

    loop {
        if probe_health(client, &config.health_url).await {
            return Ok(());
        }

        if let Some(status) = child
            .try_wait()
            .context("failed to inspect managed PII child status during startup")?
        {
            bail!("managed PII process exited during startup with status {status}");
        }

        if Instant::now() >= deadline {
            terminate_child(child).await;
            bail!(
                "managed PII process did not become healthy within {:?}",
                config.startup_timeout()
            );
        }

        tokio::select! {
            _ = cancel.cancelled() => {
                terminate_child(child).await;
                bail!("managed PII startup cancelled");
            }
            _ = sleep(std::time::Duration::from_millis(HEALTH_POLL_INTERVAL_MS)) => {}
        }
    }
}

fn spawn_child(config: &ManagedPiiConfig) -> Result<Child> {
    fs::create_dir_all(&config.working_directory).with_context(|| {
        format!(
            "failed to create managed PII working directory {}",
            config.working_directory.display()
        )
    })?;

    let mut command = Command::new(&config.executable);
    command.args(&config.args);
    command.current_dir(&config.working_directory);
    command.envs(&config.env);
    command.stdin(Stdio::null());
    configure_stdio(&mut command, config)?;

    #[cfg(windows)]
    {
        command.creation_flags(CREATE_NO_WINDOW);
    }

    command.spawn().with_context(|| {
        format!(
            "failed to spawn managed PII executable {}",
            config.executable.display()
        )
    })
}

fn configure_stdio(command: &mut Command, config: &ManagedPiiConfig) -> Result<()> {
    if let Some(path) = &config.stdout_log_path {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).with_context(|| {
                format!(
                    "failed to create managed PII stdout log directory {}",
                    parent.display()
                )
            })?;
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .with_context(|| format!("failed to open managed PII stdout log {}", path.display()))?;
        command.stdout(Stdio::from(file));
    } else {
        command.stdout(Stdio::null());
    }

    if let Some(path) = &config.stderr_log_path {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).with_context(|| {
                format!(
                    "failed to create managed PII stderr log directory {}",
                    parent.display()
                )
            })?;
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .with_context(|| format!("failed to open managed PII stderr log {}", path.display()))?;
        command.stderr(Stdio::from(file));
    } else {
        command.stderr(Stdio::null());
    }

    Ok(())
}

async fn probe_health(client: &Client, health_url: &str) -> bool {
    match client.get(health_url).send().await {
        Ok(response) => response.status().is_success(),
        Err(_) => false,
    }
}

async fn terminate_child(child: &mut Child) {
    match child.kill().await {
        Ok(_) => {
            let _ = child.wait().await;
        }
        Err(error) => {
            error!(error = %anyhow!(error), "failed to stop managed PII child");
        }
    }
}
