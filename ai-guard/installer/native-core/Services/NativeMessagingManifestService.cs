using System.Text.Json;
using System.Text.Json.Nodes;
using AIGuard.Native.Internal;
using Microsoft.Win32;

namespace AIGuard.Native.Services;

public sealed class NativeMessagingManifestService
{
    private const string HostName = "com.wininfosoft.ai_guard";
    private const string ChromeHostRegistryPath = $@"SOFTWARE\Google\Chrome\NativeMessagingHosts\{HostName}";
    private const string EdgeHostRegistryPath = $@"SOFTWARE\Microsoft\Edge\NativeMessagingHosts\{HostName}";

    public NativeManifestResult Configure(string installRoot, string configPath)
    {
        var warnings = new List<string>();
        try
        {
            var root = AiGuardJson.LoadObject(configPath);
            var hive = WindowsPolicyService.ResolveRegistryHive(configPath);
            var daemonPath = Path.Combine(installRoot, "ai-guard-daemon.exe");
            var manifestsDir = Path.Combine(installRoot, "manifests");
            Directory.CreateDirectory(manifestsDir);

            var chromeExtensionId = ResolveExtensionId(root, "chrome");
            var edgeExtensionId = ResolveExtensionId(root, "edge");
            if (string.IsNullOrWhiteSpace(chromeExtensionId) || string.IsNullOrWhiteSpace(edgeExtensionId))
            {
                return NativeManifestResult.Failed("Ulti Guard config is missing browser extension IDs.");
            }

            var chromeManifestPath = Path.Combine(manifestsDir, "chrome-native-host.json");
            var edgeManifestPath = Path.Combine(manifestsDir, "edge-native-host.json");

            WriteManifest(
                chromeManifestPath,
                daemonPath,
                FormatBrowserOrigin(chromeExtensionId));
            WriteManifest(
                edgeManifestPath,
                daemonPath,
                FormatBrowserOrigin(edgeExtensionId));

            RegistryStore.SetString(hive, ChromeHostRegistryPath, string.Empty, chromeManifestPath);
            RegistryStore.SetString(hive, EdgeHostRegistryPath, string.Empty, edgeManifestPath);

            return NativeManifestResult.Succeeded(
                "Native messaging manifests were refreshed.",
                new[] { chromeManifestPath, edgeManifestPath },
                warnings.ToArray());
        }
        catch (Exception ex)
        {
            warnings.Add(ex.Message);
            return NativeManifestResult.Failed("Native messaging manifest configuration failed.", warnings.ToArray());
        }
    }

    public NativeManifestResult Remove(string installRoot, string? configPath)
    {
        var warnings = new List<string>();
        try
        {
            var hive = !string.IsNullOrWhiteSpace(configPath) && File.Exists(configPath)
                ? WindowsPolicyService.ResolveRegistryHive(configPath)
                : RegistryHive.LocalMachine;

            RegistryStore.RemoveKeyIfPresent(hive, ChromeHostRegistryPath);
            RegistryStore.RemoveKeyIfPresent(hive, EdgeHostRegistryPath);

            if (hive == RegistryHive.LocalMachine)
            {
                RegistryStore.RemoveKeyIfPresent(RegistryHive.CurrentUser, ChromeHostRegistryPath);
                RegistryStore.RemoveKeyIfPresent(RegistryHive.CurrentUser, EdgeHostRegistryPath);
                warnings.AddRange(RemoveCurrentUserOverrides().Warnings);
            }

            foreach (var manifestPath in new[]
                     {
                         Path.Combine(installRoot, "manifests", "chrome-native-host.json"),
                         Path.Combine(installRoot, "manifests", "edge-native-host.json")
                     })
            {
                if (File.Exists(manifestPath))
                {
                    File.Delete(manifestPath);
                }
            }

            return NativeManifestResult.Succeeded("Native messaging manifests were removed.", Array.Empty<string>(), warnings.ToArray());
        }
        catch (Exception ex)
        {
            warnings.Add(ex.Message);
            return NativeManifestResult.Failed("Native messaging manifest cleanup failed.", warnings.ToArray());
        }
    }

    public NativeManifestResult RemoveCurrentUserOverrides(string? userInstallRoot = null)
    {
        var warnings = new List<string>();
        try
        {
            var manifestCandidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var sid in GetLoadedUserSids())
            {
                AddIfPresent(manifestCandidates, ReadUserDefaultValue(sid, ChromeHostRegistryPath));
                AddIfPresent(manifestCandidates, ReadUserDefaultValue(sid, EdgeHostRegistryPath));
                RemoveUserSubKeyTreeIfPresent(sid, ChromeHostRegistryPath);
                RemoveUserSubKeyTreeIfPresent(sid, EdgeHostRegistryPath);
            }

            foreach (var localInstallRoot in GetUserLocalInstallRoots(userInstallRoot))
            {
                AddIfPresent(manifestCandidates, Path.Combine(localInstallRoot, "manifests", "chrome-native-host.json"));
                AddIfPresent(manifestCandidates, Path.Combine(localInstallRoot, "manifests", "edge-native-host.json"));
            }

            foreach (var manifestPath in manifestCandidates)
            {
                try
                {
                    if (File.Exists(manifestPath))
                    {
                        File.Delete(manifestPath);
                    }
                }
                catch (Exception ex)
                {
                    warnings.Add($"Failed to remove current-user native messaging manifest {manifestPath}: {ex.Message}");
                }
            }

            return NativeManifestResult.Succeeded(
                "Current-user native messaging overrides were removed.",
                manifestCandidates.ToArray(),
                warnings.ToArray());
        }
        catch (Exception ex)
        {
            warnings.Add(ex.Message);
            return NativeManifestResult.Failed("Current-user native messaging override cleanup failed.", warnings.ToArray());
        }
    }

    private static void WriteManifest(string path, string daemonPath, string origin)
    {
        var payload = new JsonObject
        {
            ["name"] = HostName,
            ["description"] = "Ulti Guard native bootstrap host",
            ["path"] = daemonPath,
            ["type"] = "stdio",
            ["allowed_origins"] = new JsonArray(origin)
        };

        File.WriteAllText(path, payload.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    private static string FormatBrowserOrigin(string extensionId) =>
        $"chrome-extension://{extensionId.Trim().TrimEnd('/')}/";

    private static IEnumerable<string> GetUserLocalInstallRoots(string? preferredInstallRoot)
    {
        var results = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        AddIfPresent(results, preferredInstallRoot);
        using var profileList = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList");
        if (profileList is null)
        {
            return results;
        }

        foreach (var sid in profileList.GetSubKeyNames().Where(IsUserSidKey))
        {
            using var profileKey = profileList.OpenSubKey(sid, false);
            var profilePath = profileKey?.GetValue("ProfileImagePath") as string;
            if (string.IsNullOrWhiteSpace(profilePath))
            {
                continue;
            }

            var expanded = Environment.ExpandEnvironmentVariables(profilePath);
            AddIfPresent(results, Path.Combine(expanded, "AppData", "Local", "AI Guard Agent"));
        }

        return results;
    }

    private static IEnumerable<string> GetLoadedUserSids()
    {
        return Registry.Users.GetSubKeyNames()
            .Where(IsUserSidKey)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static string? ReadUserDefaultValue(string sid, string keyPath)
    {
        using var key = Registry.Users.OpenSubKey($@"{sid}\{keyPath}", false);
        return key?.GetValue(string.Empty) as string;
    }

    private static void RemoveUserSubKeyTreeIfPresent(string sid, string keyPath)
    {
        try
        {
            Registry.Users.DeleteSubKeyTree($@"{sid}\{keyPath}", throwOnMissingSubKey: false);
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static bool IsUserSidKey(string value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.StartsWith("S-1-5-", StringComparison.OrdinalIgnoreCase) &&
        !value.EndsWith("_Classes", StringComparison.OrdinalIgnoreCase);

    private static void AddIfPresent(ISet<string> values, string? candidate)
    {
        if (!string.IsNullOrWhiteSpace(candidate))
        {
            values.Add(candidate);
        }
    }

    private static string ResolveExtensionId(JsonObject root, string browser)
    {
        var direct = AiGuardJson.GetString(root, "package", $"{browser}_extension_id");
        if (!string.IsNullOrWhiteSpace(direct))
        {
            return direct;
        }

        return AiGuardJson.GetStringArray(root, "extension_ids").FirstOrDefault() ?? string.Empty;
    }
}

public sealed record NativeManifestResult(
    bool Success,
    string Message,
    string[] Targets,
    string[] Warnings)
{
    public static NativeManifestResult Succeeded(string message, string[] targets, string[] warnings) =>
        new(true, message, targets, warnings);

    public static NativeManifestResult Failed(string message, params string[] warnings) =>
        new(false, message, Array.Empty<string>(), warnings);
}
