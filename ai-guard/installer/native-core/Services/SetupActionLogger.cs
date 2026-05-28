using System.Text;

namespace AIGuard.Native.Services;

public sealed class SetupActionLogger
{
    private readonly object _gate = new();

    public SetupActionLogger(string installRoot)
    {
        if (string.IsNullOrWhiteSpace(installRoot))
        {
            throw new InvalidOperationException("InstallRoot is required for setup logging.");
        }

        LogPath = Path.Combine(installRoot, "logs", "setup-actions.log");
        Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
    }

    public string LogPath { get; }

    public void Info(string phase, string message) => Write("INFO", phase, message);

    public void Warn(string phase, string message) => Write("WARN", phase, message);

    public void Error(string phase, string message, Exception? exception = null)
    {
        var builder = new StringBuilder(message);
        if (exception is not null)
        {
            builder.Append(' ');
            builder.Append(exception.Message);
        }

        Write("ERROR", phase, builder.ToString());

        if (exception is not null)
        {
            Write("ERROR", phase, exception.ToString());
        }
    }

    private void Write(string level, string phase, string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return;
        }

        var entry = $"[{DateTimeOffset.Now:O}] [{level}] [{phase}] {message}{Environment.NewLine}";
        lock (_gate)
        {
            File.AppendAllText(LogPath, entry, Encoding.UTF8);
        }
    }
}
