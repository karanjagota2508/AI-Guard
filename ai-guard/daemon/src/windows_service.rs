#[cfg(windows)]
mod service_impl {
    use std::ffi::OsString;
    use std::path::PathBuf;
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    use std::time::Duration;

    use anyhow::Result;
    use once_cell::sync::OnceCell;
    use tokio::time;
    use windows_service::define_windows_service;
    use windows_service::service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    };
    use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
    use windows_service::service_dispatcher;

    use crate::config::AppConfig;
    use crate::runtime;

    const SERVICE_NAME: &str = "AIGuardAgent";
    static SERVICE_CONFIG_PATH: OnceCell<PathBuf> = OnceCell::new();

    define_windows_service!(ffi_service_main, service_main);

    pub fn dispatch(config_path: PathBuf) -> Result<()> {
        let _ = SERVICE_CONFIG_PATH.set(config_path);
        service_dispatcher::start(SERVICE_NAME, ffi_service_main)?;
        Ok(())
    }

    fn service_main(_arguments: Vec<OsString>) {
        if let Err(error) = run_service() {
            eprintln!("service failed: {error}");
        }
    }

    fn run_service() -> Result<()> {
        let config_path = SERVICE_CONFIG_PATH
            .get()
            .cloned()
            .unwrap_or_else(crate::config::default_config_path);
        let config = AppConfig::load(&config_path)?;
        let stop_requested = Arc::new(AtomicBool::new(false));
        let flag = stop_requested.clone();

        let status_handle = service_control_handler::register(
            SERVICE_NAME,
            move |control_event| match control_event {
                ServiceControl::Stop | ServiceControl::Shutdown => {
                    flag.store(true, Ordering::SeqCst);
                    ServiceControlHandlerResult::NoError
                }
                _ => ServiceControlHandlerResult::NotImplemented,
            },
        )?;

        status_handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Running,
            controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::from_secs(10),
            process_id: None,
        })?;

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()?;

        let runtime_result = runtime.block_on(async move {
            let shutdown = async {
                while !stop_requested.load(Ordering::SeqCst) {
                    time::sleep(Duration::from_secs(1)).await;
                }
            };

            runtime::run(config, shutdown).await
        });

        let exit_code = if runtime_result.is_ok() {
            ServiceExitCode::Win32(0)
        } else {
            ServiceExitCode::ServiceSpecific(1)
        };

        status_handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Stopped,
            controls_accepted: ServiceControlAccept::empty(),
            exit_code: exit_code,
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })?;

        runtime_result
    }
}

#[cfg(windows)]
pub use service_impl::dispatch;

#[cfg(not(windows))]
pub fn dispatch(_config: crate::config::AppConfig) -> anyhow::Result<()> {
    anyhow::bail!("windows services are only supported on Windows")
}
