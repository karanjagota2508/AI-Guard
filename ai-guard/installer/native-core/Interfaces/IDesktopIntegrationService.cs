using AIGuard.Native.Contracts;

namespace AIGuard.Native.Interfaces;

public interface IDesktopIntegrationService
{
    Task<DesktopPatchResult> ConfigureAsync(string installRoot, string configPath, CancellationToken cancellationToken);
    Task<DesktopPatchResult> RestoreAsync(string installRoot, string configPath, CancellationToken cancellationToken);
}
