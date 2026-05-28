using System.Text.Json.Nodes;
using AIGuard.Native.Contracts;
using AIGuard.Native.Internal;

namespace AIGuard.Native.Services;

public sealed class ConfigMaterializer
{
    public string WriteInstallConfig(InstallRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.InstallRoot))
        {
            throw new InvalidOperationException("InstallRoot is required.");
        }

        var configDirectory = Path.Combine(request.InstallRoot, "config");
        var configPath = Path.Combine(configDirectory, "ai-guard.json");
        var logsDirectory = Path.Combine(request.InstallRoot, "logs");
        var piiRoot = Path.Combine(request.InstallRoot, "pii-runtime");
        var pythonRuntimeRoot = Path.Combine(request.InstallRoot, "python-runtime");
        var piiPython = Path.Combine(pythonRuntimeRoot, "python.exe");
        var piiBackend = Path.Combine(piiRoot, "backend");
        var piiSitePackages = Path.Combine(piiRoot, "venv", "Lib", "site-packages");
        var pythonPath = string.Join(
            Path.PathSeparator,
            new[]
            {
                piiBackend,
                piiSitePackages
            });
        var extensionCrxPath = Path.Combine(request.InstallRoot, "dist", "ai-guard-extension.crx");
        var token = Convert.ToHexString(Guid.NewGuid().ToByteArray()) + Convert.ToHexString(Guid.NewGuid().ToByteArray());
        var extensionIds = request.AllowedExtensionIds
            .Concat(new[] { request.ChromeExtensionId, request.EdgeExtensionId })
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        var defaultsPath = Path.Combine(request.InstallRoot, "shared", "default-blocking.json");
        var blockingDefaults = File.Exists(defaultsPath)
            ? AiGuardJson.LoadObject(defaultsPath)
            : new JsonObject();

        var root = new JsonObject
        {
            ["listen_address"] = $"127.0.0.1:{request.DaemonPort}",
            ["auth_token"] = token,
            ["pii_engine_url"] = $"http://127.0.0.1:{request.PiiPort}/api/pii/detect",
            ["pii_anonymize_url"] = $"http://127.0.0.1:{request.PiiPort}/api/pii/anonymize",
            ["pii"] = new JsonObject
            {
                ["enabled"] = true,
                ["confidence_score"] = 0.35,
                ["action"] = "redact"
            },
            ["managed_pii"] = new JsonObject
            {
                ["enabled"] = true,
                ["executable"] = piiPython,
                ["args"] = new JsonArray("main.py"),
                ["working_directory"] = piiBackend,
                ["health_url"] = $"http://127.0.0.1:{request.PiiPort}/health",
                ["startup_timeout_ms"] = 180000,
                ["restart_delay_ms"] = 5000,
                ["env"] = new JsonObject
                {
                    ["HOST"] = "127.0.0.1",
                    ["PORT"] = request.PiiPort.ToString(),
                    ["PII_SERVICE_RELOAD"] = "false",
                    ["PII_SERVICE_CORS_ORIGINS"] = "http://127.0.0.1,http://localhost",
                    ["PII_SERVICE_STARTUP_DELAY_MS"] = "0",
                    ["PYTHONPATH"] = pythonPath
                },
                ["stdout_log_path"] = Path.Combine(logsDirectory, "pii-agent.stdout.log"),
                ["stderr_log_path"] = Path.Combine(logsDirectory, "pii-agent.stderr.log")
            },
            ["scan_timeout_ms"] = 3500,
            ["fail_closed"] = true,
            ["browser_heartbeat_ttl_ms"] = 8000,
            ["desktop_activity_ttl_ms"] = 5000,
            ["process_poll_ms"] = 2000,
            ["extension_ids"] = new JsonArray(extensionIds.Select(static item => JsonValue.Create(item)).ToArray()),
            ["claude"] = new JsonObject
            {
                ["web_hosts"] = new JsonArray("claude.ai", "claude.com"),
                ["desktop_processes"] = new JsonArray("claude"),
                ["desktop_protection_mode"] = "hook_preferred"
            },
            ["blocking"] = new JsonObject
            {
                ["browser_hosts"] = CloneArray(blockingDefaults["browser_hosts"] as JsonArray),
                ["process_names"] = CloneArray(blockingDefaults["process_names"] as JsonArray),
                ["exempt_process_names"] = CloneArray(blockingDefaults["exempt_process_names"] as JsonArray)
            },
            ["package"] = new JsonObject
            {
                ["chrome_extension_id"] = request.ChromeExtensionId,
                ["edge_extension_id"] = request.EdgeExtensionId,
                ["chrome_update_url"] = request.ChromeUpdateUrl,
                ["edge_update_url"] = request.EdgeUpdateUrl,
                ["extension_version"] = request.ExtensionVersion,
                ["extension_crx_path"] = extensionCrxPath
            },
            ["logging"] = new JsonObject
            {
                ["directory"] = logsDirectory
            },
            ["admin_console"] = new JsonObject
            {
                ["secret_file"] = "admin-console.secret",
                ["password_iterations"] = 150000,
                ["minimum_password_length"] = 12
            }
        };

        AiGuardJson.SaveIndented(configPath, root);
        return configPath;
    }

    private static JsonArray CloneArray(JsonArray? array)
    {
        if (array is null)
        {
            return new JsonArray();
        }

        return new JsonArray(array.Select(item => item?.DeepClone()).ToArray());
    }
}
