using Microsoft.Win32;

namespace AIGuard.Native.Internal;

internal static class RegistryStore
{
    public static string? GetString(RegistryHive hive, string keyPath, string name)
    {
        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        using var key = baseKey.OpenSubKey(keyPath, false);
        return key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
    }

    public static int? GetDword(RegistryHive hive, string keyPath, string name)
    {
        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        using var key = baseKey.OpenSubKey(keyPath, false);
        if (key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is null)
        {
            return null;
        }

        return Convert.ToInt32(key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames));
    }

    public static void SetString(RegistryHive hive, string keyPath, string name, string value)
    {
        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        using var key = baseKey.CreateSubKey(keyPath);
        key.SetValue(name, value, RegistryValueKind.String);
    }

    public static void SetDword(RegistryHive hive, string keyPath, string name, int value)
    {
        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        using var key = baseKey.CreateSubKey(keyPath);
        key.SetValue(name, value, RegistryValueKind.DWord);
    }

    public static void RemoveValueIfPresent(RegistryHive hive, string keyPath, string name)
    {
        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        using var key = baseKey.OpenSubKey(keyPath, true);
        key?.DeleteValue(name, false);
    }

    public static void RemoveKeyIfPresent(RegistryHive hive, string keyPath)
    {
        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        try
        {
            baseKey.DeleteSubKeyTree(keyPath, false);
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    public static string[] GetStringList(RegistryHive hive, string keyPath)
    {
        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        using var key = baseKey.OpenSubKey(keyPath, false);
        if (key is null)
        {
            return Array.Empty<string>();
        }

        return key.GetValueNames()
            .Select(name => new
            {
                Name = name,
                Value = key.GetValue(name) as string
            })
            .OrderBy(item => int.TryParse(item.Name, out var order) ? order : int.MaxValue)
            .ThenBy(item => item.Name, StringComparer.OrdinalIgnoreCase)
            .Select(item => item.Value?.Trim())
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Cast<string>()
            .ToArray();
    }

    public static void SaveStringList(RegistryHive hive, string keyPath, IEnumerable<string> values)
    {
        var normalized = values
            .Select(item => item?.Trim())
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .Cast<string>()
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        RemoveKeyIfPresent(hive, keyPath);
        if (normalized.Length == 0)
        {
            return;
        }

        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        using var key = baseKey.CreateSubKey(keyPath);
        for (var index = 0; index < normalized.Length; index += 1)
        {
            key.SetValue((index + 1).ToString(), normalized[index], RegistryValueKind.String);
        }
    }

    public static void UpsertStringListEntry(RegistryHive hive, string keyPath, string value, Func<string, string>? selector = null)
    {
        selector ??= static item => item;
        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        using var key = baseKey.CreateSubKey(keyPath);

        var target = selector(value);
        var match = key.GetValueNames()
            .Select(name => new { Name = name, Value = key.GetValue(name) as string })
            .FirstOrDefault(item => string.Equals(selector(item.Value ?? string.Empty), target, StringComparison.OrdinalIgnoreCase));

        if (match is not null)
        {
            key.SetValue(match.Name, value, RegistryValueKind.String);
            return;
        }

        var next = key.GetValueNames()
            .Select(name => int.TryParse(name, out var index) ? index : 0)
            .DefaultIfEmpty()
            .Max() + 1;

        key.SetValue(next.ToString(), value, RegistryValueKind.String);
    }

    public static void RemoveStringListEntry(RegistryHive hive, string keyPath, string value, Func<string, string>? selector = null)
    {
        selector ??= static item => item;
        using var baseKey = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        using var key = baseKey.OpenSubKey(keyPath, true);
        if (key is null)
        {
            return;
        }

        var target = selector(value);
        foreach (var entry in key.GetValueNames().ToArray())
        {
            var current = key.GetValue(entry) as string ?? string.Empty;
            if (string.Equals(selector(current), target, StringComparison.OrdinalIgnoreCase))
            {
                key.DeleteValue(entry, false);
            }
        }
    }
}
