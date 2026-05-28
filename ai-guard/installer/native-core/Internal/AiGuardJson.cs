using System.Text.Json;
using System.Text.Json.Nodes;

namespace AIGuard.Native.Internal;

internal static class AiGuardJson
{
    public static JsonObject LoadObject(string path)
    {
        var root = JsonNode.Parse(File.ReadAllText(path)) as JsonObject;
        if (root is null)
        {
            throw new InvalidOperationException($"Config file is invalid JSON: {path}");
        }

        return root;
    }

    public static string GetString(JsonObject root, params string[] path)
    {
        var node = GetNode(root, path);
        return node?.GetValue<string>()?.Trim() ?? string.Empty;
    }

    public static string[] GetStringArray(JsonObject root, params string[] path)
    {
        var node = GetNode(root, path) as JsonArray;
        if (node is null)
        {
            return Array.Empty<string>();
        }

        return node
            .Select(item => item?.GetValue<string>()?.Trim())
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Cast<string>()
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static void SetString(JsonObject root, string value, params string[] path)
    {
        if (path.Length == 0)
        {
            throw new ArgumentException("JSON path is required.", nameof(path));
        }

        var current = root;
        for (var index = 0; index < path.Length - 1; index += 1)
        {
            if (current[path[index]] is not JsonObject child)
            {
                child = new JsonObject();
                current[path[index]] = child;
            }

            current = child;
        }

        current[path[^1]] = value;
    }

    public static void SaveIndented(string path, JsonObject root)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var json = root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true
        });
        File.WriteAllText(path, json);
    }

    private static JsonNode? GetNode(JsonObject root, params string[] path)
    {
        JsonNode? current = root;
        foreach (var segment in path)
        {
            current = current?[segment];
            if (current is null)
            {
                return null;
            }
        }

        return current;
    }
}
