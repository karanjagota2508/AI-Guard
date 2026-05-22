using System.Diagnostics;
using System.Drawing;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace UltiGuardSetup;

internal sealed class SetupForm : Form
{
    private const string PayloadResourceName = "UltiGuardSetup.Payload.zip";
    private const string InstallScriptResourceName = "UltiGuardSetup.Scripts.install-enterprise.ps1";
    private const string UninstallScriptResourceName = "UltiGuardSetup.Scripts.uninstall.ps1";
    private const string BrandLogoResourceName = "UltiGuardSetup.BrandLogo.png";
    private const string BrandIconResourceName = "UltiGuardSetup.BrandIcon.ico";

    private readonly PictureBox _logoBox;
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
        Text = "Ulti Guard Agent Setup";
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(860, 620);
        MinimumSize = new Size(860, 620);
        MaximizeBox = false;
        BackColor = Color.FromArgb(247, 248, 251);
        Icon = LoadBrandIcon();

        _logoBox = new PictureBox
        {
            Location = new Point(24, 18),
            Size = new Size(138, 56),
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Color.Transparent,
            Image = LoadBrandLogo()
        };
        Controls.Add(_logoBox);

        _titleLabel = new Label
        {
            Text = "Ulti Guard Agent Setup",
            Font = new Font("Segoe UI Semibold", 20, FontStyle.Bold),
            Location = new Point(178, 18),
            AutoSize = true
        };
        Controls.Add(_titleLabel);

        _subtitleLabel = new Label
        {
            Text = "Installs the daemon service, managed browser extension, Claude Desktop guard, bundled PII agent, and admin console.",
            Font = new Font("Segoe UI", 10),
            Location = new Point(180, 58),
            Size = new Size(634, 40)
        };
        Controls.Add(_subtitleLabel);

        _warningLabel = new Label
        {
            Text = "This setup will request administrator approval and then perform a machine-wide install. It bundles its own local runtime, does not require command-line steps from the end user, and can restart Chrome or Edge if they are open so managed extension policy activates immediately.",
            Font = new Font("Segoe UI", 9),
            ForeColor = Color.FromArgb(120, 84, 0),
            BackColor = Color.FromArgb(255, 243, 205),
            BorderStyle = BorderStyle.FixedSingle,
            Location = new Point(24, 106),
            Size = new Size(790, 46),
            Padding = new Padding(8, 6, 8, 6)
        };
        Controls.Add(_warningLabel);

        _logBox = new RichTextBox
        {
            Location = new Point(24, 170),
            Size = new Size(790, 320),
            ReadOnly = true,
            Font = new Font("Consolas", 10),
            BackColor = Color.White,
            BorderStyle = BorderStyle.FixedSingle,
            WordWrap = false
        };
        Controls.Add(_logBox);

        _progressBar = new ProgressBar
        {
            Location = new Point(24, 504),
            Size = new Size(790, 18),
            Style = ProgressBarStyle.Blocks
        };
        Controls.Add(_progressBar);

        _installButton = new Button
        {
            Text = IsInstalled() ? "Repair / Upgrade" : "Install",
            Location = new Point(430, 536),
            Size = new Size(148, 36)
        };
        _installButton.Click += async (_, _) => await RunInstallAsync();
        Controls.Add(_installButton);

        _uninstallButton = new Button
        {
            Text = "Uninstall",
            Location = new Point(590, 536),
            Size = new Size(110, 36)
        };
        _uninstallButton.Click += async (_, _) => await RunUninstallAsync();
        Controls.Add(_uninstallButton);

        _closeButton = new Button
        {
            Text = "Close",
            Location = new Point(712, 536),
            Size = new Size(102, 36)
        };
        _closeButton.Click += (_, _) => Close();
        Controls.Add(_closeButton);

        AppendLog("Ulti Guard setup is ready.");
        AppendLog("This setup always runs in enterprise mode and does not require PowerShell commands from the end user.");
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _logoBox.Image?.Dispose();
        }

        base.Dispose(disposing);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_busy)
        {
            e.Cancel = true;
            MessageBox.Show(
                this,
                "Setup is still running. Wait for the current operation to finish before closing this window.",
                "Ulti Guard Agent Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        base.OnFormClosing(e);
    }

    private static bool IsInstalled()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        return Directory.Exists(Path.Combine(programFiles, "Ulti Guard Agent"))
            || Directory.Exists(Path.Combine(programFiles, "AI Guard Agent"))
            || Directory.Exists(Path.Combine(localAppData, "Ulti Guard Agent"))
            || Directory.Exists(Path.Combine(localAppData, "AI Guard Agent"));
    }

    private async Task RunInstallAsync()
    {
        if (!EnsureElevated())
        {
            return;
        }

        await RunScriptAsync(
            actionName: "installation",
            scriptResourceName: InstallScriptResourceName,
            arguments: "-PiiPort 8000 -SkipBuild",
            successMessage: "Ulti Guard Agent installation completed.\r\n\r\nIf Chrome or Edge were open during setup, they may have been restarted so the managed extension can activate immediately.");
    }

    private async Task RunUninstallAsync()
    {
        if (!EnsureElevated())
        {
            return;
        }

        var result = MessageBox.Show(
            this,
            "This will remove the machine-wide Ulti Guard Agent installation from this PC.\r\n\r\nContinue?",
            "Ulti Guard Agent Setup",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning);

        if (result != DialogResult.Yes)
        {
            return;
        }

        await RunScriptAsync(
            actionName: "uninstall",
            scriptResourceName: UninstallScriptResourceName,
            arguments: $"-InstallRoot \"{Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)}\\Ulti Guard Agent\"",
            successMessage: "Ulti Guard Agent uninstall completed.\r\n\r\nRestart Chrome and Edge to clear policy state.");
    }

    private async Task RunScriptAsync(string actionName, string scriptResourceName, string arguments, string successMessage)
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
            var installerRoot = Path.Combine(extractionRoot, "ai-guard", "installer");
            if (!Directory.Exists(installerRoot))
            {
                throw new DirectoryNotFoundException($"Required installer payload directory was not found: {installerRoot}");
            }

            AppendLog($"Starting {actionName}.");
            AppendLog($"Payload extracted to: {extractionRoot}");
            AppendLog($"Running embedded setup resource: {scriptResourceName}");

            var exitCode = await RunPowerShellAsync(scriptResourceName, arguments, installerRoot);
            if (exitCode != 0)
            {
                throw new InvalidOperationException($"The {actionName} process exited with code {exitCode}.");
            }

            AppendLog($"{actionName} completed successfully.");
            _installButton.Text = IsInstalled() ? "Repair / Upgrade" : "Install";

            MessageBox.Show(
                this,
                successMessage,
                "Ulti Guard Agent Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            AppendLog($"ERROR: {ex.Message}");
            AppendLog(ex.ToString());

            MessageBox.Show(
                this,
                $"Ulti Guard setup failed.\r\n\r\n{ex.Message}",
                "Ulti Guard Agent Setup",
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

    private async Task<int> RunPowerShellAsync(string scriptResourceName, string arguments, string installerRoot)
    {
        var scriptText = ReadEmbeddedText(scriptResourceName);
        var encodedScript = Convert.ToBase64String(Encoding.UTF8.GetBytes(scriptText));
        var invocation = string.IsNullOrWhiteSpace(arguments)
            ? "& ([ScriptBlock]::Create($scriptText))"
            : $"& ([ScriptBlock]::Create($scriptText)) {arguments}";

        var bootstrapCommand = $@"$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:ULTI_GUARD_INSTALLER_ROOT = '{EscapePowerShellSingleQuotedString(installerRoot)}'
try {{
    $scriptText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('{encodedScript}'))
    {invocation}
    exit 0
}} catch {{
    Write-Error $_
    exit 1
}}";

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoLogo -NoProfile -NonInteractive -Command -",
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = installerRoot,
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
            throw new InvalidOperationException("Failed to start PowerShell for Ulti Guard setup.");
        }

        await process.StandardInput.WriteAsync(bootstrapCommand);
        await process.StandardInput.FlushAsync();
        process.StandardInput.Close();

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync();
        return process.ExitCode;
    }

    private static string ReadEmbeddedText(string resourceName)
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Embedded resource not found: {resourceName}");
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }

    private static string ExtractPayload()
    {
        var extractionRoot = Path.Combine(
            Path.GetTempPath(),
            "Ulti-Guard-Setup",
            Guid.NewGuid().ToString("N"));

        Directory.CreateDirectory(extractionRoot);

        var assembly = Assembly.GetExecutingAssembly();
        using var payloadStream = assembly.GetManifestResourceStream(PayloadResourceName)
            ?? throw new InvalidOperationException("Embedded Ulti Guard payload was not found inside the setup executable.");
        using var archive = new ZipArchive(payloadStream, ZipArchiveMode.Read);
        archive.ExtractToDirectory(extractionRoot, overwriteFiles: true);
        return extractionRoot;
    }

    private bool EnsureElevated()
    {
        if (IsAdministrator())
        {
            return true;
        }

        try
        {
            using var currentProcess = Process.GetCurrentProcess();
            var startInfo = new ProcessStartInfo
            {
                FileName = currentProcess.MainModule?.FileName ?? Application.ExecutablePath,
                UseShellExecute = true,
                Verb = "runas"
            };

            Process.Start(startInfo);
            Close();
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                $"Administrator approval is required to continue.\r\n\r\n{ex.Message}",
                "Ulti Guard Agent Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }

        return false;
    }

    private static bool IsAdministrator()
    {
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        var principal = new System.Security.Principal.WindowsPrincipal(identity);
        return principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
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

    private static Image? LoadBrandLogo()
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(BrandLogoResourceName);
        if (stream is null)
        {
            return null;
        }

        using var image = Image.FromStream(stream);
        return new Bitmap(image);
    }

    private static Icon? LoadBrandIcon()
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(BrandIconResourceName);
        return stream is null ? null : new Icon(stream);
    }

    private static string EscapePowerShellSingleQuotedString(string value)
    {
        return value.Replace("'", "''", StringComparison.Ordinal);
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
