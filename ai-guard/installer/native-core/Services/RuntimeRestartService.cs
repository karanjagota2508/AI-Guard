using System.Net.Http;
using System.ServiceProcess;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using AIGuard.Native.Contracts;
using AIGuard.Native.Internal;

namespace AIGuard.Native.Services;

public sealed class RuntimeRestartService
{
    private readonly HttpClient _httpClient;

    public RuntimeRestartService(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(5)
        };
    }

    public async Task<RuntimeRestartResult> RestartAsync(
        string installRoot,
        string configPath,
        CancellationToken cancellationToken,
        SetupActionLogger? setupLogger = null)
    {
        var probe = LoadRuntimeProbe(configPath);
        int port = 48555;
        try
        {
            var root = AiGuardJson.LoadObject(configPath);
            var listenAddress = AiGuardJson.GetString(root, "listen_address");
            port = GetPortFromListenAddress(listenAddress);
        }
        catch
        {
        }

        ResolvePortConflict(port, setupLogger);

        try
        {
            var service = GetServiceOrDefault("AIGuardAgent");
            if (WindowsPolicyService.ResolveRegistryHive(configPath) == Microsoft.Win32.RegistryHive.LocalMachine && service is not null)
            {
                setupLogger?.Info("service start", $"Restarting Windows service {service.ServiceName}.");
                var restarted = await RestartWindowsServiceAsync(service, cancellationToken);
                if (!restarted)
                {
                    var result = RuntimeRestartResult.Failure(
                        "Windows service restart failed before the daemon reported a running state.",
                        $"The Windows service AIGuardAgent could not be restarted successfully. Expected readiness probe: {probe.ReadyUri}");
                    setupLogger?.Error("service start", result.DiagnosticMessage);
                    LogRuntimeRestart(result, probe.LogPath);
                    return result;
                }

                var readiness = await WaitForReadyAsync(probe, service.ServiceName, cancellationToken);
                if (readiness.Success)
                {
                    var result = RuntimeRestartResult.Succeeded("Windows service restarted successfully.");
                    setupLogger?.Info("readyz", $"Daemon reported ready at {probe.ReadyUri}.");
                    LogRuntimeRestart(result, probe.LogPath);
                    return result;
                }

                var failure = RuntimeRestartResult.Failure(
                    "Windows service restart requested, but daemon readiness check failed.",
                    readiness.DiagnosticMessage);
                setupLogger?.Error("readyz", failure.DiagnosticMessage);
                LogRuntimeRestart(failure, probe.LogPath);
                return failure;
            }

            var daemonBinary = Path.Combine(installRoot, "ai-guard-daemon.exe");
            if (!File.Exists(daemonBinary))
            {
                var failure = RuntimeRestartResult.Failure(
                    "Config saved. Restart Ulti Guard manually.",
                    $"No Windows service or daemon binary was found under {installRoot}.");
                LogRuntimeRestart(failure, probe.LogPath);
                return failure;
            }

            var process = new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = daemonBinary,
                    Arguments = $"--config \"{configPath}\" run",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden
                }
            };
            process.Start();
            setupLogger?.Info("service start", $"Launched daemon directly from {daemonBinary}.");

            var directReadiness = await WaitForReadyAsync(probe, null, cancellationToken);
            if (directReadiness.Success)
            {
                var result = RuntimeRestartResult.Succeeded("Daemon relaunched directly.");
                setupLogger?.Info("readyz", $"Daemon reported ready at {probe.ReadyUri}.");
                LogRuntimeRestart(result, probe.LogPath);
                return result;
            }

            var readinessFailure = RuntimeRestartResult.Failure(
                "Daemon launch attempted, but readiness check failed.",
                directReadiness.DiagnosticMessage);
            setupLogger?.Error("readyz", readinessFailure.DiagnosticMessage);
            LogRuntimeRestart(readinessFailure, probe.LogPath);
            return readinessFailure;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            var failure = RuntimeRestartResult.Failure("Ulti Guard restart failed unexpectedly.", ex.Message);
            setupLogger?.Error("service start", "Ulti Guard runtime restart failed unexpectedly.", ex);
            LogRuntimeRestart(failure, probe.LogPath);
            return failure;
        }
    }

    private async Task<ReadinessCheckResult> WaitForReadyAsync(RuntimeProbe probe, string? serviceName, CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.Add(probe.ReadinessTimeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!string.IsNullOrWhiteSpace(serviceName))
            {
                var service = GetServiceOrDefault(serviceName);
                if (service is not null)
                {
                    using (service)
                    {
                        service.Refresh();
                        if (service.Status == ServiceControllerStatus.Stopped)
                        {
                            return ReadinessCheckResult.Failure(
                                $"The Windows service {serviceName} entered the Stopped state before readiness completed at {probe.ReadyUri}.");
                        }
                    }
                }
            }

            try
            {
                using var response = await _httpClient.GetAsync(probe.ReadyUri, cancellationToken);
                if (response.IsSuccessStatusCode)
                {
                    return ReadinessCheckResult.SuccessResult();
                }
            }
            catch
            {
            }

            await Task.Delay(TimeSpan.FromSeconds(1.5), cancellationToken);
        }

        var launcher = string.IsNullOrWhiteSpace(serviceName)
            ? "The daemon process"
            : $"The Windows service {serviceName}";
        return ReadinessCheckResult.Failure(
            $"{launcher} did not report ready at {probe.ReadyUri} within {probe.ReadinessTimeout.TotalSeconds:0} seconds.");
    }

    private static ServiceController? GetServiceOrDefault(string serviceName)
    {
        try
        {
            return ServiceController.GetServices()
                .FirstOrDefault(item => string.Equals(item.ServiceName, serviceName, StringComparison.OrdinalIgnoreCase));
        }
        catch
        {
            return null;
        }
    }

    private static async Task<bool> RestartWindowsServiceAsync(ServiceController service, CancellationToken cancellationToken)
    {
        using (service)
        {
            service.Refresh();
            if (service.Status != ServiceControllerStatus.Stopped)
            {
                service.Stop();
                await WaitForServiceStatusAsync(service, ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(60), cancellationToken);
            }

            service.Start();
            await WaitForServiceStatusAsync(service, ServiceControllerStatus.Running, TimeSpan.FromSeconds(60), cancellationToken);
            return service.Status == ServiceControllerStatus.Running;
        }
    }

    private static async Task WaitForServiceStatusAsync(
        ServiceController service,
        ServiceControllerStatus desiredStatus,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            service.Refresh();
            if (service.Status == desiredStatus)
            {
                return;
            }

            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }
    }

    private static RuntimeProbe LoadRuntimeProbe(string configPath)
    {
        JsonObject root;
        try
        {
            root = AiGuardJson.LoadObject(configPath);
        }
        catch
        {
            return RuntimeProbe.Default;
        }

        var listenAddress = AiGuardJson.GetString(root, "listen_address");
        var readyUri = BuildReadyUri(listenAddress);
        var logPath = BuildAdminConsoleLogPath(configPath, root);
        var readinessTimeout = TimeSpan.FromSeconds(60);
        var managedPiiEnabled = root["managed_pii"]?["enabled"]?.GetValue<bool>() ?? false;
        var startupTimeoutMs = root["managed_pii"]?["startup_timeout_ms"]?.GetValue<int?>() ?? 0;
        if (managedPiiEnabled && startupTimeoutMs > 0)
        {
            var bufferedTimeoutMs = Math.Clamp(startupTimeoutMs + 15000, 60000, 300000);
            readinessTimeout = TimeSpan.FromMilliseconds(bufferedTimeoutMs);
        }

        return new RuntimeProbe(readyUri, readinessTimeout, logPath);
    }

    private static Uri BuildReadyUri(string listenAddress)
    {
        if (string.IsNullOrWhiteSpace(listenAddress))
        {
            return RuntimeProbe.Default.ReadyUri;
        }

        var candidate = listenAddress.Contains("://", StringComparison.Ordinal) ? listenAddress : $"http://{listenAddress}";
        return Uri.TryCreate(candidate, UriKind.Absolute, out var baseUri)
            ? new Uri(baseUri, "/readyz")
            : RuntimeProbe.Default.ReadyUri;
    }

    private static string BuildAdminConsoleLogPath(string configPath, JsonObject root)
    {
        try
        {
            var configDirectory = Path.GetDirectoryName(configPath);
            var loggingDirectory = AiGuardJson.GetString(root, "logging", "directory");
            if (!string.IsNullOrWhiteSpace(loggingDirectory))
            {
                var resolved = Path.IsPathRooted(loggingDirectory)
                    ? loggingDirectory
                    : Path.GetFullPath(Path.Combine(configDirectory ?? AppContext.BaseDirectory, loggingDirectory));
                return Path.Combine(resolved, "admin-console.log");
            }
        }
        catch
        {
        }

        return Path.GetFullPath(Path.Combine(Path.GetDirectoryName(configPath) ?? AppContext.BaseDirectory, "..", "logs", "admin-console.log"));
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
            builder.AppendLine($"[{DateTimeOffset.Now:O}] success={result.Success}");
            builder.AppendLine(result.Message);
            if (!string.IsNullOrWhiteSpace(result.DiagnosticMessage) &&
                !string.Equals(result.DiagnosticMessage, result.Message, StringComparison.Ordinal))
            {
                builder.AppendLine(result.DiagnosticMessage);
            }

            File.AppendAllText(logPath, builder.ToString());
        }
        catch
        {
        }
    }

    private static int GetPortFromListenAddress(string listenAddress)
    {
        if (string.IsNullOrWhiteSpace(listenAddress))
        {
            return 48555;
        }
        var parts = listenAddress.Split(':');
        if (parts.Length > 1 && int.TryParse(parts[parts.Length - 1], out var port))
        {
            return port;
        }
        return 48555;
    }

    private static bool IsPortInUse(int port)
    {
        try
        {
            var properties = IPGlobalProperties.GetIPGlobalProperties();
            var connections = properties.GetActiveTcpListeners();
            foreach (var connection in connections)
            {
                if (connection.Port == port)
                {
                    return true;
                }
            }
        }
        catch
        {
            try
            {
                var socket = new TcpListener(System.Net.IPAddress.Loopback, port);
                socket.Start();
                socket.Stop();
                return false;
            }
            catch
            {
                return true;
            }
        }
        return false;
    }

    private static void ResolvePortConflict(int port, SetupActionLogger? setupLogger)
    {
        if (!IsPortInUse(port))
        {
            return;
        }

        setupLogger?.Warn("port conflict", $"Port {port} is already in use. Attempting to resolve conflict.");

        try
        {
            foreach (var process in Process.GetProcessesByName("ai-guard-daemon"))
            {
                try
                {
                    setupLogger?.Info("port conflict", $"Killing conflicting daemon process: {process.Id}");
                    process.Kill(true);
                    process.WaitForExit(5000);
                }
                catch (Exception ex)
                {
                    setupLogger?.Warn("port conflict", $"Failed to kill daemon process {process.Id}: {ex.Message}");
                }
            }
        }
        catch (Exception ex)
        {
            setupLogger?.Warn("port conflict", $"Failed to list or kill conflicting daemon processes: {ex.Message}");
        }

        if (!IsPortInUse(port))
        {
            setupLogger?.Info("port conflict", $"Port {port} is now free after killing daemon processes.");
            return;
        }

        try
        {
            setupLogger?.Info("port conflict", "Port is still in use. Restarting 'winnat' service to clear zombie sockets.");
            
            var stopInfo = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = "/c net stop winnat",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var stopProc = Process.Start(stopInfo))
            {
                stopProc?.WaitForExit(15000);
            }

            Thread.Sleep(2000);

            var startInfo = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = "/c net start winnat",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var startProc = Process.Start(startInfo))
            {
                startProc?.WaitForExit(15000);
            }

            Thread.Sleep(2000);
        }
        catch (Exception ex)
        {
            setupLogger?.Warn("port conflict", $"Failed to restart winnat service: {ex.Message}");
        }

        if (!IsPortInUse(port))
        {
            setupLogger?.Info("port conflict", $"Port {port} successfully cleared after restarting winnat.");
        }
        else
        {
            setupLogger?.Warn("port conflict", $"Port {port} is still reported in use after winnat restart.");
        }
    }

    private sealed record RuntimeProbe(Uri ReadyUri, TimeSpan ReadinessTimeout, string LogPath)
    {
        public static RuntimeProbe Default { get; } = new(
            new Uri("http://127.0.0.1:48555/readyz"),
            TimeSpan.FromSeconds(60),
            Path.Combine(AppContext.BaseDirectory, "admin-console.log"));
    }

    private sealed record ReadinessCheckResult(bool Success, string DiagnosticMessage)
    {
        public static ReadinessCheckResult SuccessResult() => new(true, string.Empty);

        public static ReadinessCheckResult Failure(string diagnosticMessage) => new(false, diagnosticMessage);
    }
}
