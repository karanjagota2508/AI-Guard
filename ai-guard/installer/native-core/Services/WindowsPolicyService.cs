using System.Text.Json.Nodes;
using AIGuard.Native.Contracts;
using AIGuard.Native.Interfaces;
using AIGuard.Native.Internal;
using Microsoft.Win32;
using System.Text.Json;
using System.Runtime.InteropServices;
using System.Diagnostics;

namespace AIGuard.Native.Services;

public sealed class WindowsPolicyService : IPolicyService
{
    public Task<PolicyApplyResult> ApplyFromConfigAsync(string configPath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var root = AiGuardJson.LoadObject(configPath);
        var hive = ResolveRegistryHive(configPath);
        var chromeExtensionId = ResolveExtensionId(root, browser: "chrome");
        var edgeExtensionId = ResolveExtensionId(root, browser: "edge");
        var chromeUpdateUrl = AiGuardJson.GetString(root, "package", "chrome_update_url");
        var edgeUpdateUrl = AiGuardJson.GetString(root, "package", "edge_update_url");
        var extensionVersion = AiGuardJson.GetString(root, "package", "extension_version");
        var allowedExtensionIds = AiGuardJson.GetStringArray(root, "extension_ids");
        var hosts = AiGuardJson.GetStringArray(root, "blocking", "browser_hosts");

        foreach (var required in new[]
        {
            new { Label = "Chrome extension ID", Value = chromeExtensionId },
            new { Label = "Edge extension ID", Value = edgeExtensionId },
            new { Label = "Chrome update URL", Value = chromeUpdateUrl },
            new { Label = "Edge update URL", Value = edgeUpdateUrl }
        })
        {
            if (string.IsNullOrWhiteSpace(required.Value))
            {
                throw new InvalidOperationException($"Ulti Guard config is missing {required.Label}.");
            }
        }

        ApplyManagedExtensionPolicy(
            hive,
            Browser.Chrome,
            chromeExtensionId,
            chromeUpdateUrl,
            extensionVersion,
            allowedExtensionIds,
            blockOtherExtensions: true,
            requirePrivateBrowsingGuard: true,
            disallowExtensionDeveloperMode: true,
            disableDeveloperTools: true);

        ApplyManagedExtensionPolicy(
            hive,
            Browser.Edge,
            edgeExtensionId,
            edgeUpdateUrl,
            extensionVersion,
            allowedExtensionIds,
            blockOtherExtensions: true,
            requirePrivateBrowsingGuard: true,
            disallowExtensionDeveloperMode: true,
            disableDeveloperTools: true);

        SetBrowserHostBlocklist(hive, Browser.Chrome, hosts);
        SetBrowserHostBlocklist(hive, Browser.Edge, hosts);
        SetPrivateBrowsingPolicy(hive, Browser.Chrome, disable: false);
        SetPrivateBrowsingPolicy(hive, Browser.Edge, disable: false);
        RegistryStore.SetString(hive, $@"SOFTWARE\Google\Chrome\Extensions\{chromeExtensionId}", "update_url", chromeUpdateUrl);
        RegistryStore.SetString(hive, $@"SOFTWARE\Microsoft\Edge\Extensions\{edgeExtensionId}", "update_url", edgeUpdateUrl);

        if (!IsChromeSelfHostedManagedSupported())
        {
            var configDirectory = Path.GetDirectoryName(configPath);
            var installRoot = !string.IsNullOrWhiteSpace(configDirectory)
                ? Path.GetFullPath(Path.Combine(configDirectory, ".."))
                : string.Empty;
            ApplyChromeShortcutFallback(installRoot);
        }

        return Task.FromResult(
            PolicyApplyResult.Succeeded(
                $"Ulti Guard browser policies refreshed from {configPath}",
                hive,
                "Chrome",
                "Edge"));
    }

    public Task<PolicyApplyResult> RemoveManagedPoliciesAsync(string configPath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var root = File.Exists(configPath) ? AiGuardJson.LoadObject(configPath) : new JsonObject();
        var hive = ResolveRegistryHive(configPath);
        var chromeExtensionId = ResolveExtensionId(root, "chrome");
        var edgeExtensionId = ResolveExtensionId(root, "edge");

        if (!string.IsNullOrWhiteSpace(chromeExtensionId))
        {
            RemoveManagedExtensionPolicy(hive, Browser.Chrome, chromeExtensionId);
            RegistryStore.RemoveKeyIfPresent(hive, $@"SOFTWARE\Google\Chrome\Extensions\{chromeExtensionId}");
        }

        if (!string.IsNullOrWhiteSpace(edgeExtensionId))
        {
            RemoveManagedExtensionPolicy(hive, Browser.Edge, edgeExtensionId);
            RegistryStore.RemoveKeyIfPresent(hive, $@"SOFTWARE\Microsoft\Edge\Extensions\{edgeExtensionId}");
        }

        return Task.FromResult(
            PolicyApplyResult.Succeeded(
                "Ulti Guard managed browser policies were removed.",
                hive,
                "Chrome",
                "Edge"));
    }

    public static RegistryHive ResolveRegistryHive(string configPath)
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return configPath.StartsWith(programFiles, StringComparison.OrdinalIgnoreCase)
            ? RegistryHive.LocalMachine
            : RegistryHive.CurrentUser;
    }

    private static void ApplyManagedExtensionPolicy(
        RegistryHive hive,
        Browser browser,
        string extensionId,
        string updateUrl,
        string minimumVersionRequired,
        IEnumerable<string> allowedExtensionIds,
        bool blockOtherExtensions,
        bool requirePrivateBrowsingGuard,
        bool disallowExtensionDeveloperMode,
        bool disableDeveloperTools)
    {
        var settings = GetExtensionSettings(hive, browser);
        settings[extensionId] = new JsonObject
        {
            ["installation_mode"] = "force_installed",
            ["update_url"] = updateUrl,
            ["override_update_url"] = true
        };

        if (!string.IsNullOrWhiteSpace(minimumVersionRequired))
        {
            settings[extensionId]!["minimum_version_required"] = minimumVersionRequired;
        }

        if (blockOtherExtensions)
        {
            settings["*"] = new JsonObject
            {
                ["installation_mode"] = "blocked",
                ["blocked_install_message"] = "Only company-approved browser extensions are allowed."
            };
        }

        foreach (var allowedExtensionId in allowedExtensionIds.Where(item =>
                     !string.IsNullOrWhiteSpace(item) &&
                     !string.Equals(item, extensionId, StringComparison.OrdinalIgnoreCase))
                 .Distinct(StringComparer.OrdinalIgnoreCase))
        {
            settings[allowedExtensionId] ??= new JsonObject
            {
                ["installation_mode"] = "allowed"
            };
        }

        SaveExtensionSettings(hive, browser, settings);

        var forceInstallValue = string.IsNullOrWhiteSpace(updateUrl)
            ? extensionId
            : $"{extensionId};{updateUrl}";
        RegistryStore.UpsertStringListEntry(
            hive,
            $@"{GetPolicyRoot(browser)}\ExtensionInstallForcelist",
            forceInstallValue,
            item => item.Split(';', 2)[0]);

        if (disallowExtensionDeveloperMode)
        {
            SetTrackedDwordPolicy(hive, browser, "ExtensionDeveloperModeSettings", 1);
        }

        if (disableDeveloperTools)
        {
            SetTrackedDwordPolicy(hive, browser, "DeveloperToolsAvailability", 2);
        }

        if (requirePrivateBrowsingGuard)
        {
            RegistryStore.UpsertStringListEntry(
                hive,
                GetMandatoryPrivateBrowsingPolicyPath(browser),
                extensionId);
        }
    }

    private static void RemoveManagedExtensionPolicy(RegistryHive hive, Browser browser, string extensionId)
    {
        var settings = GetExtensionSettings(hive, browser);
        settings.Remove(extensionId);
        SaveExtensionSettings(hive, browser, settings);

        RegistryStore.RemoveStringListEntry(
            hive,
            $@"{GetPolicyRoot(browser)}\ExtensionInstallForcelist",
            extensionId,
            item => item.Split(';', 2)[0]);
        RegistryStore.RemoveStringListEntry(
            hive,
            GetMandatoryPrivateBrowsingPolicyPath(browser),
            extensionId);

        RemoveBrowserHostBlocklist(hive, browser);
        RestorePrivateBrowsingPolicy(hive, browser);
        RestoreTrackedDwordPolicy(hive, browser, "ExtensionDeveloperModeSettings");
        RestoreTrackedDwordPolicy(hive, browser, "DeveloperToolsAvailability");
    }

    private static string ResolveExtensionId(JsonObject root, string browser)
    {
        var browserId = AiGuardJson.GetString(root, "package", $"{browser}_extension_id");
        if (!string.IsNullOrWhiteSpace(browserId))
        {
            return browserId;
        }

        var legacy = AiGuardJson.GetString(root, "package", "extension_id");
        if (!string.IsNullOrWhiteSpace(legacy))
        {
            return legacy;
        }

        return AiGuardJson.GetStringArray(root, "extension_ids").FirstOrDefault() ?? string.Empty;
    }

    private static JsonObject GetExtensionSettings(RegistryHive hive, Browser browser)
    {
        var raw = RegistryStore.GetString(hive, GetPolicyRoot(browser), "ExtensionSettings");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return new JsonObject();
        }

        return JsonNode.Parse(raw) as JsonObject
               ?? throw new InvalidOperationException($"Existing {browser} ExtensionSettings policy is not valid JSON and will not be overwritten.");
    }

    private static void SaveExtensionSettings(RegistryHive hive, Browser browser, JsonObject settings)
    {
        if (settings.Count == 0)
        {
            RegistryStore.RemoveValueIfPresent(hive, GetPolicyRoot(browser), "ExtensionSettings");
            return;
        }

        RegistryStore.SetString(
            hive,
            GetPolicyRoot(browser),
            "ExtensionSettings",
            settings.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = false }));
    }

    private static void SetBrowserHostBlocklist(RegistryHive hive, Browser browser, IEnumerable<string> hosts)
    {
        var normalized = NormalizeHosts(hosts);
        var policyPath = $@"{GetPolicyRoot(browser)}\URLBlocklist";
        var existing = RegistryStore.GetStringList(hive, policyPath);
        var previousManaged = NormalizeHosts(ReadStateStringList(hive, browser, "ManagedUrlBlocklist"));
        var preserved = existing.Where(item => !previousManaged.Contains(NormalizeHost(item), StringComparer.OrdinalIgnoreCase));
        var combined = preserved.Concat(normalized).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();

        RegistryStore.SaveStringList(hive, policyPath, combined);
        SaveStateStringList(hive, browser, "ManagedUrlBlocklist", normalized);
    }

    private static void RemoveBrowserHostBlocklist(RegistryHive hive, Browser browser)
    {
        var policyPath = $@"{GetPolicyRoot(browser)}\URLBlocklist";
        var existing = RegistryStore.GetStringList(hive, policyPath);
        var previousManaged = NormalizeHosts(ReadStateStringList(hive, browser, "ManagedUrlBlocklist"));
        var remaining = existing.Where(item => !previousManaged.Contains(NormalizeHost(item), StringComparer.OrdinalIgnoreCase));
        RegistryStore.SaveStringList(hive, policyPath, remaining);
        SaveStateStringList(hive, browser, "ManagedUrlBlocklist", Array.Empty<string>());
    }

    private static void SetPrivateBrowsingPolicy(RegistryHive hive, Browser browser, bool disable)
    {
        if (!disable)
        {
            RestorePrivateBrowsingPolicy(hive, browser);
            if (RegistryStore.GetDword(hive, GetPolicyRoot(browser), GetPrivateBrowsingAvailabilityPolicyName(browser)) == 1)
            {
                RegistryStore.RemoveValueIfPresent(hive, GetPolicyRoot(browser), GetPrivateBrowsingAvailabilityPolicyName(browser));
            }

            return;
        }

        var stateRoot = GetPolicyStateRoot(browser);
        var tracked = RegistryStore.GetString(hive, stateRoot, "PrivateBrowsingPolicyTracked");
        if (tracked is null)
        {
            var previous = RegistryStore.GetDword(hive, GetPolicyRoot(browser), GetPrivateBrowsingAvailabilityPolicyName(browser));
            RegistryStore.SetString(hive, stateRoot, "PrivateBrowsingPolicyTracked", "true");
            RegistryStore.SetString(hive, stateRoot, "PrivateBrowsingPreviousWasSet", (previous is not null).ToString().ToLowerInvariant());
            if (previous is not null)
            {
                RegistryStore.SetString(hive, stateRoot, "PrivateBrowsingPreviousValue", previous.Value.ToString());
            }
        }

        RegistryStore.SetDword(hive, GetPolicyRoot(browser), GetPrivateBrowsingAvailabilityPolicyName(browser), 1);
    }

    private static void RestorePrivateBrowsingPolicy(RegistryHive hive, Browser browser)
    {
        var stateRoot = GetPolicyStateRoot(browser);
        var tracked = RegistryStore.GetString(hive, stateRoot, "PrivateBrowsingPolicyTracked");
        if (tracked is null)
        {
            return;
        }

        var previousWasSet = string.Equals(
            RegistryStore.GetString(hive, stateRoot, "PrivateBrowsingPreviousWasSet"),
            "true",
            StringComparison.OrdinalIgnoreCase);
        if (previousWasSet &&
            int.TryParse(RegistryStore.GetString(hive, stateRoot, "PrivateBrowsingPreviousValue"), out var previousValue))
        {
            RegistryStore.SetDword(hive, GetPolicyRoot(browser), GetPrivateBrowsingAvailabilityPolicyName(browser), previousValue);
        }
        else
        {
            RegistryStore.RemoveValueIfPresent(hive, GetPolicyRoot(browser), GetPrivateBrowsingAvailabilityPolicyName(browser));
        }

        RegistryStore.RemoveValueIfPresent(hive, stateRoot, "PrivateBrowsingPolicyTracked");
        RegistryStore.RemoveValueIfPresent(hive, stateRoot, "PrivateBrowsingPreviousWasSet");
        RegistryStore.RemoveValueIfPresent(hive, stateRoot, "PrivateBrowsingPreviousValue");
    }

    private static void SetTrackedDwordPolicy(RegistryHive hive, Browser browser, string name, int value)
    {
        var stateRoot = GetPolicyStateRoot(browser);
        var trackedName = $"{name}.Tracked";
        if (RegistryStore.GetString(hive, stateRoot, trackedName) is null)
        {
            var previous = RegistryStore.GetDword(hive, GetPolicyRoot(browser), name);
            RegistryStore.SetString(hive, stateRoot, trackedName, "true");
            RegistryStore.SetString(hive, stateRoot, $"{name}.PreviousWasSet", (previous is not null).ToString().ToLowerInvariant());
            if (previous is not null)
            {
                RegistryStore.SetString(hive, stateRoot, $"{name}.PreviousValue", previous.Value.ToString());
            }
        }

        RegistryStore.SetDword(hive, GetPolicyRoot(browser), name, value);
    }

    private static void RestoreTrackedDwordPolicy(RegistryHive hive, Browser browser, string name)
    {
        var stateRoot = GetPolicyStateRoot(browser);
        if (RegistryStore.GetString(hive, stateRoot, $"{name}.Tracked") is null)
        {
            return;
        }

        var previousWasSet = string.Equals(
            RegistryStore.GetString(hive, stateRoot, $"{name}.PreviousWasSet"),
            "true",
            StringComparison.OrdinalIgnoreCase);

        if (previousWasSet &&
            int.TryParse(RegistryStore.GetString(hive, stateRoot, $"{name}.PreviousValue"), out var previousValue))
        {
            RegistryStore.SetDword(hive, GetPolicyRoot(browser), name, previousValue);
        }
        else
        {
            RegistryStore.RemoveValueIfPresent(hive, GetPolicyRoot(browser), name);
        }

        RegistryStore.RemoveValueIfPresent(hive, stateRoot, $"{name}.Tracked");
        RegistryStore.RemoveValueIfPresent(hive, stateRoot, $"{name}.PreviousWasSet");
        RegistryStore.RemoveValueIfPresent(hive, stateRoot, $"{name}.PreviousValue");
    }

    private static string[] ReadStateStringList(RegistryHive hive, Browser browser, string name)
    {
        var raw = RegistryStore.GetString(hive, GetPolicyStateRoot(browser), name);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return Array.Empty<string>();
        }

        try
        {
            return JsonNode.Parse(raw) is JsonArray array
                ? array.Select(item => item?.GetValue<string>()?.Trim()).Where(item => !string.IsNullOrWhiteSpace(item)).Cast<string>().ToArray()
                : Array.Empty<string>();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    private static void SaveStateStringList(RegistryHive hive, Browser browser, string name, IEnumerable<string> values)
    {
        var normalized = values
            .Select(NormalizeHost)
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (normalized.Length == 0)
        {
            RegistryStore.RemoveValueIfPresent(hive, GetPolicyStateRoot(browser), name);
            return;
        }

        RegistryStore.SetString(
            hive,
            GetPolicyStateRoot(browser),
            name,
            JsonSerializer.Serialize(normalized));
    }

    private static string[] NormalizeHosts(IEnumerable<string> hosts) =>
        hosts.Select(NormalizeHost)
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

    private static string NormalizeHost(string value) =>
        (value ?? string.Empty).Trim().ToLowerInvariant().Trim('.');

    private static string GetPolicyRoot(Browser browser) =>
        browser == Browser.Chrome
            ? @"SOFTWARE\Policies\Google\Chrome"
            : @"SOFTWARE\Policies\Microsoft\Edge";

    private static string GetPolicyStateRoot(Browser browser) =>
        $@"SOFTWARE\WinInfoSoft\AI Guard Agent\PolicyState\{browser}";

    private static string GetMandatoryPrivateBrowsingPolicyPath(Browser browser) =>
        browser == Browser.Chrome
            ? @"SOFTWARE\Policies\Google\Chrome\MandatoryExtensionsForIncognitoNavigation"
            : @"SOFTWARE\Policies\Microsoft\Edge\MandatoryExtensionsForInPrivateNavigation";

    private static string GetPrivateBrowsingAvailabilityPolicyName(Browser browser) =>
        browser == Browser.Chrome ? "IncognitoModeAvailability" : "InPrivateModeAvailability";

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    private static extern int NetGetJoinInformation(string? lpServer, out IntPtr lpNameBuffer, out int BufferType);

    [DllImport("netapi32.dll")]
    private static extern int NetApiBufferFree(IntPtr Buffer);

    private static bool IsDomainJoined()
    {
        IntPtr nameBuffer = IntPtr.Zero;
        try
        {
            int result = NetGetJoinInformation(null, out nameBuffer, out int bufferType);
            if (result == 0) // NERR_Success
            {
                // 3 = NetJoinDomain
                return bufferType == 3;
            }
        }
        catch { }
        finally
        {
            if (nameBuffer != IntPtr.Zero)
            {
                NetApiBufferFree(nameBuffer);
            }
        }
        return false;
    }

    private static bool IsAzureAdJoined()
    {
        try
        {
            using (var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"))
            {
                if (key != null)
                {
                    return key.GetSubKeyNames().Length > 0;
                }
            }
        }
        catch { }
        return false;
    }

    private static bool IsChromeEnterpriseEnrollmentConfigured()
    {
        try
        {
            using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Policies\Google\Chrome"))
            {
                if (key != null)
                {
                    var token = key.GetValue("CloudManagementEnrollmentToken") as string;
                    return !string.IsNullOrWhiteSpace(token);
                }
            }
        }
        catch { }
        return false;
    }

    public static bool IsChromeSelfHostedManagedSupported()
    {
        return IsDomainJoined() || IsAzureAdJoined() || IsChromeEnterpriseEnrollmentConfigured();
    }

    private static void ApplyChromeShortcutFallback(string installRoot)
    {
        if (string.IsNullOrWhiteSpace(installRoot)) return;
        var extensionDir = Path.Combine(installRoot, "extension");
        if (!Directory.Exists(extensionDir)) return;

        var psScript = $@"
$extensionDir = '{extensionDir.Replace("'", "''")}'
$startMenu = [Environment]::GetFolderPath('CommonPrograms')
if (-not $startMenu) {{ $startMenu = $env:ProgramData + '\Microsoft\Windows\Start Menu\Programs' }}

$chromePath = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -Name '(Default)' -ErrorAction SilentlyContinue).'(Default)'
if (-not $chromePath -or -not (Test-Path $chromePath)) {{
    $chromePath = [Environment]::GetFolderPath('ProgramFiles') + '\Google\Chrome\Application\chrome.exe'
}}
if (-not (Test-Path $chromePath)) {{
    $chromePath = [Environment]::GetFolderPath('ProgramFilesX86') + '\Google\Chrome\Application\chrome.exe'
}}

if (Test-Path $chromePath) {{
    $searchRoots = @(
        $env:PUBLIC + '\Desktop',
        [Environment]::GetFolderPath('Desktop'),
        $startMenu,
        [Environment]::GetFolderPath('Programs'),
        $env:APPDATA + '\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    )

    $shell = New-Object -ComObject WScript.Shell
    foreach ($root in $searchRoots) {{
        if (-not $root -or -not (Test-Path $root)) {{ continue }}
        Get-ChildItem -Path $root -Filter *.lnk -Recurse -ErrorAction SilentlyContinue | ForEach-Object {{
            try {{
                $shortcut = $shell.CreateShortcut($_.FullName)
                $target = $shortcut.TargetPath
                if ($target -and ($target.EndsWith('chrome.exe') -or $target.EndsWith('chrome_proxy.exe'))) {{
                    if ($shortcut.Arguments -match '--app-id=' -or $shortcut.Arguments -match '--app=') {{ return }}
                    $cleanArgs = ($shortcut.Arguments -replace '--load-extension=(?:\x22[^\x22]*\x22|\S+)', '').Trim()
                    $shortcut.Arguments = ($cleanArgs + ' --load-extension=' + [char]34 + $extensionDir + [char]34).Trim()
                    $shortcut.Save()
                }}
            }} catch {{}}
        }}
    }}

    try {{
        $managedShortcut = Join-Path $startMenu 'Ulti Guard Google Chrome.lnk'
        $shortcut = $shell.CreateShortcut($managedShortcut)
        $shortcut.TargetPath = $chromePath
        $shortcut.Arguments = '--load-extension=' + [char]34 + $extensionDir + [char]34
        $shortcut.WorkingDirectory = Split-Path $chromePath -Parent
        $shortcut.Description = 'Launch Google Chrome with Ulti Guard protection.'
        $shortcut.Save()
    }} catch {{}}
}}";

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -Command \"{psScript.Replace("\"", "\\\"")}\"",
                CreateNoWindow = true,
                UseShellExecute = false,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (var process = Process.Start(startInfo))
            {
                process?.WaitForExit(15000);
            }
        }
        catch { }
    }

    private enum Browser
    {
        Chrome,
        Edge
    }
}
