namespace AIGuard.Native.Contracts;

public sealed record InstallerResult(
    string Status,
    string Message,
    string InstallRoot,
    string Scope,
    string[] Warnings,
    string[] Errors,
    bool ChromeReady,
    bool EdgeReady,
    string PrivateModeStrategy,
    string DesktopProtectionMode,
    string RollbackHint)
{
    public bool Success => !string.Equals(Status, "failed", StringComparison.OrdinalIgnoreCase);

    public static InstallerResult Succeeded(
        string message,
        string installRoot,
        string scope,
        bool chromeReady,
        bool edgeReady,
        string privateModeStrategy,
        string desktopProtectionMode,
        IEnumerable<string>? warnings = null) =>
        new(
            warnings is null || !warnings.Any() ? "installed" : "installed_with_warning",
            message,
            installRoot,
            scope,
            warnings?.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray() ?? Array.Empty<string>(),
            Array.Empty<string>(),
            chromeReady,
            edgeReady,
            privateModeStrategy,
            desktopProtectionMode,
            string.Empty);

    public static InstallerResult Failed(
        string message,
        string installRoot,
        string scope,
        string rollbackHint,
        IEnumerable<string>? errors = null,
        IEnumerable<string>? warnings = null) =>
        new(
            "failed",
            message,
            installRoot,
            scope,
            warnings?.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray() ?? Array.Empty<string>(),
            errors?.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray() ?? Array.Empty<string>(),
            false,
            false,
            string.Empty,
            "uia_fallback",
            rollbackHint);

    public static InstallerResult Uninstalled(
        string message,
        string installRoot,
        string scope,
        IEnumerable<string>? warnings = null) =>
        new(
            "uninstalled",
            message,
            installRoot,
            scope,
            warnings?.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray() ?? Array.Empty<string>(),
            Array.Empty<string>(),
            false,
            false,
            string.Empty,
            "uia_fallback",
            string.Empty);
}
