using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AIGuard.AdminConsole.Services;

internal sealed class AdminSecretStore
{
    private const int DefaultIterations = 150000;

    public bool Exists(string secretPath) => File.Exists(secretPath);

    public SecretPayload Load(string secretPath)
    {
        var protectedBytes = File.ReadAllBytes(secretPath);
        var plainBytes = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.LocalMachine);
        return JsonSerializer.Deserialize<SecretPayload>(plainBytes)
            ?? throw new InvalidOperationException("Admin console secret file is invalid.");
    }

    public void Save(string secretPath, SecretPayload payload)
    {
        var directory = Path.GetDirectoryName(secretPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var plainBytes = JsonSerializer.SerializeToUtf8Bytes(payload, new JsonSerializerOptions
        {
            WriteIndented = false
        });
        var protectedBytes = ProtectedData.Protect(plainBytes, null, DataProtectionScope.LocalMachine);
        File.WriteAllBytes(secretPath, protectedBytes);
    }

    public SecretPayload Create(string password, int iterations)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        return new SecretPayload(
            Convert.ToBase64String(HashPassword(password, salt, iterations)),
            Convert.ToBase64String(salt),
            iterations > 0 ? iterations : DefaultIterations);
    }

    public bool Validate(string password, SecretPayload payload)
    {
        var salt = Convert.FromBase64String(payload.PasswordSalt);
        var candidate = Convert.ToBase64String(HashPassword(password, salt, payload.PasswordIterations));
        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(candidate),
            Encoding.UTF8.GetBytes(payload.PasswordHash));
    }

    private static byte[] HashPassword(string password, byte[] salt, int iterations)
    {
        var effectiveIterations = iterations > 0 ? iterations : DefaultIterations;
        return Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(password),
            salt,
            effectiveIterations,
            HashAlgorithmName.SHA256,
            32);
    }
}

internal sealed record SecretPayload(string PasswordHash, string PasswordSalt, int PasswordIterations);
