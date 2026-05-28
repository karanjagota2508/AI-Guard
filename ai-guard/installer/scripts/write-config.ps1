param(
    [string]$OutputPath,
    [int]$PiiPort,
    [string]$DaemonHost = "127.0.0.1",
    [int]$DaemonPort = 48555,
    [string]$AuthToken,
    [string]$ExtensionCrxPath,
    [string]$ChromeExtensionId = "kgfkgellcbbmadimiahbfndmfbhfobko",
    [string]$EdgeExtensionId = "kgfkgellcbbmadimiahbfndmfbhfobko",
    [string]$ChromeUpdateUrl = "http://127.0.0.1:48555/update.xml",
    [string]$EdgeUpdateUrl = "http://127.0.0.1:48555/update.xml",
    [string]$ExtensionVersion = "1.0.4",
    [string]$LogDirectory,
    [string]$PiiExecutablePath,
    [string]$PiiWorkingDirectory,
    [string]$PiiStdoutLogPath,
    [string]$PiiStderrLogPath,
    [string]$PiiPythonPath = "",
    [int]$PiiStartupDelayMs = 0,
    [string[]]$ClaudeWebHosts = @("claude.ai", "claude.com")
)

$ErrorActionPreference = "Stop"

$defaultsPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "shared\default-blocking.json"
$blockingDefaults = if (Test-Path $defaultsPath) {
    Get-Content -Path $defaultsPath -Raw | ConvertFrom-Json
} else {
    [pscustomobject]@{
        browser_hosts = @(
            "chatgpt.com",
            "chat.openai.com",
            "gemini.google.com",
            "perplexity.ai",
            "www.perplexity.ai"
        )
        process_names = @(
            "ChatGPT",
            "Cursor",
            "Ollama",
            "LM Studio",
            "OpenWebUI",
            "AnythingLLM",
            "Jan"
        )
        exempt_process_names = @(
            "ai-guard-daemon",
            "msedge",
            "chrome"
        )
    }
}
$extensionIds = @($ChromeExtensionId, $EdgeExtensionId | Where-Object { $_ } | Select-Object -Unique)
$resolvedPiiPythonPath = if ($PiiPythonPath) {
    $PiiPythonPath
} elseif ($PiiWorkingDirectory) {
    $sitePackagesCandidate = Join-Path (Split-Path $PiiWorkingDirectory -Parent) "venv\Lib\site-packages"
    "$PiiWorkingDirectory;$sitePackagesCandidate"
} else {
    ""
}

$config = @{
    listen_address = "${DaemonHost}:${DaemonPort}"
    auth_token = $AuthToken
    pii_engine_url = "http://127.0.0.1:$PiiPort/api/pii/detect"
    pii_anonymize_url = "http://127.0.0.1:$PiiPort/api/pii/anonymize"
    pii = @{
        enabled = $true
        confidence_score = 0.35
        action = "redact"
    }
    managed_pii = @{
        enabled = $true
        executable = $PiiExecutablePath
        args = @("main.py")
        working_directory = $PiiWorkingDirectory
        health_url = "http://127.0.0.1:$PiiPort/health"
        startup_timeout_ms = 180000
        restart_delay_ms = 5000
        env = @{
            HOST = "127.0.0.1"
            PORT = "$PiiPort"
            PII_SERVICE_RELOAD = "false"
            PII_SERVICE_CORS_ORIGINS = "http://127.0.0.1,http://localhost"
            PII_SERVICE_STARTUP_DELAY_MS = "$PiiStartupDelayMs"
            PYTHONPATH = $resolvedPiiPythonPath
        }
        stdout_log_path = $PiiStdoutLogPath
        stderr_log_path = $PiiStderrLogPath
    }
    scan_timeout_ms = 3500
    fail_closed = $true
    browser_heartbeat_ttl_ms = 8000
    desktop_activity_ttl_ms = 5000
    process_poll_ms = 2000
    extension_ids = @($extensionIds)
    claude = @{
        web_hosts = @($ClaudeWebHosts)
        desktop_processes = @("claude")
    }
    blocking = @{
        browser_hosts = @($blockingDefaults.browser_hosts)
        process_names = @($blockingDefaults.process_names)
        exempt_process_names = @($blockingDefaults.exempt_process_names)
    }
    package = @{
        chrome_extension_id = $ChromeExtensionId
        edge_extension_id = $EdgeExtensionId
        chrome_update_url = $ChromeUpdateUrl
        edge_update_url = $EdgeUpdateUrl
        extension_version = $ExtensionVersion
        extension_crx_path = $ExtensionCrxPath
    }
    logging = @{
        directory = $LogDirectory
    }
    admin_console = @{
        secret_file = "admin-console.secret"
        password_iterations = 150000
        minimum_password_length = 12
    }
}

$json = $config | ConvertTo-Json -Depth 8
$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, $json, $encoding)
