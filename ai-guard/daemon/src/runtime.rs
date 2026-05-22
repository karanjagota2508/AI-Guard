use std::future::Future;
use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;
use tracing::{error, info};
use tracing_appender::non_blocking::WorkerGuard;

use crate::config::AppConfig;
use crate::guard::GuardController;
use crate::http_api;
use crate::managed_pii;
use crate::pii::PiiClient;
use crate::processes::run_process_monitor;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub guard: Arc<GuardController>,
    pub pii: Arc<PiiClient>,
}

impl AppState {
    pub fn new(config: AppConfig) -> Result<Self> {
        let pii = PiiClient::new(&config)?;
        let guard = GuardController::new(
            config.browser_heartbeat_ttl(),
            config.desktop_activity_ttl(),
        );

        Ok(Self {
            config: Arc::new(config),
            guard: Arc::new(guard),
            pii: Arc::new(pii),
        })
    }

    pub fn extension_update_manifest(&self) -> String {
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
  <app appid="{extension_id}">
    <updatecheck codebase="{base_url}/extension.crx" version="{version}" />
  </app>
</gupdate>
"#,
            extension_id = self.config.package.extension_id,
            base_url = self
                .config
                .base_url()
                .unwrap_or_else(|_| "http://127.0.0.1:48555".to_string()),
            version = self.config.package.extension_version,
        )
    }
}

pub async fn run(config: AppConfig, shutdown: impl Future<Output = ()> + Send) -> Result<()> {
    let _logging_guard = init_logging(&config)?;
    let state = AppState::new(config)?;
    let listen_addr = state.config.listen_socket_addr()?;
    let cancel = CancellationToken::new();
    let router = http_api::router(state.clone());
    let listener = TcpListener::bind(listen_addr)
        .await
        .context("failed to bind local API listener")?;
    let http_cancel = cancel.clone();
    let managed_pii_config = state.config.managed_pii.clone().filter(|item| item.enabled);

    info!(listen = %listen_addr, "starting AI Guard Agent daemon");
    let mut server_handle = tokio::spawn(async move {
        axum::serve(listener, router)
            .with_graceful_shutdown(http_cancel.cancelled_owned())
            .await
            .context("HTTP server failed")
    });
    let monitor_handle = tokio::spawn(run_process_monitor(
        state.clone(),
        cancel.clone(),
        state.config.process_poll_interval(),
    ));
    let pii_cancel = cancel.clone();
    let pii_handle = tokio::spawn(async move {
        match managed_pii_config {
            Some(config) => managed_pii::run(config, pii_cancel).await,
            None => {
                pii_cancel.cancelled_owned().await;
                Ok(())
            }
        }
    });
    tokio::pin!(shutdown);

    tokio::select! {
        _ = &mut shutdown => {
            info!("shutdown requested");
            cancel.cancel();
        }
        result = &mut server_handle => {
            cancel.cancel();
            finish_task(result)?;
        }
        result = monitor_handle => {
            cancel.cancel();
            finish_task(result)?;
        }
        result = pii_handle => {
            cancel.cancel();
            finish_task(result)?;
        }
    }

    Ok(())
}

fn finish_task(result: std::result::Result<Result<()>, tokio::task::JoinError>) -> Result<()> {
    match result {
        Ok(inner) => inner,
        Err(error) => {
            error!(?error, "background task terminated unexpectedly");
            Err(anyhow!(error))
        }
    }
}

fn init_logging(config: &AppConfig) -> Result<WorkerGuard> {
    std::fs::create_dir_all(&config.logging.directory).with_context(|| {
        format!(
            "failed to create log directory {}",
            config.logging.directory.display()
        )
    })?;

    let file_appender = tracing_appender::rolling::daily(&config.logging.directory, "ai-guard.log");
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);
    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .with_writer(non_blocking)
        .with_ansi(false)
        .try_init()
        .ok();

    Ok(guard)
}
