using System.IO;
using System.Windows;
using AIGuard.AdminConsole.Services;

namespace AIGuard.AdminConsole;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(
                args.Exception.Message,
                "Ulti Guard Admin Console",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            args.Handled = true;
            Shutdown(-1);
        };

        if (TryRunSelfTest(e.Args, out var exitCode))
        {
            Shutdown(exitCode);
            return;
        }

        base.OnStartup(e);
    }

    private static bool TryRunSelfTest(string[] args, out int exitCode)
    {
        exitCode = 0;
        if (!args.Any(arg => string.Equals(arg, "--self-test", StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }

        try
        {
            var configService = new ConfigService();
            var explicitConfig = ParseNamedArgument(args, "--config");
            var configPath = configService.ResolveConfigPath(explicitConfig);
            var config = configService.Load(configPath);
            var installRoot = configService.ResolveInstallRoot(configPath);

            foreach (var requiredPath in new[]
            {
                configPath,
                Path.Combine(installRoot, "ai-guard-daemon.exe"),
                Path.Combine(installRoot, "scripts", "apply-browser-policies-from-config.ps1")
            })
            {
                if (!File.Exists(requiredPath))
                {
                    throw new FileNotFoundException($"Required Ulti Guard file was not found: {requiredPath}");
                }
            }

            _ = configService.ResolveSecretPath(configPath, config);
            exitCode = 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            exitCode = 1;
        }

        return true;
    }

    private static string? ParseNamedArgument(IEnumerable<string> args, string name)
    {
        var values = args.ToArray();
        for (var index = 0; index < values.Length - 1; index += 1)
        {
            if (string.Equals(values[index], name, StringComparison.OrdinalIgnoreCase))
            {
                return values[index + 1];
            }
        }

        return null;
    }
}
