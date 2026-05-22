mod config;
mod contracts;
mod guard;
mod http_api;
mod managed_pii;
mod native_host;
mod pii;
mod processes;
mod runtime;
mod windows_service;

use std::env;
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

use crate::config::{AppConfig, default_config_path};

#[derive(Debug, Parser)]
#[command(name = "ai-guard-daemon")]
#[command(about = "Ulti Guard Agent local enforcement daemon")]
struct Cli {
    #[arg(long, default_value_os_t = default_config_path())]
    config: PathBuf,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    Run,
    Service,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    if let Some(origin) = args
        .get(1)
        .filter(|value| value.starts_with("chrome-extension://"))
    {
        let config = AppConfig::load(&default_config_path())?;
        return native_host::run(Some(origin), config).await;
    }

    let cli = Cli::parse();
    let config = AppConfig::load(&cli.config)
        .with_context(|| format!("failed to load config {}", cli.config.display()))?;

    match cli.command.unwrap_or(Command::Run) {
        Command::Run => {
            runtime::run(config, async {
                let _ = tokio::signal::ctrl_c().await;
            })
            .await
        }
        Command::Service => windows_service::dispatch(cli.config),
    }
}
