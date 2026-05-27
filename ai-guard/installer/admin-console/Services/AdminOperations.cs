using System.Diagnostics;
using System.IO;
using System.Net.Http;

namespace AIGuard.AdminConsole.Services;

internal sealed class AdminOperations
{
    private readonly HttpClient _httpClient = new()
    {
        Timeout = TimeSpan.FromSeconds(2)
    };

    public async Task ApplyBrowserPoliciesAsync(string installRoot, string configPath, CancellationToken cancellationToken)
    {
        var scriptPath = Path.Combine(installRoot, "scripts", "apply-browser-policies-from-config.ps1");
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException($"Browser policy helper was not found: {scriptPath}");
        }

        var exitCode = await RunPowerShellFileAsync(
            scriptPath,
            $"-ConfigPath \"{configPath}\"",
            cancellationToken);

        if (exitCode != 0)
        {
            throw new InvalidOperationException("Browser policy refresh failed.");
        }
    }

    public async Task<string> RestartRuntimeAsync(string installRoot, string configPath, CancellationToken cancellationToken)
    {
        if (await ServiceExistsAsync("AIGuardAgent", cancellationToken))
        {
            await RunProcessAsync("sc.exe", "stop AIGuardAgent", cancellationToken, allowFailure: true);
            await Task.Delay(1500, cancellationToken);
            await RunProcessAsync("sc.exe", "start AIGuardAgent", cancellationToken, allowFailure: true);
            return await WaitForReadyAsync(cancellationToken)
                ? "Windows service restarted successfully."
                : "Windows service restart requested, but daemon readiness check failed.";
        }

        var launcherScript = Path.Combine(installRoot, "launch-daemon.ps1");
        if (File.Exists(launcherScript))
        {
            await RunPowerShellFileAsync(launcherScript, string.Empty, cancellationToken, waitForExit: false);
            return await WaitForReadyAsync(cancellationToken)
                ? "Daemon relaunched through launcher script."
                : "Launcher script executed, but daemon readiness check failed.";
        }

        var daemonBinary = Path.Combine(installRoot, "ai-guard-daemon.exe");
        if (File.Exists(daemonBinary))
        {
            await RunProcessAsync(
                daemonBinary,
                $"--config \"{configPath}\" run",
                cancellationToken,
                waitForExit: false);

            return await WaitForReadyAsync(cancellationToken)
                ? "Daemon relaunched directly."
                : "Daemon launch attempted, but readiness check failed.";
        }

        return "Config saved. Restart Ulti Guard manually.";
    }

    private async Task<bool> WaitForReadyAsync(CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(30);
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using var response = await _httpClient.GetAsync("http://127.0.0.1:48555/readyz", cancellationToken);
                if (response.IsSuccessStatusCode)
                {
                    return true;
                }
            }
            catch
            {
            }

            await Task.Delay(1000, cancellationToken);
        }

        return false;
    }

    private async Task<bool> ServiceExistsAsync(string serviceName, CancellationToken cancellationToken)
    {
        var exitCode = await RunProcessAsync("sc.exe", $"query {serviceName}", cancellationToken, allowFailure: true);
        return exitCode == 0;
    }

    private Task<int> RunPowerShellFileAsync(
        string scriptPath,
        string arguments,
        CancellationToken cancellationToken,
        bool waitForExit = true)
    {
        var invocation = string.IsNullOrWhiteSpace(arguments)
            ? $"-NoProfile -ExecutionPolicy RemoteSigned -File \"{scriptPath}\""
            : $"-NoProfile -ExecutionPolicy RemoteSigned -File \"{scriptPath}\" {arguments}";

        return RunProcessAsync(
            "powershell.exe",
            invocation,
            cancellationToken,
            waitForExit: waitForExit);
    }

    private static async Task<int> RunProcessAsync(
        string fileName,
        string arguments,
        CancellationToken cancellationToken,
        bool waitForExit = true,
        bool allowFailure = false)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };

        using var process = new Process
        {
            StartInfo = startInfo
        };

        if (!process.Start())
        {
            throw new InvalidOperationException($"Failed to start process: {fileName}");
        }

        if (!waitForExit)
        {
            return 0;
        }

        await process.WaitForExitAsync(cancellationToken);
        if (!allowFailure && process.ExitCode != 0)
        {
            throw new InvalidOperationException($"{Path.GetFileName(fileName)} exited with code {process.ExitCode}.");
        }

        return process.ExitCode;
    }
}
