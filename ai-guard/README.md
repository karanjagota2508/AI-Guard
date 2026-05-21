# AI Guard Agent

AI Guard Agent is a Windows-first single-install security product that enforces protected Claude usage. One installation deploys:

- A Rust background daemon with a localhost API bridge
- A managed local PII engine based on the bundled `PII_agent` FastAPI service
- A Chrome/Edge Manifest V3 extension that only injects on `https://claude.ai/*`
- A Claude Desktop preload hook that applies the same `/scan` enforcement in the Electron app
- Native-messaging bootstrap and enterprise browser policy registration for force-install

## Repository layout

```text
ai-guard/
  daemon/      Rust daemon and Windows service
  extension/   Manifest V3 extension for Claude interception
  shared/      Shared API contracts
  installer/   Windows packaging and install scripts
  config/      Example configuration
```

## Core behavior

- Claude web activity is tracked by extension heartbeats.
- Claude desktop activity is tracked by foreground process inspection.
- Claude Desktop prompt interception is enforced by patching its Electron preload bundle and relaying scans to the local daemon.
- When Claude becomes active, guard mode switches to `active`.
- In active mode, the daemon kills configured desktop LLM processes and the extension blocks configured LLM domains.
- Claude prompts are scanned on paste, debounced input, and submit only.
- Submit-time scan decisions return `allow`, `redact`, or `block`.
- The daemon can supervise the bundled PII backend and restart it if it stops responding.
- If Claude Desktop is installed from the Microsoft Store, AI Guard mirrors the package into a writable local runtime and patches that guarded copy instead of the read-only `WindowsApps` bundle.
- For Microsoft Store Claude builds, AI Guard launches the signed package with Chromium accessibility enabled and applies prompt redaction through an external UIAutomation helper.

## What You Can Do With It

- Enforce Claude-only sessions on a Windows workstation.
- Block or kill configured competing LLM apps while Claude is active.
- Intercept Claude prompts before submit and either allow, redact, or block them.
- Apply the same PII detection and redaction flow inside Claude Desktop, not just `claude.ai`.
- Launch a guarded Claude Desktop runtime even when the official desktop app is distributed as a read-only Store/MSIX package.
- Enforce prompt scanning in Store/MSIX Claude Desktop builds without modifying the protected `WindowsApps` package in place.
- Run a fully local PII pipeline with Presidio-based detection and anonymization.
- Force-install the browser extension for Chrome and Edge through policy.
- Support Claude web protection in Chrome Incognito and Edge InPrivate windows when the browser allows the extension there.
- Deploy one install under `C:\Program Files\AI Guard Agent` instead of managing separate pieces manually.
- Let administrators manage blocked providers through a local desktop admin console instead of editing JSON manually.

## Local API

The daemon binds to `127.0.0.1:48555` and exposes:

- `POST /scan`
- `GET /status`
- `POST /extension/activity`
- `GET /update.xml`
- `GET /extension.crx`

The extension never talks to the daemon directly until it bootstraps an auth token through native messaging. HTTP calls require:

- `Authorization: Bearer <token>`
- `Origin: chrome-extension://kgfkgellcbbmadimiahbfndmfbhfobko`

## Build

Prerequisites:

- Rust toolchain
- Windows PowerShell 5.1+ or PowerShell 7+
- Microsoft Edge or Google Chrome installed locally for CRX packaging
- Python available locally for the bundled PII backend provisioning step

Build the daemon:

```powershell
cd .\daemon
cargo build --release
```

Package the extension:

```powershell
.\installer\scripts\package-extension.ps1
```

## Install

Run from an elevated PowerShell session:

```powershell
.\installer\install.ps1 -PiiPort 8000
```

For a stronger managed-browser rollout, use:

```powershell
.\installer\install.ps1 `
  -PiiPort 8000 `
  -ExtensionUpdateUrl "https://your-company-host/ai-guard/update.xml" `
  -BlockOtherExtensions `
  -AllowedExtensionIds @("your_other_corporate_extension_id") `
  -RequirePrivateBrowsingGuard `
  -DisallowExtensionDeveloperMode `
  -DisableBrowserDeveloperTools
```

For offline or repeated installs on other PCs:

1. Run the installer once on a build machine without `-SkipBuild`.
2. This will populate `installer/dist/ai-guard-daemon.exe` and `installer/dist/ai-guard-extension.crx`.
3. Copy the full `ai-guard/` and `PII_agent/` folders to the target PC.
4. On the target PC, run the installer with `-SkipBuild`.

Do not leave placeholder values like `https://your-company-host/...` in the command. Omit `-ExtensionUpdateUrl` to use the local daemon update endpoint, or replace it with a real reachable HTTPS URL.

If you want a no-command setup for end users or IT operators, build the single-file setup executable:

```powershell
.\installer\scripts\build-setup-exe.ps1
```

That produces:

- `installer/dist/AI-Guard-Setup.exe`

The setup executable:

- requests administrator approval automatically
- shows a simple Install / Repair / Uninstall GUI
- extracts the bundled AI Guard + PII payload to a temporary folder
- bundles a private Python runtime for the managed PII backend
- can bundle a local wheelhouse so the PII backend provisions without preinstalled Python or manual pip commands
- runs `install-enterprise.ps1 -SkipBuild` internally
- does not require the operator to type any PowerShell commands

The installer:

- Builds the daemon release binary
- Packs the MV3 extension as a CRX with a fixed extension ID
- Copies and provisions the bundled `PII_agent/backend` into a private virtual environment
- Writes `C:\Program Files\AI Guard Agent\config\ai-guard.json`
- Copies the Claude Desktop hook and patches detected `%LOCALAPPDATA%\AnthropicClaude\app-*\resources\app.asar` bundles
- Detects Microsoft Store Claude installs under `C:\Program Files\WindowsApps\Claude_*`, mirrors them into a writable local runtime, and generates a guarded launcher script
- Generates a Claude Desktop launcher that starts the Store build with `--force-renderer-accessibility` and runs the AI Guard UIAutomation helper
- Installs an elevated `launch-admin-console.ps1` entry point for provider management
- Registers the daemon as the `AIGuardAgent` Windows service
- Registers Chrome and Edge native messaging manifests
- Applies Chrome and Edge managed extension policies without overwriting unrelated org policy entries
- Registers both `ExtensionSettings` and `ExtensionInstallForcelist` entries for the fixed extension ID
- Can optionally register Chrome `MandatoryExtensionsForIncognitoNavigation` and Edge `MandatoryExtensionsForInPrivateNavigation` so users must allow AI Guard before they can browse privately
- Can optionally block other extensions, disable extensions-page developer mode, and disable browser developer tools

Restart Chrome and Edge after installation so policy refresh and extension installation happen immediately.
Restart Claude Desktop after installation if it was open during setup. The installer backs up each original `app.asar` as `app.asar.ai-guard.bak` and the uninstaller restores it.
If Claude Desktop came from the Microsoft Store, launch it through `launch-claude-desktop.ps1` in the install root so AI Guard can enable the accessibility-based desktop guard path.

If you run the installer without elevation, the daemon installs for the current user only. In that mode the browser extension is copied locally, but Chromium will not be force-managed. Load `extension/` unpacked for development or use the elevated install path for managed rollout.

## Development

Run the daemon locally with the example config:

```powershell
cd .\daemon
cargo run -- --config ..\config\ai-guard.example.json run
```

For extension debugging, load `extension/` as an unpacked extension. The fixed manifest key keeps the extension ID aligned with the native-messaging allowlist.

## Enterprise rollout

Use this model when users must not disable or uninstall the extension:

1. Install AI Guard Agent from an elevated PowerShell session so the daemon runs as a Windows service under `C:\Program Files\AI Guard Agent`.
2. Apply browser policy at machine scope, not per-user scope.
3. Force-install the extension with `installation_mode = force_installed`.
4. Keep the extension ID fixed so native messaging allowlists remain valid.
5. Remove local admin rights from end users. A local administrator can always tamper with browser policy, services, or files.

### Admin console

Machine installs now include an administrator-only Windows desktop console at:

- `C:\Program Files\AI Guard Agent\launch-admin-console.ps1`
- Start Menu: `AI Guard Agent Admin Console`

The console lets an administrator:

- Add or remove blocked website hosts
- Add or remove blocked desktop process names
- Apply preset providers such as ChatGPT, Gemini, Perplexity, Grok, Cursor, Ollama, and LM Studio
- Save the updated config and restart the AI Guard service
- Set an admin-console password on first launch and require that password on every future launch

Standard users cannot use this console without administrator approval. For enterprise rollout, keep the install under `C:\Program Files\AI Guard Agent` and do not grant end users local admin rights.

Recommended hardening switches:

- `-BlockOtherExtensions` blocks non-approved extensions by default.
- `-AllowedExtensionIds` keeps required corporate extensions allowed.
- `-DisallowExtensionDeveloperMode` prevents turning on extensions-page developer mode.
- `-DisableBrowserDeveloperTools` disables built-in browser developer tools entirely.
- `-MinimumExtensionVersion` enforces a minimum AI Guard extension version.
- `-ExtensionUpdateUrl` lets you point the force-install policy at a central HTTPS update manifest instead of `127.0.0.1`.
- `-RequirePrivateBrowsingGuard` registers AI Guard as mandatory for Chrome Incognito and Edge InPrivate navigation.

Operational guidance:

- For company rollout, prefer a central HTTPS-hosted `update.xml` and `.crx`, or publish the same fixed-ID package to the Chrome Web Store and Edge Add-ons.
- The installer now merges AI Guard policy into existing `ExtensionSettings` rather than overwriting the whole organization policy blob.
- Uninstall removes only AI Guard's managed-extension entries and preserves unrelated extension policies.
- The extension manifest is configured with `"incognito": "split"` so `blocked.html` and content-script enforcement can operate in private browsing contexts when the browser allows the extension there.
- Chrome still doesn't let admins silently flip `Allow in Incognito`; managed rollout can only force the user prompt before Incognito browsing, or disable Incognito entirely.
- Edge similarly does not let admins directly enable `Allow in InPrivate`, but recent Edge supports `MandatoryExtensionsForInPrivateNavigation` to require user approval before private navigation.

## Operational notes

- The daemon is fail-closed by default if the PII engine is unavailable.
- Process blocking is configurable through `config/ai-guard.example.json` or the installed config file.
- Browser-side web blocking only applies to Chrome and Edge profiles where the extension is installed.
- The installed daemon can supervise the bundled PII backend on `127.0.0.1:8000`.
- Claude Desktop auto-updates into new `app-*` folders. Re-run `installer\install.ps1` after a desktop app update so the new preload bundle gets patched.
- Microsoft Store Claude updates replace the read-only package in `WindowsApps`. Re-run `installer\install.ps1` after a Store update so AI Guard refreshes its mirrored guarded runtime and launcher.
- Silent force-install of self-hosted extensions on Windows is intended for enterprise-managed Chromium browsers. See Chrome and Edge policy documentation:
  - https://support.google.com/chrome/a/answer/9867568?hl=en-gb
  - https://support.google.com/chrome/a/answer/6306504?hl=en
  - https://support.google.com/chrome/a/answer/2657289?hl=en
  - https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/extensionsettings
  - https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/extensioninstallforcelist
  - https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/extensiondevelopermodesettings
  - https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/developertoolsavailability
  - https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
