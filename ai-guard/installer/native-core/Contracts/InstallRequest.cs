namespace AIGuard.Native.Contracts;

public sealed class InstallRequest
{
    public string InstallRoot { get; init; } = string.Empty;
    public int PiiPort { get; init; } = 8000;
    public int DaemonPort { get; init; } = 48555;
    public string ChromeExtensionId { get; init; } = "kgfkgellcbbmadimiahbfndmfbhfobko";
    public string EdgeExtensionId { get; init; } = "kgfkgellcbbmadimiahbfndmfbhfobko";
    public string ChromeUpdateUrl { get; init; } = "http://127.0.0.1:48555/update.xml";
    public string EdgeUpdateUrl { get; init; } = "http://127.0.0.1:48555/update.xml";
    public string ExtensionVersion { get; init; } = "1.0.4";
    public string[] AllowedExtensionIds { get; init; } = Array.Empty<string>();
    public bool BlockOtherExtensions { get; init; } = true;
    public bool RequirePrivateBrowsingGuard { get; init; } = true;
    public bool DisallowExtensionDeveloperMode { get; init; } = true;
    public bool DisableBrowserDeveloperTools { get; init; } = true;
}
