namespace AIGuard.Native.Contracts;

public sealed class UninstallRequest
{
    public string InstallRoot { get; init; } = string.Empty;
    public bool KeepFiles { get; init; }
}
