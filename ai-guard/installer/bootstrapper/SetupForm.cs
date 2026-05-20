using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace AIGuardSetup;

internal sealed class SetupForm : Form
{
    private const string InstallScriptRelativePath = @"ai-guard\installer\install-enterprise.ps1";
    private const string UninstallScriptRelativePath = @"ai-guard\installer\uninstall.ps1";
    private const string PayloadResourceName = "AIGuardSetup.Payload.zip";

    private readonly Label _titleLabel;
    private readonly Label _subtitleLabel;
    private readonly Label _warningLabel;
    private readonly RichTextBox _logBox;
    private readonly Button _installButton;
    private readonly Button _uninstallButton;
    private readonly Button _closeButton;
    private readonly ProgressBar _progressBar;

    private bool _busy;

    public SetupForm()
    {
        Text = "AI Guard Agent Setup";
        StartPosition = FormStartPosition.CenterScreen;
        Size = new System.Drawing.Size(860, 620);
        MinimumSize = new System.Drawing.Size(860, 620);
        MaximizeBox = false;
        BackColor = System.Drawing.Color.FromArgb(247, 248, 251);

        _titleLabel = new Label
        {
            Text = "AI Guard Agent Setup",
            Font = new System.Drawing.Font("Segoe UI Semibold", 20, System.Drawing.FontStyle.Bold),
            Location = new System.Drawing.Point(22, 18),
            AutoSize = true
        };
        Controls.Add(_titleLabel);

        _subtitleLabel = new Label
        {
            Text = "Installs the daemon service, managed browser extension, Claude Desktop guard, bundled PII agent, and admin console.",
            Font = new System.Drawing.Font("Segoe UI", 10),
            Location = new System.Drawing.Point(24, 58),
            Size = new System.Drawing.Size(790, 40)
        };
        Controls.Add(_subtitleLabel);

        _warningLabel = new Label
        {
            Text = BuildWarningText(),
            Font = new System.Drawing.Font("Segoe UI", 9),
            ForeColor = System.Drawing.Color.FromArgb(120, 84, 0),
            BackColor = System.Drawing.Color.FromArgb(255, 243, 205),
            BorderStyle = BorderStyle.FixedSingle,
            Location = new System.Drawing.Point(24, 106),
            Size = new System.Drawing.Size(790, 46),
            Padding = new Padding(8, 6, 8, 6)
        };
        Controls.Add(_warningLabel);

        _logBox = new RichTextBox
        {
            Location = new System.Drawing.Point(24, 170),
            Size = new System.Drawing.Size(790, 320),
            ReadOnly = true,
            Font = new System.Drawing.Font("Consolas", 10),
            BackColor = System.Drawing.Color.White,
            BorderStyle = BorderStyle.FixedSingle,
            WordWrap = false
        };
        Controls.Add(_logBox);

        _progressBar = new ProgressBar
        {
            Location = new System.Drawing.Point(24, 504),
            Size = new System.Drawing.Size(790, 18),
            Style = ProgressBarStyle.Blocks
        };
        Controls.Add(_progressBar);

        _installButton = new Button
        {
            Text = IsInstalled() ? "Repair / Upgrade" : "Install",
            Location = new System.Drawing.Point(430, 536),
            Size = new System.Drawing.Size(148, 36)
        };
        _installButton.Click += async (_, _) => await RunInstallAsync();
        Controls.Add(_installButton);

        _uninstallButton = new Button
        {
            Text = "Uninstall",
            Location = new System.Drawing.Point(590, 536),
            Size = new System.Drawing.Size(110, 36)
        };
        _uninstallButton.Click += async (_, _) => await RunUninstallAsync();
        Controls.Add(_uninstallButton);

        _closeButton = new Button
        {
            Text = "Close",
            Location = new System.Drawing.Point(712, 536),
            Size = new System.Drawing.Size(102, 36)
        };
        _closeButton.Click += (_, _) => Close();
        Controls.Add(_closeButton);

        AppendLog("AI Guard setup is ready.");
        AppendLog("This setup always runs in enterprise mode and does not require PowerShell commands from the end user.");
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_busy)
        {
            e.Cancel = true;
            MessageBox.Show(
                this,
                "Setup is still running. Wait for the current operation to finish before closing this window.",
                "AI Guard Agent Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        base.OnFormClosing(e);
    }

    private static bool IsInstalled()
    {
        var installRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "AI Guard Agent");
        return Directory.Exists(installRoot);
    }

    private string BuildWarningText()
    {
        if (IsPythonAvailable())
        {
            return "This installer will request administrator approval and then perform a machine-wide install. Restart Chrome, Edge, and Claude Desktop after setup if they were already open.";
        }

        return "Warning: Python 3 was not detected on this PC. The bundled PII agent provisioning currently depends on Python. Install Python first or use a company image that already includes it.";
    }

    private async Task RunInstallAsync()
    {
        await RunScriptAsync(
            actionName: "installation",
            relativeScriptPath: InstallScriptRelativePath,
            arguments: "-PiiPort 8000 -SkipBuild",
            successMessage: "AI Guard Agent installation completed.\r\n\r\nRestart Chrome, Edge, and Claude Desktop if they were open during setup.");
    }

    private async Task RunUninstallAsync()
    {
        var result = MessageBox.Show(
            this,
            "This will remove the machine-wide AI Guard Agent installation from this PC.\r\n\r\nContinue?",
            "AI Guard Agent Setup",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning);

        if (result != DialogResult.Yes)
        {
            return;
        }

        await RunScriptAsync(
            actionName: "uninstall",
            relativeScriptPath: UninstallScriptRelativePath,
            arguments: "",
            successMessage: "AI Guard Agent uninstall completed.\r\n\r\nRestart Chrome and Edge to clear policy state.");
    }

    private async Task RunScriptAsync(string actionName, string relativeScriptPath, string arguments, string successMessage)
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        SetButtonsEnabled(false);
        _progressBar.Style = ProgressBarStyle.Marquee;

        var extractionRoot = string.Empty;

        try
        {
            extractionRoot = ExtractPayload();
            var scriptPath = Path.Combine(extractionRoot, relativeScriptPath);
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException($"Required setup script was not found: {scriptPath}");
            }

            AppendLog($"Starting {actionName}.");
            AppendLog($"Payload extracted to: {extractionRoot}");
            AppendLog($"Running script: {scriptPath}");

            var exitCode = await RunPowerShellAsync(scriptPath, arguments);
            if (exitCode != 0)
            {
                throw new InvalidOperationException($"The {actionName} process exited with code {exitCode}.");
            }

            AppendLog($"{actionName} completed successfully.");
            _installButton.Text = IsInstalled() ? "Repair / Upgrade" : "Install";

            MessageBox.Show(
                this,
                successMessage,
                "AI Guard Agent Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            AppendLog($"ERROR: {ex.Message}");
            AppendLog(ex.ToString());

            MessageBox.Show(
                this,
                $"AI Guard setup failed.\r\n\r\n{ex.Message}",
                "AI Guard Agent Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        finally
        {
            TryDeleteDirectory(extractionRoot);
            _progressBar.Style = ProgressBarStyle.Blocks;
            SetButtonsEnabled(true);
            _busy = false;
        }
    }

    private async Task<int> RunPowerShellAsync(string scriptPath, string arguments)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\" {arguments}".Trim(),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(scriptPath) ?? Environment.CurrentDirectory,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, eventArgs) =>
        {
            if (!string.IsNullOrWhiteSpace(eventArgs.Data))
            {
                AppendLog(eventArgs.Data);
            }
        };
        process.ErrorDataReceived += (_, eventArgs) =>
        {
            if (!string.IsNullOrWhiteSpace(eventArgs.Data))
            {
                AppendLog($"ERR: {eventArgs.Data}");
            }
        };

        if (!process.Start())
        {
            throw new InvalidOperationException("Failed to start PowerShell for AI Guard setup.");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync();
        return process.ExitCode;
    }

    private static string ExtractPayload()
    {
        var extractionRoot = Path.Combine(
            Path.GetTempPath(),
            "AI-Guard-Setup",
            Guid.NewGuid().ToString("N"));

        Directory.CreateDirectory(extractionRoot);

        var assembly = Assembly.GetExecutingAssembly();
        using var payloadStream = assembly.GetManifestResourceStream(PayloadResourceName)
            ?? throw new InvalidOperationException("Embedded AI Guard payload was not found inside the setup executable.");
        using var archive = new ZipArchive(payloadStream, ZipArchiveMode.Read);
        archive.ExtractToDirectory(extractionRoot, overwriteFiles: true);
        return extractionRoot;
    }

    private static bool IsPythonAvailable()
    {
        return CanRunCommand("py", "-3 --version") || CanRunCommand("python", "--version");
    }

    private static bool CanRunCommand(string fileName, string arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            });

            if (process is null)
            {
                return false;
            }

            process.WaitForExit(5000);
            return process.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    private void SetButtonsEnabled(bool enabled)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action<bool>(SetButtonsEnabled), enabled);
            return;
        }

        _installButton.Enabled = enabled;
        _uninstallButton.Enabled = enabled;
        _closeButton.Enabled = enabled;
    }

    private void AppendLog(string message)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action<string>(AppendLog), message);
            return;
        }

        var line = $"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}";
        _logBox.AppendText(line);
        _logBox.SelectionStart = _logBox.TextLength;
        _logBox.ScrollToCaret();
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
}
