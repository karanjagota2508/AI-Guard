using AIGuard.Native.Contracts;

namespace AIGuard.Native.Interfaces;

public interface IInstallEngine
{
    Task<InstallerResult> InstallAsync(InstallRequest request, CancellationToken cancellationToken);
    Task<InstallerResult> RepairAsync(InstallRequest request, CancellationToken cancellationToken);
    Task<InstallerResult> UninstallAsync(UninstallRequest request, CancellationToken cancellationToken);
}
