using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Media.Imaging;

namespace AIGuard.Setup;

public partial class MainWindow : Window
{
    private const string PayloadResourceName = "AIGuardSetup.Payload.zip";
    private const string BrandLogoResourceName = "AIGuardSetup.BrandLogo.png";
    private const string InstallScriptRelativePath = "install-enterprise.ps1";
    private const string UninstallScriptRelativePath = "uninstall.ps1";
    private const string BootstrapperResultMarker = "ULTI_GUARD_BOOTSTRAPPER_RESULT::";
    private const string ResumeActionArgument = "--resume-action";
    private bool _busy;
    private bool _finishActionInProgress;
    private readonly PendingSetupOperation _startupOperation;
    private bool _startupOperationHandled;
    private PendingFinishAction _pendingFinishAction = PendingFinishAction.None;
    private string? _pendingCompletionInstallRoot;
    private bool _forceClose;

    public MainWindow()
    {
        InitializeComponent();
        LogoImage.Source = LoadBrandLogo();
        ProgressBar.Minimum = 0;
        ProgressBar.Maximum = 100;
        ProgressBar.Value = 0;
        HideCompletionScreen();
        ApplyBuildMarker();
        _startupOperation = ParseStartupOperation(Environment.GetCommandLineArgs().Skip(1));
        InstallButton.Content = IsInstalled() ? "Repair / Upgrade" : "Install";
        AppendLog("Ulti Guard setup is ready.");
        AppendLog($"Build marker: {BuildInfoTextBlock.Text}");
        AppendLog("This setup always runs in enterprise mode and does not require PowerShell commands from the end user.");
        Closing += MainWindow_Closing;
        ContentRendered += MainWindow_ContentRendered;
    }

    private async void InstallButton_Click(object sender, RoutedEventArgs e)
    {
        await StartInstallAsync(resumedFromElevation: false);
    }

    private async void UninstallButton_Click(object sender, RoutedEventArgs e)
    {
        await StartUninstallAsync(resumedFromElevation: false);
    }

    private async void MainWindow_ContentRendered(object? sender, EventArgs e)
    {
        if (_startupOperationHandled || _startupOperation == PendingSetupOperation.None)
        {
            return;
        }

        _startupOperationHandled = true;
        BringWindowToFront();

        switch (_startupOperation)
        {
            case PendingSetupOperation.Install:
                AppendLog("Administrator approval accepted. Continuing installation automatically.");
                await StartInstallAsync(resumedFromElevation: true);
                break;
            case PendingSetupOperation.Uninstall:
                AppendLog("Administrator approval accepted. Continuing uninstall automatically.");
                await StartUninstallAsync(resumedFromElevation: true);
                break;
        }
    }

    private async Task StartInstallAsync(bool resumedFromElevation)
    {
        if (!IsAdministrator())
        {
            await RelaunchElevatedAsync(PendingSetupOperation.Install);
            return;
        }

        await RunScriptAsync(
            actionName: "installation",
            scriptRelativePath: InstallScriptRelativePath,
            arguments: ["-PiiPort", "8000", "-SkipBuild"],
            operation: ScriptOperation.Install);
    }

    private async Task StartUninstallAsync(bool resumedFromElevation)
    {
        if (!resumedFromElevation)
        {
            var result = MessageBox.Show(
                this,
                "This will remove the machine-wide Ulti Guard installation from this PC.\n\nContinue?",
                "Ulti Guard Setup",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

            if (result != MessageBoxResult.Yes)
            {
                return;
            }
        }

        if (!IsAdministrator())
        {
            await RelaunchElevatedAsync(PendingSetupOperation.Uninstall);
            return;
        }

        var installRoot = GetCandidateInstallRoots().FirstOrDefault(IsInstallRootPresent)
            ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "AI Guard Agent");

        await RunScriptAsync(
            actionName: "uninstall",
            scriptRelativePath: UninstallScriptRelativePath,
            arguments: ["-InstallRoot", installRoot],
            operation: ScriptOperation.Uninstall);
    }

    private async Task RunScriptAsync(
        string actionName,
        string scriptRelativePath,
        IReadOnlyList<string> arguments,
        ScriptOperation operation)
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        SetButtonsEnabled(false);
        ProgressBar.IsIndeterminate = true;
        var extractionRoot = string.Empty;
        var showCompletionScreen = false;
        InstallerContract? completedContract = null;
        string? completedInstallRoot = null;

        try
        {
            extractionRoot = ExtractPayload();
            var installerRoot = Path.Combine(extractionRoot, "ai-guard", "installer");
            if (!Directory.Exists(installerRoot))
            {
                throw new DirectoryNotFoundException($"Required installer payload directory was not found: {installerRoot}");
            }

            var scriptPath = Path.Combine(installerRoot, scriptRelativePath);
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException($"Required installer script was not found inside the setup payload: {scriptPath}");
            }

            AppendLog($"Starting {actionName}.");
            AppendLog($"Payload extracted to: {extractionRoot}");
            AppendLog($"Running extracted setup file: {Path.GetFileName(scriptPath)}");

            var resultPath = Path.Combine(
                extractionRoot,
                $"ulti-guard-{operation.ToString().ToLowerInvariant()}-result.json");

            InstallerContract? contract = null;
            var exitCode = 0;
            const int maxAttempts = 3;

            for (var attempt = 1; attempt <= maxAttempts; attempt++)
            {
                if (File.Exists(resultPath))
                {
                    File.Delete(resultPath);
                }

                exitCode = await RunPowerShellFileAsync(scriptPath, arguments, installerRoot, resultPath);

                try
                {
                    contract = await WaitForContractAsync(resultPath, installerRoot, TimeSpan.FromSeconds(3));
                    if (contract is null)
                    {
                        throw new InvalidOperationException(GetMissingContractMessage(actionName, exitCode));
                    }

                    LogContract(contract);
                    ValidateContract(operation, exitCode, contract);
                    break;
                }
                catch (InvalidOperationException ex) when (
                    attempt < maxAttempts &&
                    ShouldRetryOperationAttempt(ex, contract))
                {
                    AppendLog($"Ulti Guard setup hit a transient failure. Retrying {actionName} ({attempt}/{maxAttempts})...");
                    await Task.Delay(TimeSpan.FromSeconds(attempt * 2));
                    continue;
                }
            }

            if (contract is null)
            {
                throw new InvalidOperationException($"Ulti Guard {actionName} did not return a result contract.");
            }

            if (operation == ScriptOperation.Install && !IsInstalled())
            {
                throw new InvalidOperationException("Ulti Guard reported success, but the installed product markers were not found on disk.");
            }

            AppendLog($"{actionName} completed successfully with status '{contract.Status}'.");
            InstallButton.Content = IsInstalled() ? "Repair / Upgrade" : "Install";

            ResetOperationState();
            completedInstallRoot = ResolveInstallRoot(contract.InstallRoot);
            completedContract = contract;
            showCompletionScreen = true;
        }
        catch (Exception ex)
        {
            AppendLog($"ERROR: {ex.Message}");
            AppendLog(ex.ToString());
            MessageBox.Show(
                this,
                ex.Message,
                "Ulti Guard Setup",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        finally
        {
            TryDeleteDirectory(extractionRoot);
            if (_busy)
            {
                ResetOperationState();
            }
        }

        if (showCompletionScreen && completedContract is not null)
        {
            AppendLog($"{actionName} completed; showing finish screen.");
            ShowCompletionScreen(operation, completedContract, completedInstallRoot);
        }
    }

    private async Task<int> RunPowerShellFileAsync(
        string scriptPath,
        IReadOnlyList<string> arguments,
        string installerRoot,
        string resultPath)
    {
        var outputLines = new ConcurrentQueue<string>();
        var errorLines = new ConcurrentQueue<string>();

        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = installerRoot,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }
        startInfo.ArgumentList.Add("-BootstrapResultPath");
        startInfo.ArgumentList.Add(resultPath);
        startInfo.Environment["ULTI_GUARD_INSTALLER_ROOT"] = installerRoot;

        using var process = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true
        };
        process.OutputDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data))
            {
                outputLines.Enqueue(args.Data);
                AppendLog(args.Data);
            }
        };
        process.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data))
            {
                errorLines.Enqueue(args.Data);
                AppendLog($"ERR: {args.Data}");
            }
        };

        if (!process.Start())
        {
            throw new InvalidOperationException("Failed to start PowerShell for Ulti Guard setup.");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync();
        process.WaitForExit();

        _lastOutputLines = outputLines.ToArray();
        _lastErrorLines = errorLines.ToArray();
        return process.ExitCode;
    }

    private string[] _lastOutputLines = Array.Empty<string>();
    private string[] _lastErrorLines = Array.Empty<string>();

    private InstallerContract? ReadContract(string resultPath, string installerRoot)
    {
        if (File.Exists(resultPath))
        {
            var json = File.ReadAllText(resultPath, Encoding.UTF8);
            return DeserializeContract(json);
        }

        var markerLine = _lastOutputLines
            .Reverse()
            .FirstOrDefault(line => line.StartsWith(BootstrapperResultMarker, StringComparison.Ordinal));

        if (markerLine is null)
        {
            return null;
        }

        var jsonPayload = markerLine[BootstrapperResultMarker.Length..];
        return DeserializeContract(jsonPayload);
    }

    private static InstallerContract? DeserializeContract(string json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }

        return JsonSerializer.Deserialize<InstallerContract>(
            json,
            new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });
    }

    private void LogContract(InstallerContract contract)
    {
        AppendLog($"Result status: {contract.Status}");
        if (!string.IsNullOrWhiteSpace(contract.InstallRoot))
        {
            AppendLog($"Reported install root: {contract.InstallRoot}");
        }

        if (!string.IsNullOrWhiteSpace(contract.PrivateModeStrategy))
        {
            AppendLog($"Private mode strategy: {contract.PrivateModeStrategy}");
        }

        AppendLog($"Chrome ready: {contract.ChromeReady}");
        AppendLog($"Edge ready: {contract.EdgeReady}");

        foreach (var warning in contract.Warnings ?? [])
        {
            AppendLog($"WARNING: {warning}");
        }

        foreach (var error in contract.Errors ?? [])
        {
            AppendLog($"ERROR: {error}");
        }
    }

    private void ValidateContract(ScriptOperation operation, int exitCode, InstallerContract contract)
    {
        var status = contract.Status?.Trim().ToLowerInvariant();
        var allowedStatuses = operation == ScriptOperation.Install
            ? new[] { "installed", "installed_with_warning" }
            : new[] { "uninstalled", "not_found" };

        if (status == "failed")
        {
            throw new InvalidOperationException(GetFailureMessage(contract, exitCode));
        }

        if (exitCode != 0)
        {
            throw new InvalidOperationException(GetFailureMessage(contract, exitCode));
        }

        if (string.IsNullOrWhiteSpace(status) || !allowedStatuses.Contains(status, StringComparer.Ordinal))
        {
            throw new InvalidOperationException(
                $"Ulti Guard returned an unexpected result status '{contract.Status ?? "<empty>"}' for {operation.ToString().ToLowerInvariant()}.");
        }
    }

    private string GetFailureMessage(InstallerContract contract, int exitCode)
    {
        var builder = new StringBuilder();
        if (!string.IsNullOrWhiteSpace(contract.Message))
        {
            builder.Append(contract.Message.Trim());
        }
        else
        {
            builder.Append($"Ulti Guard setup failed with exit code {exitCode}.");
        }

        var errors = contract.Errors ?? Array.Empty<string>();
        if (errors.Length > 0)
        {
            builder.AppendLine();
            builder.AppendLine();
            builder.Append("Errors:");
            foreach (var error in errors.Where(item => !string.IsNullOrWhiteSpace(item)))
            {
                builder.AppendLine();
                builder.Append("- ");
                builder.Append(error.Trim());
            }
        }
        else if (_lastErrorLines.Length > 0)
        {
            builder.AppendLine();
            builder.AppendLine();
            builder.Append("PowerShell error:");
            builder.AppendLine();
            builder.Append(_lastErrorLines.Last());
        }

        return builder.ToString();
    }

    private static string BuildCompletionMessage(InstallerContract contract)
    {
        var message = string.IsNullOrWhiteSpace(contract.Message)
            ? "Ulti Guard operation completed."
            : contract.Message.Trim();

        var details = new List<string>();
        var status = contract.Status?.Trim().ToLowerInvariant();
        if (status is "installed" or "installed_with_warning")
        {
            details.Add($"Chrome managed extension ready: {(contract.ChromeReady ? "Yes" : "No")}");
            details.Add($"Edge managed extension ready: {(contract.EdgeReady ? "Yes" : "No")}");

            if (!string.IsNullOrWhiteSpace(contract.PrivateModeStrategy))
            {
                details.Add($"Private browsing policy: {contract.PrivateModeStrategy.Trim()}");
            }
        }

        var warnings = contract.Warnings?
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .ToArray() ?? Array.Empty<string>();

        if (warnings.Length == 0 && details.Count == 0)
        {
            return message;
        }

        var lines = new List<string> { message };
        if (details.Count > 0)
        {
            lines.Add(string.Empty);
            lines.Add("Readiness:");
            lines.AddRange(details.Select(item => $"- {item}"));
        }

        if (warnings.Length > 0)
        {
            lines.Add(string.Empty);
            lines.Add("Warnings:");
            lines.AddRange(warnings.Select(item => $"- {item.Trim()}"));
        }

        return string.Join(Environment.NewLine, lines);
    }

    private static MessageBoxImage GetDialogImage(string? status) =>
        string.Equals(status, "installed_with_warning", StringComparison.OrdinalIgnoreCase)
            ? MessageBoxImage.Warning
            : MessageBoxImage.Information;

    private void ShowCompletionScreen(ScriptOperation operation, InstallerContract contract, string? installRoot)
    {
        var isInstall = operation == ScriptOperation.Install;
        var hasWarnings = string.Equals(contract.Status, "installed_with_warning", StringComparison.OrdinalIgnoreCase);
        _pendingFinishAction = isInstall ? PendingFinishAction.OpenAdminConsole : PendingFinishAction.CloseSetup;
        _pendingCompletionInstallRoot = installRoot;
        _finishActionInProgress = false;

        FinishTitleTextBlock.Text = isInstall
            ? "Ulti Guard installation completed"
            : "Ulti Guard uninstall completed";
        FinishMessageTextBlock.Text = BuildCompletionMessage(contract);
        FinishBuildInfoTextBlock.Text = BuildInfoTextBlock.Text;
        FinishHintTextBlock.Text = isInstall
            ? "Click Finish to open Ulti Guard Admin Console."
            : "Click Finish to close Ulti Guard Setup.";
        FinishBusyTextBlock.Text = isInstall
            ? "Opening Ulti Guard Admin Console..."
            : "Closing Ulti Guard Setup...";
        FinishWarningTextBlock.Text = hasWarnings
            ? "Installation finished with warnings. Review the readiness details below before closing setup."
            : string.Empty;
        FinishWarningBanner.Visibility = hasWarnings ? Visibility.Visible : Visibility.Collapsed;
        FinishBusyPanel.Visibility = Visibility.Collapsed;
        FinishButton.IsEnabled = true;

        SetupContentGrid.Visibility = Visibility.Collapsed;
        FinishOverlayGrid.Visibility = Visibility.Visible;
        BringWindowToFront();
    }

    private void HideCompletionScreen()
    {
        _pendingFinishAction = PendingFinishAction.None;
        _pendingCompletionInstallRoot = null;
        _finishActionInProgress = false;
        if (FinishOverlayGrid is not null)
        {
            FinishOverlayGrid.Visibility = Visibility.Collapsed;
        }
        if (SetupContentGrid is not null)
        {
            SetupContentGrid.Visibility = Visibility.Visible;
        }
    }

    private async void FinishButton_Click(object sender, RoutedEventArgs e)
    {
        if (_finishActionInProgress)
        {
            return;
        }

        _finishActionInProgress = true;
        FinishButton.IsEnabled = false;
        FinishHintTextBlock.Visibility = Visibility.Collapsed;
        FinishBusyPanel.Visibility = Visibility.Visible;
        await Task.Delay(350);

        if (_pendingFinishAction == PendingFinishAction.OpenAdminConsole)
        {
            AppendLog("Opening Ulti Guard Admin Console.");
            try
            {
                TryLaunchAdminConsole(_pendingCompletionInstallRoot);
            }
            catch (Exception ex)
            {
                AppendLog($"WARNING: Failed to launch Admin Console: {ex.Message}");
            }
        }

        AppendLog("Closing Ulti Guard Setup.");
        _forceClose = true;
        Close();
        try
        {
            Application.Current.Shutdown();
        }
        catch
        {
            Environment.Exit(0);
        }
        return;
    }

    private bool TryLaunchAdminConsole(string? installRoot)
    {
        var resolvedInstallRoot = ResolveInstallRoot(installRoot);
        if (string.IsNullOrWhiteSpace(resolvedInstallRoot))
        {
            MessageBox.Show(
                this,
                "Ulti Guard finished installing, but the installed Admin Console location could not be resolved.",
                "Ulti Guard Setup",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return false;
        }

        var adminConsolePath = Path.Combine(resolvedInstallRoot, "admin-console", "AI-Guard-Admin-Console.exe");
        var configPath = Path.Combine(resolvedInstallRoot, "config", "ai-guard.json");
        if (!File.Exists(adminConsolePath))
        {
            MessageBox.Show(
                this,
                $"Ulti Guard finished installing, but the Admin Console executable was not found at:{Environment.NewLine}{adminConsolePath}",
                "Ulti Guard Setup",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return false;
        }

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = adminConsolePath,
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(adminConsolePath) ?? resolvedInstallRoot
            };

            if (File.Exists(configPath))
            {
                startInfo.ArgumentList.Add("--config");
                startInfo.ArgumentList.Add(configPath);
            }

            Process.Start(startInfo);
            return true;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                $"Ulti Guard installed successfully, but the Admin Console could not be opened automatically.{Environment.NewLine}{Environment.NewLine}{ex.Message}",
                "Ulti Guard Setup",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return false;
        }
    }

    private static string? ResolveInstallRoot(string? preferredInstallRoot)
    {
        if (IsInstallRootPresent(preferredInstallRoot ?? string.Empty))
        {
            return preferredInstallRoot;
        }

        return GetCandidateInstallRoots().FirstOrDefault(IsInstallRootPresent);
    }

    private static bool IsRetryableFileLockFailure(string message, InstallerContract? contract)
    {
        if (ContainsFileLockText(message))
        {
            return true;
        }

        if (contract is null)
        {
            return false;
        }

        if (ContainsFileLockText(contract.Message))
        {
            return true;
        }

        return (contract.Errors ?? Array.Empty<string>()).Any(ContainsFileLockText);
    }

    private bool ShouldRetryOperationAttempt(Exception ex, InstallerContract? contract)
    {
        if (IsRetryableFileLockFailure(ex.Message, contract))
        {
            return true;
        }

        return ex.Message.Contains("did not return a result contract", StringComparison.OrdinalIgnoreCase);
    }

    private static bool ContainsFileLockText(string? value) =>
        !string.IsNullOrWhiteSpace(value) &&
        (value.Contains("cannot access the file", StringComparison.OrdinalIgnoreCase) ||
         value.Contains("being used by another process", StringComparison.OrdinalIgnoreCase));

    private async Task<InstallerContract?> WaitForContractAsync(string resultPath, string installerRoot, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow.Add(timeout);
        InstallerContract? contract = null;

        do
        {
            contract = ReadContract(resultPath, installerRoot);
            if (contract is not null)
            {
                return contract;
            }

            await Task.Delay(250);
        }
        while (DateTime.UtcNow < deadline);

        return ReadContract(resultPath, installerRoot);
    }

    private string GetMissingContractMessage(string actionName, int exitCode)
    {
        var builder = new StringBuilder();
        builder.Append($"Ulti Guard {actionName} did not return a result contract.");

        if (exitCode != 0)
        {
            builder.Append($" PowerShell exited with code {exitCode}.");
        }

        if (_lastErrorLines.Length > 0)
        {
            builder.AppendLine();
            builder.AppendLine();
            builder.Append("PowerShell error:");
            builder.AppendLine();
            builder.Append(_lastErrorLines.Last());
        }
        else if (_lastOutputLines.Length > 0)
        {
            builder.AppendLine();
            builder.AppendLine();
            builder.Append("Last output:");
            builder.AppendLine();
            builder.Append(_lastOutputLines.Last());
        }

        return builder.ToString();
    }

    private static string ExtractPayload()
    {
        var extractionRoot = Path.Combine(Path.GetTempPath(), "Ulti-Guard-Setup", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(extractionRoot);

        var assembly = Assembly.GetExecutingAssembly();
        using var payloadStream = assembly.GetManifestResourceStream(PayloadResourceName)
            ?? throw new InvalidOperationException("Embedded Ulti Guard payload was not found inside the setup executable.");
        using var archive = new ZipArchive(payloadStream, ZipArchiveMode.Read);
        archive.ExtractToDirectory(extractionRoot, overwriteFiles: true);
        return extractionRoot;
    }

    private async Task RelaunchElevatedAsync(PendingSetupOperation operation)
    {
        try
        {
            using var currentProcess = Process.GetCurrentProcess();
            var startInfo = new ProcessStartInfo
            {
                FileName = currentProcess.MainModule?.FileName ?? Environment.ProcessPath!,
                UseShellExecute = true,
                Verb = "runas",
                Arguments = $"{ResumeActionArgument} {operation.ToString().ToLowerInvariant()}"
            };

            AppendLog("Administrator approval is required. Approve the Windows prompt to continue automatically.");
            var elevatedProcess = Process.Start(startInfo);
            if (elevatedProcess is null)
            {
                throw new InvalidOperationException("Windows did not start the elevated Ulti Guard Setup process.");
            }

            await Task.Delay(TimeSpan.FromSeconds(2));
            var processExitedEarly = false;
            try
            {
                processExitedEarly = elevatedProcess.HasExited;
            }
            catch (InvalidOperationException)
            {
            }

            if (processExitedEarly)
            {
                throw new InvalidOperationException("The elevated Ulti Guard Setup process exited before it could continue the requested action.");
            }

            AppendLog("Elevated Ulti Guard Setup is running. This window will close now.");
            Close();
        }
        catch (System.ComponentModel.Win32Exception ex) when ((uint)ex.NativeErrorCode == 1223)
        {
            MessageBox.Show(
                this,
                "Administrator approval was cancelled. Ulti Guard did not start the requested action.",
                "Ulti Guard Setup",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                $"Administrator approval is required to continue.\n\n{ex.Message}",
                "Ulti Guard Setup",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }

    }

    private static PendingSetupOperation ParseStartupOperation(IEnumerable<string> arguments)
    {
        var values = arguments.ToArray();
        for (var index = 0; index < values.Length; index++)
        {
            if (!string.Equals(values[index], ResumeActionArgument, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (index + 1 >= values.Length)
            {
                return PendingSetupOperation.None;
            }

            return values[index + 1].Trim().ToLowerInvariant() switch
            {
                "install" => PendingSetupOperation.Install,
                "uninstall" => PendingSetupOperation.Uninstall,
                _ => PendingSetupOperation.None
            };
        }

        return PendingSetupOperation.None;
    }

    private void BringWindowToFront()
    {
        try
        {
            Topmost = true;
            Activate();
            Focus();
        }
        finally
        {
            Topmost = false;
        }
    }

    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static bool IsInstalled()
    {
        foreach (var candidate in GetCandidateInstallRoots())
        {
            if (IsInstallRootPresent(candidate))
            {
                return true;
            }
        }

        return false;
    }

    private static IEnumerable<string> GetCandidateInstallRoots()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        yield return Path.Combine(programFiles, "AI Guard Agent");
        yield return Path.Combine(programFiles, "Ulti Guard Agent");
        yield return Path.Combine(localAppData, "AI Guard Agent");
        yield return Path.Combine(localAppData, "Ulti Guard Agent");
    }

    private static bool IsInstallRootPresent(string installRoot)
    {
        if (string.IsNullOrWhiteSpace(installRoot) || !Directory.Exists(installRoot))
        {
            return false;
        }

        var markerPaths = new[]
        {
            "ai-guard-daemon.exe",
            Path.Combine("config", "ai-guard.json"),
            Path.Combine("dist", "ai-guard-extension.crx"),
            Path.Combine("admin-console", "AI-Guard-Admin-Console.exe")
        };

        return markerPaths.All(relativePath => File.Exists(Path.Combine(installRoot, relativePath)));
    }

    private void SetButtonsEnabled(bool enabled)
    {
        InstallButton.IsEnabled = enabled;
        UninstallButton.IsEnabled = enabled;
        CloseButton.IsEnabled = enabled;
    }

    private void AppendLog(string message)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(new Action(() => AppendLog(message)));
            return;
        }

        LogTextBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}");
        LogTextBox.ScrollToEnd();
    }

    private void ApplyBuildMarker()
    {
        var buildMarker = GetBuildMarker();
        BuildInfoTextBlock.Text = buildMarker;
        if (FinishBuildInfoTextBlock is not null)
        {
            FinishBuildInfoTextBlock.Text = buildMarker;
        }
    }

    private static string GetBuildMarker()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var version = assembly.GetName().Version?.ToString() ?? "1.0.0.0";
        var executablePath = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(executablePath) && File.Exists(executablePath))
        {
            var timestamp = File.GetLastWriteTime(executablePath).ToString("yyyy-MM-dd HH:mm");
            return $"Build {version} · {timestamp}";
        }

        return $"Build {version}";
    }

    private void ResetOperationState()
    {
        ProgressBar.IsIndeterminate = false;
        ProgressBar.Value = 0;
        SetButtonsEnabled(true);
        _busy = false;
    }

    private static BitmapSource? LoadBrandLogo()
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(BrandLogoResourceName);
        if (stream is null)
        {
            return null;
        }

        var memoryStream = new MemoryStream();
        stream.CopyTo(memoryStream);
        memoryStream.Position = 0;

        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = memoryStream;
        image.EndInit();
        image.Freeze();
        return image;
    }

    private static void TryDeleteDirectory(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
        {
            return;
        }

        try
        {
            Directory.Delete(path, recursive: true);
        }
        catch
        {
        }
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_forceClose)
        {
            return;
        }
        if (FinishOverlayGrid.Visibility == Visibility.Visible &&
            _pendingFinishAction != PendingFinishAction.None &&
            !_finishActionInProgress)
        {
            e.Cancel = true;
            MessageBox.Show(
                this,
                "Use the Finish button to complete Ulti Guard Setup.",
                "Ulti Guard Setup",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        if (_busy || _finishActionInProgress)
        {
            e.Cancel = true;
            MessageBox.Show(
                this,
                "Setup is still running. Wait for the current operation to finish before closing this window.",
                "Ulti Guard Setup",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
    }
}

internal enum ScriptOperation
{
    Install,
    Uninstall
}

internal enum PendingSetupOperation
{
    None,
    Install,
    Uninstall
}

internal enum PendingFinishAction
{
    None,
    OpenAdminConsole,
    CloseSetup
}

internal sealed class InstallerContract
{
    [JsonPropertyName("status")]
    public string Status { get; set; } = string.Empty;
    [JsonPropertyName("message")]
    public string Message { get; set; } = string.Empty;
    [JsonPropertyName("install_root")]
    public string InstallRoot { get; set; } = string.Empty;
    [JsonPropertyName("scope")]
    public string Scope { get; set; } = string.Empty;
    [JsonPropertyName("warnings")]
    public string[] Warnings { get; set; } = Array.Empty<string>();
    [JsonPropertyName("errors")]
    public string[] Errors { get; set; } = Array.Empty<string>();
    [JsonPropertyName("chrome_ready")]
    public bool ChromeReady { get; set; }
    [JsonPropertyName("edge_ready")]
    public bool EdgeReady { get; set; }
    [JsonPropertyName("private_mode_strategy")]
    public string PrivateModeStrategy { get; set; } = string.Empty;
}
