using Microsoft.Win32;

namespace AIGuard.Native.Contracts;

public sealed record PolicyApplyResult(
    string Status,
    string Message,
    string[] Warnings,
    string RegistryHive,
    string[] Browsers)
{
    public bool Success => !string.Equals(Status, "failed", StringComparison.OrdinalIgnoreCase);

    public static PolicyApplyResult Succeeded(
        string message,
        RegistryHive hive,
        params string[] browsers) =>
        new(
            "applied",
            message,
            Array.Empty<string>(),
            hive.ToString(),
            browsers);

    public static PolicyApplyResult Failed(
        string message,
        RegistryHive hive,
        params string[] warnings) =>
        new(
            "failed",
            message,
            warnings.Where(item => !string.IsNullOrWhiteSpace(item)).ToArray(),
            hive.ToString(),
            Array.Empty<string>());
}
