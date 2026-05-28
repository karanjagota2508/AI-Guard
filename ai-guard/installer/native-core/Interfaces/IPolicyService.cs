using AIGuard.Native.Contracts;

namespace AIGuard.Native.Interfaces;

public interface IPolicyService
{
    Task<PolicyApplyResult> ApplyFromConfigAsync(string configPath, CancellationToken cancellationToken);
    Task<PolicyApplyResult> RemoveManagedPoliciesAsync(string configPath, CancellationToken cancellationToken);
}
