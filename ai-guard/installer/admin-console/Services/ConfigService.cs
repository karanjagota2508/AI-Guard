using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIGuard.AdminConsole.Services;

internal sealed class ConfigService
{
    private const string DefaultSecretFileName = "admin-console.secret";
    private const int DefaultIterations = 150000;
    private const int DefaultMinimumPasswordLength = 12;

    public string ResolveConfigPath(string? explicitPath)
    {
        foreach (var candidate in GetConfigCandidates(explicitPath))
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException("Ulti Guard config was not found.");
    }

    public JsonObject Load(string configPath)
    {
        var root = JsonNode.Parse(File.ReadAllText(configPath)) as JsonObject
            ?? throw new InvalidOperationException($"Config file is invalid JSON: {configPath}");

        Normalize(root);
        return root;
    }

    public void Save(string configPath, JsonObject root)
    {
        Normalize(root);
        var json = root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true
        });
        File.WriteAllText(configPath, json);
    }

    public void Normalize(JsonObject root)
    {
        var blocking = root["blocking"] as JsonObject ?? new JsonObject();
        root["blocking"] = blocking;
        blocking["browser_hosts"] = ToSortedUniqueArray(blocking["browser_hosts"], normalizeHost: true);
        blocking["process_names"] = ToSortedUniqueArray(blocking["process_names"], normalizeHost: false);
        blocking["exempt_process_names"] = ToSortedUniqueArray(blocking["exempt_process_names"], normalizeHost: false);

        var adminConsole = root["admin_console"] as JsonObject ?? new JsonObject();
        root["admin_console"] = adminConsole;
        var secretFile = adminConsole["secret_file"]?.GetValue<string>();
        adminConsole["secret_file"] = string.IsNullOrWhiteSpace(secretFile)
            ? DefaultSecretFileName
            : secretFile;
        var passwordIterations = adminConsole["password_iterations"]?.GetValue<int?>() ?? 0;
        adminConsole["password_iterations"] = passwordIterations > 0
            ? passwordIterations
            : DefaultIterations;
        var minimumPasswordLength = adminConsole["minimum_password_length"]?.GetValue<int?>() ?? 0;
        adminConsole["minimum_password_length"] = minimumPasswordLength > 0
            ? minimumPasswordLength
            : DefaultMinimumPasswordLength;

        var pii = root["pii"] as JsonObject ?? new JsonObject();
        root["pii"] = pii;
        if (pii["enabled"] == null)
        {
            pii["enabled"] = true;
        }
        if (pii["confidence_score"] == null)
        {
            pii["confidence_score"] = 0.35;
        }
        if (pii["action"] == null)
        {
            pii["action"] = "redact";
        }
    }

    public bool GetPiiEnabled(JsonObject root) =>
        ((JsonObject)root["pii"]!)["enabled"]?.GetValue<bool>() ?? true;

    public double GetPiiConfidenceScore(JsonObject root) =>
        ((JsonObject)root["pii"]!)["confidence_score"]?.GetValue<double>() ?? 0.35;

    public string GetPiiAction(JsonObject root) =>
        ((JsonObject)root["pii"]!)["action"]?.GetValue<string>() ?? "redact";

    public void SetPiiSettings(JsonObject root, bool enabled, double confidenceScore, string action)
    {
        var pii = (JsonObject)root["pii"]!;
        pii["enabled"] = enabled;
        pii["confidence_score"] = confidenceScore;
        pii["action"] = action.ToLowerInvariant();
    }

    public IReadOnlyList<string> GetBlockedHosts(JsonObject root) =>
        ToStringList(((JsonObject)root["blocking"]!)["browser_hosts"]);

    public IReadOnlyList<string> GetBlockedProcesses(JsonObject root) =>
        ToStringList(((JsonObject)root["blocking"]!)["process_names"]);

    public void SetBlockedHosts(JsonObject root, IEnumerable<string> hosts) =>
        ((JsonObject)root["blocking"]!)["browser_hosts"] = ToSortedUniqueArray(hosts, normalizeHost: true);

    public void SetBlockedProcesses(JsonObject root, IEnumerable<string> processes) =>
        ((JsonObject)root["blocking"]!)["process_names"] = ToSortedUniqueArray(processes, normalizeHost: false);

    public string ResolveInstallRoot(string configPath)
    {
        var configDirectory = Path.GetDirectoryName(configPath)
            ?? throw new InvalidOperationException("Config path has no parent directory.");
        var installRoot = Directory.GetParent(configDirectory)?.FullName;
        return installRoot ?? throw new InvalidOperationException("Install root could not be determined.");
    }

    public bool IsMachineInstall(string configPath)
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return configPath.StartsWith(programFiles, StringComparison.OrdinalIgnoreCase);
    }

    public string ResolveSecretPath(string configPath, JsonObject root)
    {
        var secretFile = ((JsonObject)root["admin_console"]!)["secret_file"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(secretFile))
        {
            secretFile = DefaultSecretFileName;
        }

        var configDirectory = Path.GetDirectoryName(configPath)
            ?? throw new InvalidOperationException("Config path has no parent directory.");
        return Path.IsPathRooted(secretFile)
            ? secretFile
            : Path.Combine(configDirectory, secretFile);
    }

    public int GetPasswordIterations(JsonObject root)
    {
        var iterations = ((JsonObject)root["admin_console"]!)["password_iterations"]?.GetValue<int?>() ?? 0;
        return iterations > 0 ? iterations : DefaultIterations;
    }

    public int GetMinimumPasswordLength(JsonObject root)
    {
        var minimumLength = ((JsonObject)root["admin_console"]!)["minimum_password_length"]?.GetValue<int?>() ?? 0;
        return minimumLength > 0 ? minimumLength : DefaultMinimumPasswordLength;
    }

    public SecretPayload? TryGetLegacySecret(JsonObject root)
    {
        var adminConsole = root["admin_console"] as JsonObject;
        if (adminConsole is null)
        {
            return null;
        }

        var passwordHash = adminConsole["password_hash"]?.GetValue<string>();
        var passwordSalt = adminConsole["password_salt"]?.GetValue<string>();
        var iterations = adminConsole["password_iterations"]?.GetValue<int?>() ?? DefaultIterations;

        if (string.IsNullOrWhiteSpace(passwordHash) || string.IsNullOrWhiteSpace(passwordSalt))
        {
            return null;
        }

        return new SecretPayload(passwordHash, passwordSalt, iterations);
    }

    public void ClearLegacySecret(JsonObject root)
    {
        if (root["admin_console"] is not JsonObject adminConsole)
        {
            return;
        }

        adminConsole.Remove("password_hash");
        adminConsole.Remove("password_salt");
    }

    public string NormalizeHost(string value)
    {
        var text = (value ?? string.Empty).Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(text))
        {
            return string.Empty;
        }

        text = text.Trim('/');
        if (text.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
            text.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            if (Uri.TryCreate(text, UriKind.Absolute, out var uri) && !string.IsNullOrWhiteSpace(uri.Host))
            {
                text = uri.Host.ToLowerInvariant();
            }
        }

        return text.Trim().Trim('.');
    }

    public string NormalizeProcessName(string value) => (value ?? string.Empty).Trim();

    private static IEnumerable<string> GetConfigCandidates(string? explicitPath)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath))
        {
            yield return explicitPath;
        }

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        yield return Path.Combine(programFiles, "AI Guard Agent", "config", "ai-guard.json");
        yield return Path.Combine(programFiles, "Ulti Guard Agent", "config", "ai-guard.json");
        yield return Path.Combine(localAppData, "AI Guard Agent", "config", "ai-guard.json");
        yield return Path.Combine(localAppData, "Ulti Guard Agent", "config", "ai-guard.json");
    }

    private JsonArray ToSortedUniqueArray(JsonNode? source, bool normalizeHost)
    {
        return ToSortedUniqueArray(ToStringList(source), normalizeHost);
    }

    private JsonArray ToSortedUniqueArray(IEnumerable<string> source, bool normalizeHost)
    {
        var values = source
            .Select(item => normalizeHost ? NormalizeHost(item) : NormalizeProcessName(item))
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(item => item, StringComparer.OrdinalIgnoreCase)
            .Select(item => JsonValue.Create(item))
            .ToArray();

        return new JsonArray(values);
    }

    private static IReadOnlyList<string> ToStringList(JsonNode? source)
    {
        if (source is not JsonArray items)
        {
            return Array.Empty<string>();
        }

        return items
            .Select(item => item?.GetValue<string>())
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Cast<string>()
            .ToArray();
    }
}
