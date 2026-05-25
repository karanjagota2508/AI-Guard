use axum::body::Body;
use axum::extract::State;
use axum::http::header::{AUTHORIZATION, CONTENT_TYPE, ORIGIN};
use axum::http::{HeaderMap, HeaderValue, Method, Response, StatusCode};
use axum::response::{IntoResponse, Json};
use axum::routing::{get, post};
use axum::{Router, response::Html};
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::warn;

use crate::contracts::{ActivityRequest, ScanRequest, ScanResponse, StatusResponse};
use crate::runtime::AppState;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/status", get(status))
        .route("/scan", post(scan))
        .route("/extension/activity", post(activity))
        .route("/__ulti_guard_test__/mock-claude", get(mock_claude))
        .route("/update.xml", get(update_manifest))
        .route("/extension.crx", get(extension_package))
        .layer(build_cors_layer(&state))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn healthz() -> impl IntoResponse {
    Json(serde_json::json!({ "ok": true }))
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

async fn mock_claude() -> Html<&'static str> {
    Html(
        r#"<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Ulti Guard Mock Claude</title>
    <style>
      :root {
        color-scheme: light;
        font-family: "Segoe UI", system-ui, sans-serif;
        background: #f7f3ea;
        color: #231f1b;
      }

      body {
        margin: 0;
        min-height: 100vh;
        background:
          radial-gradient(circle at top left, rgba(229, 106, 62, 0.12), transparent 28%),
          linear-gradient(180deg, #faf7ef 0%, #f1ece4 100%);
      }

      main {
        max-width: 920px;
        margin: 0 auto;
        padding: 56px 24px 80px;
      }

      .headline {
        font-size: clamp(2rem, 4vw, 3.25rem);
        line-height: 1.05;
        letter-spacing: -0.04em;
        margin: 0 0 12px;
      }

      .subhead {
        max-width: 640px;
        margin: 0 0 28px;
        color: #695f54;
        font-size: 1rem;
      }

      .composer {
        background: rgba(255, 255, 255, 0.92);
        border: 1px solid rgba(100, 88, 77, 0.16);
        border-radius: 28px;
        box-shadow: 0 28px 64px rgba(41, 29, 18, 0.08);
        overflow: hidden;
      }

      .editor {
        min-height: 180px;
        padding: 26px 28px 20px;
        outline: none;
        font-size: 1.05rem;
        line-height: 1.55;
        white-space: pre-wrap;
      }

      .editor:empty::before {
        content: attr(data-placeholder);
        color: #988d80;
      }

      .toolbar {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 14px 18px 18px 18px;
        border-top: 1px solid rgba(100, 88, 77, 0.08);
      }

      .pill {
        padding: 9px 14px;
        border-radius: 999px;
        background: #f5efe7;
        color: #54473a;
        font-size: 0.9rem;
      }

      button {
        border: 0;
        border-radius: 999px;
        background: #d7673a;
        color: #fff;
        padding: 12px 18px;
        font-size: 0.95rem;
        font-weight: 600;
        cursor: pointer;
      }

      .submitted {
        margin-top: 24px;
        padding: 18px 20px;
        border-radius: 18px;
        background: rgba(255, 255, 255, 0.78);
        border: 1px solid rgba(100, 88, 77, 0.12);
      }

      .submitted strong {
        display: block;
        margin-bottom: 8px;
      }

      .submitted-output {
        min-height: 22px;
        white-space: pre-wrap;
      }
    </style>
  </head>
  <body>
    <main>
      <h1 class="headline">Ulti Guard local web smoke test</h1>
      <p class="subhead">
        This page mimics a Claude-style composer so the browser extension can be tested
        end to end without depending on a live Claude login session.
      </p>

      <form class="composer" id="composer">
        <div
          id="editor"
          class="editor"
          data-testid="mock-editor"
          data-placeholder="Type a Claude prompt here"
          role="textbox"
          aria-label="Message Claude"
          contenteditable="true"
          spellcheck="false"
        ></div>
        <div class="toolbar">
          <div class="pill">Sonnet 4.6 mock surface</div>
          <button id="send" type="submit" aria-label="Send">
            Send
          </button>
        </div>
      </form>

      <section class="submitted">
        <strong>Last submitted prompt</strong>
        <div id="submitted-output" class="submitted-output"></div>
      </section>
    </main>

    <script>
      const composer = document.getElementById("composer");
      const editor = document.getElementById("editor");
      const submittedOutput = document.getElementById("submitted-output");

      composer.addEventListener("submit", (event) => {
        event.preventDefault();
        submittedOutput.textContent = editor.innerText || editor.textContent || "";
      });
    </script>
  </body>
</html>"#,
    )
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
            Html(format!(
                "<html><body><h1>Ulti Guard Agent</h1><p>{}</p></body></html>",
                self.message
            )),
        )
            .into_response()
    }
}
