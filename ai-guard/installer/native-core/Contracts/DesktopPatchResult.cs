namespace AIGuard.Native.Contracts;

public sealed record DesktopPatchResult(
    string Status,
    string Message,
    string[] Warnings,
    string DesktopProtectionMode,
    string[] Targets)
{
    public bool Success => !string.Equals(Status, "failed", StringComparison.OrdinalIgnoreCase);

    public static DesktopPatchResult HookPreferred(string message, params string[] targets) =>
        new("patched", message, Array.Empty<string>(), "hook_preferred", targets);

    public static DesktopPatchResult UiaFallback(string message, params string[] warnings) =>
        new("fallback", message, warnings.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray(), "uia_fallback", Array.Empty<string>());

    public static DesktopPatchResult Failed(string message, params string[] warnings) =>
        new("failed", message, warnings.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray(), "uia_fallback", Array.Empty<string>());
}
