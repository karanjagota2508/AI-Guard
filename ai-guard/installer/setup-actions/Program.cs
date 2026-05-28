using System.Text.Json;
using AIGuard.Native.Contracts;
using AIGuard.Native.Services;

var arguments = Environment.GetCommandLineArgs().Skip(1).ToArray();
if (arguments.Length == 0)
{
    Console.Error.WriteLine("Usage: AIGuard.Setup.Actions <install|repair|uninstall|apply-policy|restart-runtime> [options]");
    return 2;
}

var command = arguments[0].Trim().ToLowerInvariant();
var named = ParseNamedArguments(arguments.Skip(1));
var installRoot = ResolveInstallRoot(named);
var configPath = ResolveConfigPath(named, installRoot);

var policyService = new WindowsPolicyService();
var desktopService = new DesktopIntegrationService();
var runtimeService = new RuntimeRestartService();
var materializer = new ConfigMaterializer();
var engine = new NativeInstallEngine(policyService, desktopService, runtimeService, materializer);

switch (command)
{
    case "install":
    case "repair":
    {
        var requestedPort = TryGetInt(named, "daemon-port", 48555);
        var daemonPort = FindFreePort(requestedPort);
        var request = new InstallRequest
        {
            InstallRoot = installRoot,
            PiiPort = TryGetInt(named, "pii-port", 8000),
            DaemonPort = daemonPort,
            ChromeExtensionId = GetOrDefault(named, "chrome-extension-id", "kgfkgellcbbmadimiahbfndmfbhfobko"),
            EdgeExtensionId = GetOrDefault(named, "edge-extension-id", "kgfkgellcbbmadimiahbfndmfbhfobko"),
            ChromeUpdateUrl = GetOrDefault(named, "chrome-update-url", $"http://127.0.0.1:{daemonPort}/update.xml"),
            EdgeUpdateUrl = GetOrDefault(named, "edge-update-url", $"http://127.0.0.1:{daemonPort}/update.xml"),
            ExtensionVersion = GetOrDefault(named, "extension-version", "1.0.4"),
            AllowedExtensionIds = GetList(named, "allowed-extension-id")
        };
        var result = await engine.InstallAsync(request, CancellationToken.None);
        WriteJson(result);
        return result.Success ? 0 : 1;
    }
    case "uninstall":
    {
        var result = await engine.UninstallAsync(new UninstallRequest
        {
            InstallRoot = installRoot,
            KeepFiles = named.ContainsKey("keep-files")
        }, CancellationToken.None);
        WriteJson(result);
        return result.Success ? 0 : 1;
    }
    case "apply-policy":
    {
        var result = await policyService.ApplyFromConfigAsync(configPath, CancellationToken.None);
        WriteJson(result);
        return result.Success ? 0 : 1;
    }
    case "restart-runtime":
    {
        var result = await runtimeService.RestartAsync(installRoot, configPath, CancellationToken.None);
        WriteJson(result);
        return result.Success ? 0 : 1;
    }
    default:
        Console.Error.WriteLine($"Unknown command: {command}");
        return 2;
}

static Dictionary<string, string> ParseNamedArguments(IEnumerable<string> values)
{
    var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    var items = values.ToArray();
    for (var index = 0; index < items.Length; index += 1)
    {
        var current = items[index];
        if (!current.StartsWith("--", StringComparison.Ordinal))
        {
            continue;
        }

        var key = current[2..];
        if (index + 1 < items.Length && !items[index + 1].StartsWith("--", StringComparison.Ordinal))
        {
            result[key] = items[index + 1];
            index += 1;
            continue;
        }

        result[key] = "true";
    }

    return result;
}

static string ResolveInstallRoot(IReadOnlyDictionary<string, string> values)
{
    if (values.TryGetValue("install-root", out var explicitInstallRoot) &&
        !string.IsNullOrWhiteSpace(explicitInstallRoot))
    {
        return NormalizePathValue(explicitInstallRoot);
    }

    if (values.TryGetValue("config", out var explicitConfigPath) &&
        !string.IsNullOrWhiteSpace(explicitConfigPath))
    {
        var configDirectory = Path.GetDirectoryName(NormalizePathValue(explicitConfigPath));
        if (!string.IsNullOrWhiteSpace(configDirectory))
        {
            return Path.GetFullPath(Path.Combine(configDirectory, ".."));
        }
    }

    var executablePath = Environment.ProcessPath;
    var executableDirectory = !string.IsNullOrWhiteSpace(executablePath)
        ? Path.GetDirectoryName(executablePath)
        : AppContext.BaseDirectory;
    if (!string.IsNullOrWhiteSpace(executableDirectory))
    {
        return Path.GetFullPath(Path.Combine(executableDirectory, ".."));
    }

    return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "AI Guard Agent");
}

static string ResolveConfigPath(IReadOnlyDictionary<string, string> values, string installRoot)
{
    if (values.TryGetValue("config", out var explicitConfigPath) &&
        !string.IsNullOrWhiteSpace(explicitConfigPath))
    {
        return NormalizePathValue(explicitConfigPath);
    }

    return Path.Combine(installRoot, "config", "ai-guard.json");
}

static string NormalizePathValue(string value)
{
    var trimmed = value.Trim().Trim('"');
    if (string.IsNullOrWhiteSpace(trimmed))
    {
        return trimmed;
    }

    var root = Path.GetPathRoot(trimmed);
    if (!string.IsNullOrWhiteSpace(root) &&
        string.Equals(trimmed, root, StringComparison.OrdinalIgnoreCase))
    {
        return trimmed;
    }

    trimmed = trimmed.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    return Path.GetFullPath(trimmed);
}

static string GetOrDefault(IReadOnlyDictionary<string, string> values, string key, string defaultValue) =>
    values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value : defaultValue;

static int TryGetInt(IReadOnlyDictionary<string, string> values, string key, int defaultValue) =>
    values.TryGetValue(key, out var value) && int.TryParse(value, out var parsed) ? parsed : defaultValue;

static string[] GetList(IReadOnlyDictionary<string, string> values, string key)
{
    return values.TryGetValue(key, out var value)
        ? value.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        : Array.Empty<string>();
}

static int FindFreePort(int startPort)
{
    for (var port = startPort; port < startPort + 100; port += 1)
    {
        if (!IsPortInUse(port))
        {
            return port;
        }
    }
    return startPort;
}

static bool IsPortInUse(int port)
{
    try
    {
        var properties = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties();
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
            var socket = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
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

static void WriteJson<T>(T value)
{
    Console.WriteLine(JsonSerializer.Serialize(value, new JsonSerializerOptions
    {
        WriteIndented = true
    }));
}
