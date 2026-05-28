using AIGuard.Native.Contracts;
using AIGuard.Native.Services;

namespace AIGuard.AdminConsole.Services;

internal sealed class AdminOperations
{
    private readonly WindowsPolicyService _policyService = new();
    private readonly RuntimeRestartService _runtimeRestartService = new();

    public async Task ApplyBrowserPoliciesAsync(string installRoot, string configPath, CancellationToken cancellationToken)
    {
        var result = await _policyService.ApplyFromConfigAsync(configPath, cancellationToken);
        if (!result.Success)
        {
            throw new InvalidOperationException(result.Message);
        }
    }

    public Task<RuntimeRestartResult> RestartRuntimeAsync(string installRoot, string configPath, CancellationToken cancellationToken) =>
        _runtimeRestartService.RestartAsync(installRoot, configPath, cancellationToken);
}
