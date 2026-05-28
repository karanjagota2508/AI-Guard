using AIGuard.Native.Contracts;
using AIGuard.Native.Interfaces;
using AIGuard.Native.Internal;
using Microsoft.Win32;
using System.Text.Json;

namespace AIGuard.Native.Services;

public sealed class DesktopIntegrationService : IDesktopIntegrationService
{
    private const string RunValueName = "UltiGuardDesktopSessionHelper";
    private const string HookFileName = "ai-guard-claude-hook.cjs";
    private const string BridgeFileName = "ai-guard-desktop-bridge.json";
    private const string BackupSuffix = ".ai-guard.bak";

    public Task<DesktopPatchResult> ConfigureAsync(string installRoot, string configPath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var helperPath = Path.Combine(installRoot, "desktop-session", "AIGuard.DesktopSessionHelper.exe");
        var warnings = new List<string>();
        if (!File.Exists(helperPath))
        {
            UpdateProtectionMode(configPath, "uia_fallback");
            return Task.FromResult(
                DesktopPatchResult.UiaFallback(
                    "Claude Desktop native session helper was not found, so desktop protection remains in UIA fallback mode.",
                    $"Missing helper executable: {helperPath}"));
        }

        var hive = WindowsPolicyService.ResolveRegistryHive(configPath);
        var runKeyPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
        RegistryStore.SetString(
            hive,
            runKeyPath,
            RunValueName,
            $"\"{helperPath}\" --config \"{configPath}\"");

        var patchedTargets = RefreshPatchedClaudeTargets(installRoot, configPath, warnings);
        if (patchedTargets.Count > 0)
        {
            UpdateProtectionMode(configPath, "hook_preferred");
            return Task.FromResult(
                new DesktopPatchResult(
                    "patched",
                    "Desktop session helper registration completed and existing Claude hook targets were refreshed.",
                    warnings.ToArray(),
                    "hook_preferred",
                    patchedTargets.ToArray()));
        }

        UpdateProtectionMode(configPath, "uia_fallback");
        warnings.Add("No existing Claude Desktop hook deployment was found, so the native session helper remains active in UIA fallback mode.");
        return Task.FromResult(
            new DesktopPatchResult(
                "fallback",
                "Desktop session helper registration completed.",
                warnings.ToArray(),
                "uia_fallback",
                new[] { helperPath }));
    }

    public Task<DesktopPatchResult> RestoreAsync(string installRoot, string configPath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var hive = WindowsPolicyService.ResolveRegistryHive(configPath);
        RegistryStore.RemoveValueIfPresent(hive, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", RunValueName);
        var warnings = RestorePatchedClaudeTargets(installRoot);
        UpdateProtectionMode(configPath, "uia_fallback");

        return Task.FromResult(
            new DesktopPatchResult(
                "restored",
                "Desktop session helper registration was removed.",
                warnings,
                "uia_fallback",
                Array.Empty<string>()));
    }

    private static List<string> RefreshPatchedClaudeTargets(string installRoot, string configPath, List<string> warnings)
    {
        var hookSourcePath = Path.Combine(installRoot, "desktop", "claude-desktop-hook.cjs");
        if (!File.Exists(hookSourcePath))
        {
            warnings.Add($"Claude Desktop hook source was not found at {hookSourcePath}.");
            return new List<string>();
        }

        var bridgeConfiguration = BuildBridgeConfiguration(configPath);
        var bridgeJson = JsonSerializer.Serialize(bridgeConfiguration, new JsonSerializerOptions
        {
            WriteIndented = true
        });

        var targets = new List<string>();
        foreach (var resourceDirectory in GetClaudeResourceDirectories(installRoot))
        {
            try
            {
                if (!IsPatchedResourceDirectory(resourceDirectory))
                {
                    continue;
                }

                File.Copy(hookSourcePath, Path.Combine(resourceDirectory, HookFileName), overwrite: true);
                File.WriteAllText(Path.Combine(resourceDirectory, BridgeFileName), bridgeJson);
                targets.Add(resourceDirectory);
            }
            catch (Exception ex)
            {
                warnings.Add(ex.Message);
            }
        }

        return targets;
    }

    private static string[] RestorePatchedClaudeTargets(string installRoot)
    {
        var warnings = new List<string>();
        foreach (var resourceDirectory in GetClaudeResourceDirectories(installRoot))
        {
            try
            {
                var asarPath = Path.Combine(resourceDirectory, "app.asar");
                var backupPath = asarPath + BackupSuffix;
                if (File.Exists(backupPath))
                {
                    File.Copy(backupPath, asarPath, overwrite: true);
                    File.Delete(backupPath);
                }

                var hookTarget = Path.Combine(resourceDirectory, HookFileName);
                if (File.Exists(hookTarget))
                {
                    File.Delete(hookTarget);
                }

                var bridgeTarget = Path.Combine(resourceDirectory, BridgeFileName);
                if (File.Exists(bridgeTarget))
                {
                    File.Delete(bridgeTarget);
                }
            }
            catch (Exception ex)
            {
                warnings.Add(ex.Message);
            }
        }

        return warnings.ToArray();
    }

    private static IEnumerable<string> GetClaudeResourceDirectories(string installRoot)
    {
        var roots = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AnthropicClaude"),
            Path.Combine(installRoot, "claude-desktop")
        };

        foreach (var root in roots.Where(Directory.Exists))
        {
            foreach (var directory in Directory.GetDirectories(root, "app-*", SearchOption.TopDirectoryOnly))
            {
                var resourceDirectory = Path.Combine(directory, "resources");
                if (Directory.Exists(resourceDirectory))
                {
                    yield return resourceDirectory;
                }
            }
        }
    }

    private static bool IsPatchedResourceDirectory(string resourceDirectory)
    {
        var asarPath = Path.Combine(resourceDirectory, "app.asar");
        return File.Exists(asarPath + BackupSuffix) ||
               File.Exists(Path.Combine(resourceDirectory, HookFileName)) ||
               File.Exists(Path.Combine(resourceDirectory, BridgeFileName));
    }

    private static object BuildBridgeConfiguration(string configPath)
    {
        var root = AiGuardJson.LoadObject(configPath);
        var listenAddress = AiGuardJson.GetString(root, "listen_address");
        var authToken = AiGuardJson.GetString(root, "auth_token");
        var extensionId = AiGuardJson.GetString(root, "package", "edge_extension_id");
        if (string.IsNullOrWhiteSpace(extensionId))
        {
            extensionId = AiGuardJson.GetString(root, "package", "chrome_extension_id");
        }
        if (string.IsNullOrWhiteSpace(extensionId))
        {
            extensionId = AiGuardJson.GetStringArray(root, "extension_ids").FirstOrDefault() ?? string.Empty;
        }

        if (string.IsNullOrWhiteSpace(listenAddress) ||
            string.IsNullOrWhiteSpace(authToken) ||
            string.IsNullOrWhiteSpace(extensionId))
        {
            throw new InvalidOperationException("Ulti Guard config is missing Claude Desktop bridge settings.");
        }

        return new
        {
            base_url = $"http://{listenAddress}",
            token = authToken,
            origin = $"chrome-extension://{extensionId}"
        };
    }

    private static void UpdateProtectionMode(string configPath, string protectionMode)
    {
        if (!File.Exists(configPath))
        {
            return;
        }

        var root = AiGuardJson.LoadObject(configPath);
        AiGuardJson.SetString(root, protectionMode, "claude", "desktop_protection_mode");
        AiGuardJson.SaveIndented(configPath, root);
    }
}
