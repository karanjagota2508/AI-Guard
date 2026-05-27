using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Text;

namespace AIGuard.AdminConsole.Services;

internal sealed class AdminOperations
{
    private readonly ConfigService _configService = new();
    private readonly HttpClient _httpClient = new()
    {
        Timeout = TimeSpan.FromSeconds(5)
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

    public async Task<RuntimeRestartResult> RestartRuntimeAsync(string installRoot, string configPath, CancellationToken cancellationToken)
    {
        var probe = LoadRuntimeProbe(configPath);
        try
        {
            var useWindowsService = _configService.IsMachineInstall(configPath)
                && await ServiceExistsAsync("AIGuardAgent", cancellationToken);

            if (useWindowsService)
            {
                var restarted = await RestartWindowsServiceAsync("AIGuardAgent", cancellationToken);
                if (!restarted)
                {
                    var result = RuntimeRestartResult.Failure(
                        "Windows service restart failed before the daemon reported a running state.",
                        $"The Windows service AIGuardAgent could not be restarted successfully. Expected readiness probe: {probe.ReadyUri}");
                    LogRuntimeRestart(result, probe.LogPath);
                    return result;
                }

                if (await WaitForReadyAsync(probe, cancellationToken))
                {
                    var result = RuntimeRestartResult.Succeeded("Windows service restarted successfully.");
                    LogRuntimeRestart(result, probe.LogPath);
                    return result;
                }

                var readinessFailure = RuntimeRestartResult.Failure(
                    "Windows service restart requested, but daemon readiness check failed.",
                    $"The Windows service restarted, but the daemon never reported ready at {probe.ReadyUri} within {probe.ReadinessTimeout.TotalSeconds:0} seconds.");
                LogRuntimeRestart(readinessFailure, probe.LogPath);
                return readinessFailure;
            }

            var launcherScript = Path.Combine(installRoot, "launch-daemon.ps1");
            if (File.Exists(launcherScript))
            {
                await RunPowerShellFileAsync(launcherScript, string.Empty, cancellationToken, waitForExit: false);
                if (await WaitForReadyAsync(probe, cancellationToken))
                {
                    var result = RuntimeRestartResult.Succeeded("Daemon relaunched through launcher script.");
                    LogRuntimeRestart(result, probe.LogPath);
                    return result;
                }

                var readinessFailure = RuntimeRestartResult.Failure(
                    "Launcher script executed, but daemon readiness check failed.",
                    $"The launcher script ran, but the daemon never reported ready at {probe.ReadyUri} within {probe.ReadinessTimeout.TotalSeconds:0} seconds.");
                LogRuntimeRestart(readinessFailure, probe.LogPath);
                return readinessFailure;
            }

            var daemonBinary = Path.Combine(installRoot, "ai-guard-daemon.exe");
            if (File.Exists(daemonBinary))
            {
                await RunProcessAsync(
                    daemonBinary,
                    $"--config \"{configPath}\" run",
                    cancellationToken,
                    waitForExit: false);

                if (await WaitForReadyAsync(probe, cancellationToken))
                {
                    var result = RuntimeRestartResult.Succeeded("Daemon relaunched directly.");
                    LogRuntimeRestart(result, probe.LogPath);
                    return result;
                }

                var readinessFailure = RuntimeRestartResult.Failure(
                    "Daemon launch attempted, but readiness check failed.",
                    $"The daemon process was launched directly, but readiness never succeeded at {probe.ReadyUri} within {probe.ReadinessTimeout.TotalSeconds:0} seconds.");
                LogRuntimeRestart(readinessFailure, probe.LogPath);
                return readinessFailure;
            }

            var manualRestart = RuntimeRestartResult.Failure(
                "Config saved. Restart Ulti Guard manually.",
                $"No Windows service, launcher script, or daemon binary was found under {installRoot}.");
            LogRuntimeRestart(manualRestart, probe.LogPath);
            return manualRestart;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            var unexpectedFailure = RuntimeRestartResult.Failure(
                "Ulti Guard restart failed unexpectedly.",
                ex.Message);
            LogRuntimeRestart(unexpectedFailure, probe.LogPath);
            return unexpectedFailure;
        }
    }

    private async Task<bool> WaitForReadyAsync(RuntimeProbe probe, CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.Add(probe.ReadinessTimeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using var response = await _httpClient.GetAsync(probe.ReadyUri, cancellationToken);
                if (response.IsSuccessStatusCode)
                {
                    return true;
                }
            }
            catch
            {
            }

            await Task.Delay(1500, cancellationToken);
        }

        return false;
    }

    private async Task<bool> RestartWindowsServiceAsync(string serviceName, CancellationToken cancellationToken)
    {
        var currentState = await QueryServiceStateAsync(serviceName, cancellationToken);
        if (currentState != ServiceRuntimeState.Stopped)
        {
            await RunProcessAsync("sc.exe", $"stop {serviceName}", cancellationToken, allowFailure: true);
            if (!await WaitForServiceStateAsync(serviceName, ServiceRuntimeState.Stopped, TimeSpan.FromSeconds(60), cancellationToken))
            {
                return false;
            }
        }

        await RunProcessAsync("sc.exe", $"start {serviceName}", cancellationToken, allowFailure: true);
        return await WaitForServiceStateAsync(serviceName, ServiceRuntimeState.Running, TimeSpan.FromSeconds(60), cancellationToken);
    }

    private async Task<bool> WaitForServiceStateAsync(
        string serviceName,
        ServiceRuntimeState desiredState,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var state = await QueryServiceStateAsync(serviceName, cancellationToken);
            if (state == desiredState)
            {
                return true;
            }

            await Task.Delay(1000, cancellationToken);
        }

        return false;
    }

    private async Task<ServiceRuntimeState> QueryServiceStateAsync(string serviceName, CancellationToken cancellationToken)
    {
        var output = await RunProcessCaptureAsync("sc.exe", $"query {serviceName}", cancellationToken, allowFailure: true);
        if (string.IsNullOrWhiteSpace(output))
        {
            return ServiceRuntimeState.Unknown;
        }

        foreach (var rawLine in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim();
            if (!line.StartsWith("STATE", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (line.Contains("RUNNING", StringComparison.OrdinalIgnoreCase))
            {
                return ServiceRuntimeState.Running;
            }

            if (line.Contains("STOPPED", StringComparison.OrdinalIgnoreCase))
            {
                return ServiceRuntimeState.Stopped;
            }

            if (line.Contains("START_PENDING", StringComparison.OrdinalIgnoreCase))
            {
                return ServiceRuntimeState.StartPending;
            }

            if (line.Contains("STOP_PENDING", StringComparison.OrdinalIgnoreCase))
            {
                return ServiceRuntimeState.StopPending;
            }
        }

        return ServiceRuntimeState.Unknown;
    }

    private RuntimeProbe LoadRuntimeProbe(string configPath)
    {
        JsonObject root;
        try
        {
            root = _configService.Load(configPath);
        }
        catch
        {
            return RuntimeProbe.Default;
        }

        var listenAddress = root["listen_address"]?.GetValue<string>()?.Trim();
        var readyUri = BuildReadyUri(listenAddress);
        var logPath = BuildAdminConsoleLogPath(configPath, root);

        var readinessTimeout = TimeSpan.FromSeconds(60);
        var managedPii = root["managed_pii"] as JsonObject;
        var managedPiiEnabled = managedPii?["enabled"]?.GetValue<bool>() ?? false;
        var startupTimeoutMs = managedPii?["startup_timeout_ms"]?.GetValue<int?>() ?? 0;
        if (managedPiiEnabled && startupTimeoutMs > 0)
        {
            var bufferedTimeoutMs = Math.Clamp(startupTimeoutMs + 15000, 60000, 300000);
            readinessTimeout = TimeSpan.FromMilliseconds(bufferedTimeoutMs);
        }

        return new RuntimeProbe(readyUri, readinessTimeout, logPath);
    }

    private static Uri BuildReadyUri(string? listenAddress)
    {
        if (string.IsNullOrWhiteSpace(listenAddress))
        {
            return RuntimeProbe.Default.ReadyUri;
        }

        var candidate = listenAddress.Contains("://", StringComparison.Ordinal)
            ? listenAddress
            : $"http://{listenAddress}";
        if (Uri.TryCreate(candidate, UriKind.Absolute, out var baseUri))
        {
            return new Uri(baseUri, "/readyz");
        }

        return RuntimeProbe.Default.ReadyUri;
    }

    private static string BuildAdminConsoleLogPath(string configPath, JsonObject root)
    {
        try
        {
            var configDirectory = Path.GetDirectoryName(configPath);
            var loggingDirectory = root["logging"]?["directory"]?.GetValue<string>();
            if (!string.IsNullOrWhiteSpace(loggingDirectory))
            {
                var resolvedDirectory = Path.IsPathRooted(loggingDirectory)
                    ? loggingDirectory
                    : Path.GetFullPath(Path.Combine(configDirectory ?? AppContext.BaseDirectory, loggingDirectory));
                return Path.Combine(resolvedDirectory, "admin-console.log");
            }
        }
        catch
        {
        }

        var fallbackDirectory = Path.Combine(
            Path.GetDirectoryName(configPath) ?? AppContext.BaseDirectory,
            "..",
            "logs");
        return Path.GetFullPath(Path.Combine(fallbackDirectory, "admin-console.log"));
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

    private static async Task<string> RunProcessCaptureAsync(
        string fileName,
        string arguments,
        CancellationToken cancellationToken,
        bool allowFailure = false)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        using var process = new Process
        {
            StartInfo = startInfo
        };

        if (!process.Start())
        {
            throw new InvalidOperationException($"Failed to start process: {fileName}");
        }

        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var stdout = await stdoutTask;
        var stderr = await stderrTask;

        if (!allowFailure && process.ExitCode != 0)
        {
            var details = string.IsNullOrWhiteSpace(stderr) ? stdout : stderr;
            throw new InvalidOperationException($"{Path.GetFileName(fileName)} exited with code {process.ExitCode}. {details}".Trim());
        }

        return string.IsNullOrWhiteSpace(stdout) ? stderr : stdout;
    }

    private static void LogRuntimeRestart(RuntimeRestartResult result, string logPath)
    {
        try
        {
            var directory = Path.GetDirectoryName(logPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var builder = new StringBuilder();
            builder.Append('[')
                .Append(DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss zzz"))
                .Append("] ")
                .Append(result.Success ? "INFO" : "WARN")
                .Append(" SaveApply runtime restart: ")
                .Append(result.Message);

            if (!string.IsNullOrWhiteSpace(result.DiagnosticMessage))
            {
                builder.Append(" | ").Append(result.DiagnosticMessage);
            }

            builder.AppendLine();
            File.AppendAllText(logPath, builder.ToString(), Encoding.UTF8);
        }
        catch
        {
        }
    }

    private sealed record RuntimeProbe(Uri ReadyUri, TimeSpan ReadinessTimeout, string LogPath)
    {
        public static RuntimeProbe Default { get; } = new(
            new Uri("http://127.0.0.1:48555/readyz"),
            TimeSpan.FromSeconds(60),
            Path.Combine(AppContext.BaseDirectory, "admin-console.log"));
    }

    private enum ServiceRuntimeState
    {
        Unknown,
        Running,
        Stopped,
        StartPending,
        StopPending
    }
}

internal sealed record RuntimeRestartResult(bool Success, string Message, string DiagnosticMessage)
{
    public static RuntimeRestartResult Succeeded(string message) => new(true, message, string.Empty);

    public static RuntimeRestartResult Failure(string message, string diagnosticMessage) =>
        new(false, message, diagnosticMessage);
}
