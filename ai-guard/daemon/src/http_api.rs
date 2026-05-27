use axum::body::Body;
use axum::extract::State;
use axum::http::header::{AUTHORIZATION, CONTENT_TYPE, ORIGIN};
use axum::http::{HeaderMap, HeaderValue, Method, Response, StatusCode};
use axum::response::{IntoResponse, Json};
use axum::routing::{get, post};
use axum::Router;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::warn;

use crate::contracts::{ActivityRequest, ScanRequest, ScanResponse, StatusResponse};
use crate::runtime::AppState;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/status", get(status))
        .route("/scan", post(scan))
        .route("/extension/activity", post(activity))
        .route("/update.xml", get(update_manifest))
        .route("/extension.crx", get(extension_package))
        .layer(build_cors_layer(&state))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn healthz() -> impl IntoResponse {
    Json(serde_json::json!({ "ok": true }))
}

async fn readyz(State(state): State<AppState>) -> impl IntoResponse {
    if state.pii_ready() {
        return (StatusCode::OK, Json(serde_json::json!({ "ok": true })));
    }

    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(serde_json::json!({
            "ok": false,
            "reason": "PII scanning is still starting up."
        })),
    )
}

async fn status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    authorize(&state, &headers)?;
    let snapshot = state.guard.snapshot();
    Ok(Json(StatusResponse {
        mode: snapshot.mode,
        active_sources: snapshot.active_sources,
        blocked_hosts: state.config.blocking.browser_hosts.clone(),
    }))
}

async fn scan(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ScanRequest>,
) -> Result<impl IntoResponse, ApiError> {
    authorize(&state, &headers)?;
    if state.pii_readiness.requires_ready() && !state.pii_ready() {
        return Ok(Json(state.pii.scan_unavailable(
            &payload.text,
            "PII scanning is still starting up. Submission is blocked until the service is ready.",
        )));
    }
    let response: ScanResponse = state.pii.scan(&payload.text).await;
    Ok(Json(response))
}

async fn activity(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ActivityRequest>,
) -> Result<impl IntoResponse, ApiError> {
    authorize(&state, &headers)?;
    let snapshot = state.guard.note_browser_activity(payload.tab_visible);
    Ok(Json(StatusResponse {
        mode: snapshot.mode,
        active_sources: snapshot.active_sources,
        blocked_hosts: state.config.blocking.browser_hosts.clone(),
    }))
}

async fn update_manifest(State(state): State<AppState>) -> impl IntoResponse {
    let payload = state.extension_update_manifest();
    (
        [(CONTENT_TYPE, HeaderValue::from_static("application/xml"))],
        payload,
    )
}

async fn extension_package(State(state): State<AppState>) -> Result<Response<Body>, ApiError> {
    let bytes = tokio::fs::read(&state.config.package.extension_crx_path)
        .await
        .map_err(ApiError::internal)?;

    let response = Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "application/x-chrome-extension")
        .body(Body::from(bytes))
        .map_err(ApiError::internal)?;

    Ok(response)
}

fn authorize(state: &AppState, headers: &HeaderMap) -> Result<(), ApiError> {
    let auth_header = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| ApiError::unauthorized("missing bearer token"))?;

    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or_else(|| ApiError::unauthorized("invalid bearer token"))?;

    if token != state.config.auth_token {
        return Err(ApiError::unauthorized("token mismatch"));
    }

    let origin = headers
        .get(ORIGIN)
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| ApiError::forbidden("missing extension origin"))?;

    if !state.config.is_allowed_origin(origin) {
        warn!(origin, "rejected unauthorized extension origin");
        return Err(ApiError::forbidden("origin not allowed"));
    }

    Ok(())
}

fn build_cors_layer(state: &AppState) -> CorsLayer {
    let allowed_origins: Vec<HeaderValue> = state
        .config
        .allowed_origins()
        .iter()
        .filter_map(|origin| HeaderValue::from_str(origin).ok())
        .collect();

    CorsLayer::new()
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers([AUTHORIZATION, CONTENT_TYPE, ORIGIN])
        .allow_origin(allowed_origins)
        .expose_headers(Any)
}

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn unauthorized(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: message.into(),
        }
    }

    fn forbidden(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            message: message.into(),
        }
    }

    fn internal(error: impl std::fmt::Display) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: error.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response<Body> {
        (
            self.status,
            Json(serde_json::json!({
                "error": true,
                "message": self.message
            })),
        )
            .into_response()
    }
}
