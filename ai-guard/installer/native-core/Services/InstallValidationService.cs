using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AIGuard.Native.Internal;
using Microsoft.Win32;

namespace AIGuard.Native.Services;

public sealed class InstallValidationService
{
    private readonly HttpClient _httpClient;
    private readonly NativeMessagingManifestService _nativeMessagingManifestService;

    public InstallValidationService(
        NativeMessagingManifestService? nativeMessagingManifestService = null,
        HttpClient? httpClient = null)
    {
        _nativeMessagingManifestService = nativeMessagingManifestService ?? new NativeMessagingManifestService();
        _httpClient = httpClient ?? new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(10)
        };
    }

    public InstallFlowResult ValidateInstallLayout(string installRoot)
    {
        var errors = new List<string>();
        foreach (var item in GetRequiredLayoutEntries(installRoot))
        {
            if (item.IsDirectory)
            {
                if (!Directory.Exists(item.Path))
                {
                    errors.Add($"{item.Label} is missing at {item.Path}.");
                }
            }
            else if (!File.Exists(item.Path))
            {
                errors.Add($"{item.Label} is missing at {item.Path}.");
            }
        }

        return errors.Count == 0
            ? InstallFlowResult.Passed("Ulti Guard install payload preflight passed.")
            : InstallFlowResult.Failure("Ulti Guard install payload preflight failed.", errors);
    }

    public InstallFlowResult CleanupMachineScopeUserOverrides(string installRoot)
    {
        var warnings = new List<string>();
        var userLocalInstallRoots = GetUserLocalInstallRoots().ToArray();
        var manifestCleanupResult = _nativeMessagingManifestService.RemoveCurrentUserOverrides(userLocalInstallRoots.FirstOrDefault());
        warnings.AddRange(manifestCleanupResult.Warnings);
        if (!manifestCleanupResult.Success)
        {
            return InstallFlowResult.Failure(
                "Current-user native messaging override cleanup failed.",
                new[] { manifestCleanupResult.Message },
                warnings);
        }

        warnings.AddRange(RemoveUserRunKeys());
        warnings.AddRange(StopUserLocalProcesses(userLocalInstallRoots));
        return InstallFlowResult.Passed("Current-user Ulti Guard overrides were neutralized.", warnings);
    }

    public async Task<InstallFlowResult> VerifyRuntimeAsync(string configPath, CancellationToken cancellationToken)
    {
        RuntimeVerificationProbe probe;
        try
        {
            probe = LoadProbe(configPath);
        }
        catch (Exception ex)
        {
            return InstallFlowResult.Failure(
                "Ulti Guard runtime verification could not load the generated config.",
                new[] { ex.Message });
        }

        var errors = new List<string>();

        var healthzResult = await ProbeAsync("healthz", probe.HealthzUri, cancellationToken);
        if (!healthzResult.Success)
        {
            errors.Add(healthzResult.Message);
            return InstallFlowResult.Failure("Ulti Guard health probe failed.", errors);
        }

        var readyzResult = await ProbeAsync("readyz", probe.ReadyzUri, cancellationToken);
        if (!readyzResult.Success)
        {
            errors.Add(readyzResult.Message);
            return InstallFlowResult.Failure("Ulti Guard readiness probe failed.", errors);
        }

        var updateManifestResult = await ProbeAsync("update.xml", probe.UpdateManifestUri, cancellationToken);
        if (!updateManifestResult.Success)
        {
            errors.Add(updateManifestResult.Message);
            return InstallFlowResult.Failure("Ulti Guard update manifest endpoint failed.", errors);
        }

        if (!updateManifestResult.Body.Contains("<updatecheck", StringComparison.OrdinalIgnoreCase))
        {
            errors.Add("The /update.xml response did not contain an extension updatecheck payload.");
            return InstallFlowResult.Failure("Ulti Guard update manifest endpoint returned an invalid payload.", errors);
        }

        var extensionResult = await ProbeAsync("extension.crx", probe.ExtensionPackageUri, cancellationToken);
        if (!extensionResult.Success)
        {
            errors.Add(extensionResult.Message);
            return InstallFlowResult.Failure("Ulti Guard extension package endpoint failed.", errors);
        }

        if (extensionResult.ContentLength <= 0)
        {
            errors.Add("The /extension.crx response was empty.");
            return InstallFlowResult.Failure("Ulti Guard extension package endpoint returned an empty payload.", errors);
        }

        var scanResult = await ProbeScanAsync(probe, cancellationToken);
        if (!scanResult.Success)
        {
            errors.Add(scanResult.Message);
            return InstallFlowResult.Failure("Ulti Guard PII smoke scan failed.", errors);
        }

        return InstallFlowResult.Passed("Ulti Guard runtime smoke verification passed.");
    }

    private static IReadOnlyList<LayoutEntry> GetRequiredLayoutEntries(string installRoot) =>
        new[]
        {
            new LayoutEntry("daemon executable", Path.Combine(installRoot, "ai-guard-daemon.exe"), false),
            new LayoutEntry("portable Python runtime", Path.Combine(installRoot, "python-runtime", "python.exe"), false),
            new LayoutEntry("PII backend entrypoint", Path.Combine(installRoot, "pii-runtime", "backend", "main.py"), false),
            new LayoutEntry("PII site-packages directory", Path.Combine(installRoot, "pii-runtime", "venv", "Lib", "site-packages"), true),
            new LayoutEntry("browser extension package", Path.Combine(installRoot, "dist", "ai-guard-extension.crx"), false),
            new LayoutEntry("admin console helper", Path.Combine(installRoot, "admin-console", "AI-Guard-Admin-Console.exe"), false),
            new LayoutEntry("desktop session helper", Path.Combine(installRoot, "desktop-session", "AIGuard.DesktopSessionHelper.exe"), false),
            new LayoutEntry("setup actions helper", Path.Combine(installRoot, "setup-actions", "AIGuard.Setup.Actions.exe"), false),
            new LayoutEntry("Claude Desktop hook", Path.Combine(installRoot, "desktop", "claude-desktop-hook.cjs"), false)
        };

    private static IEnumerable<string> StopUserLocalProcesses(IReadOnlyCollection<string> localInstallRoots)
    {
        if (localInstallRoots.Count == 0)
        {
            return Array.Empty<string>();
        }

        var normalizedRoots = localInstallRoots
            .Where(static path => !string.IsNullOrWhiteSpace(path))
            .Where(Directory.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (normalizedRoots.Length == 0)
        {
            return Array.Empty<string>();
        }

        var warnings = new List<string>();
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                var executablePath = process.MainModule?.FileName;
                if (string.IsNullOrWhiteSpace(executablePath))
                {
                    continue;
                }

                if (!normalizedRoots.Any(root => executablePath.StartsWith(root, StringComparison.OrdinalIgnoreCase)))
                {
                    continue;
                }

                if (!IsKnownUserLocalRuntimeProcess(process.ProcessName))
                {
                    continue;
                }

                process.Kill(entireProcessTree: true);
                process.WaitForExit(10000);
            }
            catch (Exception ex)
            {
                warnings.Add($"Failed to stop user-local runtime process {process.ProcessName}: {ex.Message}");
            }
            finally
            {
                process.Dispose();
            }
        }

        return warnings;
    }

    private static bool IsKnownUserLocalRuntimeProcess(string processName) =>
        string.Equals(processName, "ai-guard-daemon", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(processName, "python", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(processName, "pythonw", StringComparison.OrdinalIgnoreCase);

    private static IEnumerable<string> RemoveUserRunKeys()
    {
        var warnings = new List<string>();
        foreach (var sid in Registry.Users.GetSubKeyNames().Where(IsUserSidKey))
        {
            try
            {
                using var key = Registry.Users.OpenSubKey(
                    $@"{sid}\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
                    writable: true);
                key?.DeleteValue("AIGuardAgent", throwOnMissingValue: false);
            }
            catch (Exception ex)
            {
                warnings.Add($"Failed to remove the Ulti Guard Run value for user hive {sid}: {ex.Message}");
            }
        }

        return warnings;
    }

    private async Task<HttpProbeResult> ProbeAsync(string label, Uri uri, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await _httpClient.GetAsync(uri, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return HttpProbeResult.Failure(
                    $"{label} probe failed with HTTP {(int)response.StatusCode} from {uri}. Body: {body}");
            }

            return HttpProbeResult.Passed(body, response.Content.Headers.ContentLength ?? body.Length);
        }
        catch (Exception ex)
        {
            return HttpProbeResult.Failure($"{label} probe failed for {uri}: {ex.Message}");
        }
    }

    private async Task<InstallFlowResult> ProbeScanAsync(RuntimeVerificationProbe probe, CancellationToken cancellationToken)
    {
        const string SeedPrompt = "test@example.com";

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, probe.ScanUri);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", probe.AuthToken);
            request.Headers.TryAddWithoutValidation("Origin", probe.ExtensionOrigin);
            request.Content = new StringContent(
                JsonSerializer.Serialize(new { text = SeedPrompt }),
                Encoding.UTF8,
                "application/json");

            using var response = await _httpClient.SendAsync(request, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return InstallFlowResult.Failure(
                    "Ulti Guard /scan verification request failed.",
                    new[] { $"The /scan endpoint returned HTTP {(int)response.StatusCode}. Body: {body}" });
            }

            var root = JsonNode.Parse(body) as JsonObject;
            var decisionKind = root?["decision_kind"]?.GetValue<string>() ?? string.Empty;
            var action = root?["action"]?.GetValue<string>() ?? string.Empty;
            var redactedText = root?["redacted_text"]?.GetValue<string>() ?? string.Empty;

            if (!string.Equals(decisionKind, "pii_detected", StringComparison.OrdinalIgnoreCase))
            {
                return InstallFlowResult.Failure(
                    "Ulti Guard /scan verification did not detect the seeded email address.",
                    new[] { $"Unexpected decision_kind '{decisionKind}'. Body: {body}" });
            }

            var isBlockingOrRedacting =
                string.Equals(action, "redact", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(action, "block", StringComparison.OrdinalIgnoreCase);
            if (!isBlockingOrRedacting)
            {
                return InstallFlowResult.Failure(
                    "Ulti Guard /scan verification returned an unexpected scan action.",
                    new[] { $"Unexpected action '{action}'. Body: {body}" });
            }

            if (string.Equals(redactedText, SeedPrompt, StringComparison.Ordinal))
            {
                return InstallFlowResult.Failure(
                    "Ulti Guard /scan verification returned the seeded email unchanged.",
                    new[] { $"Seeded prompt '{SeedPrompt}' was not redacted. Body: {body}" });
            }

            return InstallFlowResult.Passed("Ulti Guard /scan verification detected and transformed the seeded email address.");
        }
        catch (Exception ex)
        {
            return InstallFlowResult.Failure(
                "Ulti Guard /scan verification failed unexpectedly.",
                new[] { ex.Message });
        }
    }

    private static RuntimeVerificationProbe LoadProbe(string configPath)
    {
        var root = AiGuardJson.LoadObject(configPath);
        var listenAddress = AiGuardJson.GetString(root, "listen_address");
        var baseUri = BuildBaseUri(listenAddress);
        var authToken = AiGuardJson.GetString(root, "auth_token");
        if (string.IsNullOrWhiteSpace(authToken))
        {
            throw new InvalidOperationException("Ulti Guard config is missing auth_token.");
        }

        var chromeExtensionId = AiGuardJson.GetString(root, "package", "chrome_extension_id");
        if (string.IsNullOrWhiteSpace(chromeExtensionId))
        {
            chromeExtensionId = AiGuardJson.GetStringArray(root, "extension_ids").FirstOrDefault();
        }

        if (string.IsNullOrWhiteSpace(chromeExtensionId))
        {
            throw new InvalidOperationException("Ulti Guard config is missing a Chrome extension ID for smoke verification.");
        }

        return new RuntimeVerificationProbe(
            new Uri(baseUri, "/healthz"),
            new Uri(baseUri, "/readyz"),
            new Uri(baseUri, "/update.xml"),
            new Uri(baseUri, "/extension.crx"),
            new Uri(baseUri, "/scan"),
            authToken,
            $"chrome-extension://{chromeExtensionId.Trim().TrimEnd('/')}/");
    }

    private static Uri BuildBaseUri(string listenAddress)
    {
        if (string.IsNullOrWhiteSpace(listenAddress))
        {
            return new Uri("http://127.0.0.1:48555/");
        }

        var candidate = listenAddress.Contains("://", StringComparison.Ordinal)
            ? listenAddress
            : $"http://{listenAddress}";
        return Uri.TryCreate(candidate, UriKind.Absolute, out var baseUri)
            ? new Uri(baseUri, "/")
            : new Uri("http://127.0.0.1:48555/");
    }

    private sealed record LayoutEntry(string Label, string Path, bool IsDirectory);

    private sealed record RuntimeVerificationProbe(
        Uri HealthzUri,
        Uri ReadyzUri,
        Uri UpdateManifestUri,
        Uri ExtensionPackageUri,
        Uri ScanUri,
        string AuthToken,
        string ExtensionOrigin);

    private sealed record HttpProbeResult(bool Success, string Message, string Body, long ContentLength)
    {
        public static HttpProbeResult Passed(string body, long contentLength) =>
            new(true, string.Empty, body, contentLength);

        public static HttpProbeResult Failure(string message) =>
            new(false, message, string.Empty, 0);
    }

    private static IEnumerable<string> GetUserLocalInstallRoots()
    {
        var results = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using var profileList = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList");
        if (profileList is null)
        {
            return results;
        }

        foreach (var sid in profileList.GetSubKeyNames().Where(IsUserSidKey))
        {
            using var profileKey = profileList.OpenSubKey(sid, writable: false);
            var profilePath = profileKey?.GetValue("ProfileImagePath") as string;
            if (string.IsNullOrWhiteSpace(profilePath))
            {
                continue;
            }

            var expanded = Environment.ExpandEnvironmentVariables(profilePath);
            results.Add(Path.Combine(expanded, "AppData", "Local", "AI Guard Agent"));
        }

        return results;
    }

    private static bool IsUserSidKey(string value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.StartsWith("S-1-5-", StringComparison.OrdinalIgnoreCase) &&
        !value.EndsWith("_Classes", StringComparison.OrdinalIgnoreCase);
}

public sealed record InstallFlowResult(bool Success, string Message, string[] Errors, string[] Warnings)
{
    public static InstallFlowResult Passed(string message, IEnumerable<string>? warnings = null) =>
        new(
            true,
            message,
            Array.Empty<string>(),
            warnings?.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray() ?? Array.Empty<string>());

    public static InstallFlowResult Failure(string message, IEnumerable<string>? errors = null, IEnumerable<string>? warnings = null) =>
        new(
            false,
            message,
            errors?.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray() ?? Array.Empty<string>(),
            warnings?.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray() ?? Array.Empty<string>());
}
