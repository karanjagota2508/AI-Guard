# Ulti Guard

Ulti Guard is a Windows-first single-install security product that enforces protected Claude usage with local PII scanning and competing-LLM isolation.

One installation deploys:

- A Rust daemon running as the local control plane on `127.0.0.1:48555`
- A managed local PII service backed by the bundled `PII_agent`
- A Chrome/Edge Manifest V3 extension that injects only on `https://claude.ai/*` and `https://claude.com/*`
- Claude Desktop protection for standard installs plus a Store/MSIX fallback path
- A compiled WPF admin console for provider and policy management
- A compiled self-contained setup EXE for install, repair, and uninstall

## Repository Layout

```text
ai-guard/
  daemon/      Rust daemon and Windows service
  extension/   Manifest V3 extension
  shared/      Shared contracts
  installer/   Setup app, admin console, packaging scripts, install scripts
  config/      Example configuration
  tests/       Browser smoke fixture and automation
```

## Runtime Behavior

- Claude web activity is tracked by the extension heartbeat.
- Claude Desktop activity is tracked by the daemon process monitor and enforced through the desktop hook or UIAutomation fallback.
- When Claude is active, guard mode switches to `active`.
- In active mode the daemon:
  - scans Claude prompts through the local PII engine
  - returns `allow`, `redact`, or `block` plus a `decision_kind` that distinguishes clean scans, real PII detections, and scan errors
  - terminates configured competing desktop LLM processes
  - provides the browser blocklist consumed by the extension and browser policy
- The PII service is local-only and the daemon is fail-closed by default if scanning becomes unavailable.

## Local API

The daemon binds to `127.0.0.1:48555` and exposes:

- `GET /healthz`
- `GET /readyz`
- `POST /scan`
- `GET /status`
- `POST /extension/activity`
- `GET /update.xml`
- `GET /extension.crx`

All extension-facing HTTP calls require:

- `Authorization: Bearer <token>`
- `Origin: chrome-extension://kgfkgellcbbmadimiahbfndmfbhfobko`

## Build

Prerequisites:

- Rust toolchain
- PowerShell 5.1+ or PowerShell 7+
- .NET 8 SDK with Windows Desktop workload support
- Microsoft Edge or Google Chrome available locally for CRX packaging
- Python available locally for initial PII provisioning steps

Build the daemon:

```powershell
cd .\daemon
cargo build --release
```

Package the extension:

```powershell
.\installer\scripts\package-extension.ps1
```

Publish the admin console:

```powershell
.\installer\scripts\publish-admin-console.ps1
```

Build the self-contained setup EXE:

```powershell
.\installer\scripts\build-setup-exe.ps1
```

Offline-style setup output with bundled wheelhouse:

```powershell
.\installer\scripts\build-setup-exe.ps1 -IncludeWheelhouse -OutputPath .\artifacts\AI-Guard-Setup-offline.exe
```

## Install

For a machine-wide managed deployment:

```powershell
.\installer\install.ps1 -PiiPort 8000
```

For the stronger enterprise policy path:

```powershell
.\installer\install-enterprise.ps1 -PiiPort 8000
```

The default machine install root is:

```text
C:\Program Files\AI Guard Agent
```

The installer:

- copies the daemon, extension, admin console, Claude Desktop assets, and branding
- provisions a private Python runtime and the bundled PII backend
- writes `config\ai-guard.json`
- registers the daemon as the `AIGuardAgent` Windows service
- registers Chrome and Edge native messaging manifests
- applies managed Chromium extension policy and optional URL blocklist policy
- patches supported Claude Desktop installs and prepares the Store/MSIX fallback runtime
- creates the Start Menu entry `Ulti Guard Admin Console`

The setup EXE (`installer/dist/AI-Guard-Setup.exe`) wraps the same install/uninstall engine in a WPF desktop application and does not require end users to run PowerShell manually.

## Admin Console

The admin console is a compiled WPF application installed under:

```text
C:\Program Files\AI Guard Agent\admin-console\AI-Guard-Admin-Console.exe
```

It:

- requires administrator elevation
- requires a password on every launch
- stores password material in a DPAPI-protected sidecar file, not inside `ai-guard.json`
- lets administrators add or remove blocked browser hosts
- lets administrators add or remove blocked process names
- includes presets for ChatGPT, Gemini, Perplexity, Cursor, Ollama, LM Studio, OpenWebUI, AnythingLLM, and Jan
- refreshes browser policy and restarts the runtime after saving

## Enterprise Notes

- Force-install and policy enforcement are intended for managed Windows/Chromium environments.
- Ulti Guard keeps the fixed extension ID and native host name for compatibility.
- Chrome and Edge private browsing can remain enabled while blocked-provider host denial is still enforced through browser policy.
- Local administrators can still tamper with services, files, and registry policy; the product is designed to harden standard-user enterprise deployments.

## Tests

- `cargo test` in `daemon/` covers PII decision helpers, guard-state transitions, and process-name matching.
- `python -m unittest discover -s tests` in `PII_agent/backend/` covers detection filters and API endpoint behavior.
- `tests/browser/smoke-test.mjs` uses a test-only local fixture page and a patched temporary extension copy. The production daemon no longer exposes a browser mock route.

## Operational Notes

- Re-run `installer\install.ps1` after a Claude Desktop update so the new desktop bundle is patched or re-synced.
- Re-run the installer after Microsoft Store Claude updates so the mirrored guarded runtime stays current.
- Uninstall stops and removes the service, clears Ulti Guard browser-policy entries, restores desktop patches where applicable, and removes the installed files unless `-KeepFiles` is used.
