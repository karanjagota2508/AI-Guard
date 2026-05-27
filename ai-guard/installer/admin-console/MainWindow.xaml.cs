using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using AIGuard.AdminConsole.Dialogs;
using AIGuard.AdminConsole.Services;

namespace AIGuard.AdminConsole;

public partial class MainWindow : Window
{
    private readonly ConfigService _configService = new();
    private readonly AdminSecretStore _secretStore = new();
    private readonly AdminOperations _operations = new();
    private readonly ObservableCollection<string> _blockedHosts = [];
    private readonly ObservableCollection<string> _blockedProcesses = [];
    private readonly Dictionary<string, ProviderPreset> _providerCatalog = new(StringComparer.OrdinalIgnoreCase)
    {
        ["ChatGPT / OpenAI"] = new(["chatgpt.com", "chat.openai.com"], ["ChatGPT"]),
        ["Gemini"] = new(["gemini.google.com"], []),
        ["Perplexity"] = new(["perplexity.ai", "www.perplexity.ai"], []),
        ["Cursor"] = new([], ["Cursor"]),
        ["Ollama"] = new([], ["Ollama"]),
        ["LM Studio"] = new([], ["LM Studio"]),
        ["Open WebUI"] = new([], ["OpenWebUI"]),
        ["AnythingLLM"] = new([], ["AnythingLLM"]),
        ["Jan"] = new([], ["Jan"]),
    };

    private string _configPath = string.Empty;
    private string _installRoot = string.Empty;
    private JsonObject _configRoot = new();
    private readonly CancellationTokenSource _windowLifetime = new();
    private int _backgroundApplyInProgress;

    public MainWindow()
    {
        InitializeComponent();
        BlockedHostsListBox.ItemsSource = _blockedHosts;
        BlockedProcessesListBox.ItemsSource = _blockedProcesses;
        PresetComboBox.ItemsSource = _providerCatalog.Keys.ToArray();
        PresetComboBox.SelectedIndex = 0;
        Loaded += MainWindow_Loaded;
        Closed += (_, _) => _windowLifetime.Cancel();
    }
    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _configPath = _configService.ResolveConfigPath(ParseNamedArgument("--config"));
            _installRoot = _configService.ResolveInstallRoot(_configPath);
            _configRoot = _configService.Load(_configPath);

            // Silent self-test argument check
            if (HasCommandLineArgument("--self-test"))
            {
                Application.Current.Shutdown(0);
                return;
            }

            await MigrateLegacySecretAsync();
            if (!await EnsureAuthenticatedAsync())
            {
                Close();
                return;
            }

            ConfigPathText.Text = FormatConfigPathForDisplay(_configPath);
            ConfigPathText.ToolTip = FormatConfigPathForDisplay(_configPath);
            InstallModeBadge.Text = _configService.IsMachineInstall(_configPath) ? "Machine Install" : "Current User Install";
            LoadBranding();
            ReloadFromDisk();
            StatusTextBlock.Text = $"Loaded config from {FormatConfigPathForDisplay(_configPath)}";
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                ex.Message,
                "Ulti Guard Admin Console",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Close();
        }
    }

    private async Task MigrateLegacySecretAsync()
    {
        var secretPath = _configService.ResolveSecretPath(_configPath, _configRoot);
        var legacySecret = _configService.TryGetLegacySecret(_configRoot);
        if (legacySecret is null || _secretStore.Exists(secretPath))
        {
            return;
        }

        _secretStore.Save(secretPath, legacySecret);
        _configService.ClearLegacySecret(_configRoot);
        _configService.Save(_configPath, _configRoot);
        await Task.CompletedTask;
    }

    private async Task<bool> EnsureAuthenticatedAsync()
    {
        var secretPath = _configService.ResolveSecretPath(_configPath, _configRoot);
        var minimumPasswordLength = _configService.GetMinimumPasswordLength(_configRoot);
        if (!_secretStore.Exists(secretPath))
        {
            var createDialog = new PasswordDialog(
                "Create Admin Password",
                "Set the password required to open Ulti Guard Admin Console on this device.",
                "Set Password",
                requireConfirmation: true,
                minimumPasswordLength: minimumPasswordLength)
            {
                Owner = this
            };

            if (createDialog.ShowDialog() != true)
            {
                return false;
            }

            var payload = _secretStore.Create(createDialog.Password, _configService.GetPasswordIterations(_configRoot));
            _secretStore.Save(secretPath, payload);
            return true;
        }

        var promptDialog = new PasswordDialog(
            "Admin Password Required",
            "Enter the Ulti Guard Admin Console password to continue.",
            "Unlock",
            requireConfirmation: false,
            minimumPasswordLength: minimumPasswordLength)
        {
            Owner = this
        };

        if (promptDialog.ShowDialog() != true)
        {
            return false;
        }

        var currentSecret = _secretStore.Load(secretPath);
        if (_secretStore.Validate(promptDialog.Password, currentSecret))
        {
            return true;
        }

        MessageBox.Show(
            "The password was incorrect.",
            "Ulti Guard Admin Console",
            MessageBoxButton.OK,
            MessageBoxImage.Warning);
        return await EnsureAuthenticatedAsync();
    }

    private void LoadBranding()
    {
        var logoPath = Path.Combine(_installRoot, "branding", "logo.png");
        if (!File.Exists(logoPath))
        {
            return;
        }

        LogoImage.Source = new BitmapImage(new Uri(logoPath));
    }

    private void ReloadFromDisk()
    {
        _configRoot = _configService.Load(_configPath);
        ResetCollection(_blockedHosts, _configService.GetBlockedHosts(_configRoot));
        ResetCollection(_blockedProcesses, _configService.GetBlockedProcesses(_configRoot));

        // Load PII Settings
        var piiEnabled = _configService.GetPiiEnabled(_configRoot);
        PiiEnabledCheckBox.IsChecked = piiEnabled;
        PiiConfidenceTextBox.Text = _configService.GetPiiConfidenceScore(_configRoot).ToString("0.00");

        var piiAction = _configService.GetPiiAction(_configRoot).ToLowerInvariant();
        PiiActionRedact.IsChecked = piiAction == "redact";
        PiiActionMask.IsChecked = piiAction == "mask";
        PiiActionReplace.IsChecked = piiAction == "replace";
        PiiActionHash.IsChecked = piiAction == "hash";
        PiiActionKeep.IsChecked = piiAction == "keep";
        PiiActionBlock.IsChecked = piiAction == "block";

        UpdatePiiPanelState(piiEnabled);
    }

    private void PiiEnabledCheckBox_Checked(object sender, RoutedEventArgs e)
    {
        UpdatePiiPanelState(PiiEnabledCheckBox.IsChecked == true);
    }

    private void UpdatePiiPanelState(bool enabled)
    {
        if (PiiSettingsPanel != null)
        {
            PiiSettingsPanel.IsEnabled = enabled;
            PiiSettingsPanel.Opacity = enabled ? 1.0 : 0.45;
        }
    }

    private static void ResetCollection(ObservableCollection<string> target, IReadOnlyList<string> values)
    {
        target.Clear();
        foreach (var value in values)
        {
            target.Add(value);
        }
    }

    private void AddHostButton_Click(object sender, RoutedEventArgs e)
    {
        var value = _configService.NormalizeHost(BlockedHostTextBox.Text);
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        AddUnique(_blockedHosts, value);
        BlockedHostTextBox.Clear();
        StatusTextBlock.Text = $"Added blocked host: {value}";
    }

    private void AddProcessButton_Click(object sender, RoutedEventArgs e)
    {
        var value = _configService.NormalizeProcessName(BlockedProcessTextBox.Text);
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        AddUnique(_blockedProcesses, value);
        BlockedProcessTextBox.Clear();
        StatusTextBlock.Text = $"Added blocked process: {value}";
    }

    private void AddPresetButton_Click(object sender, RoutedEventArgs e)
    {
        if (PresetComboBox.SelectedItem is not string name || !_providerCatalog.TryGetValue(name, out var preset))
        {
            return;
        }

        foreach (var host in preset.BrowserHosts)
        {
            AddUnique(_blockedHosts, _configService.NormalizeHost(host));
        }

        foreach (var process in preset.ProcessNames)
        {
            AddUnique(_blockedProcesses, _configService.NormalizeProcessName(process));
        }

        StatusTextBlock.Text = $"Added preset provider: {name}";
    }

    private async void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (IsBackgroundApplyInProgress())
        {
            StatusTextBlock.Text = "Apply already in progress.";
            MessageBox.Show(
                "Ulti Guard is still applying the previous Save & Apply request. Wait for that restart to finish before saving again.",
                "Ulti Guard Admin Console",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        var backgroundApplyScheduled = false;
        try
        {
            SetBusy(true);

            // Validate and Parse PII Confidence Score if PII is enabled
            var piiEnabled = PiiEnabledCheckBox.IsChecked == true;
            double confidenceScore = 0.35;
            if (piiEnabled)
            {
                if (!double.TryParse(PiiConfidenceTextBox.Text.Trim(), out confidenceScore) || confidenceScore < 0.0 || confidenceScore > 1.0)
                {
                    throw new InvalidOperationException("Confidence Score must be a valid decimal number between 0.0 and 1.0.");
                }
            }
            else
            {
                // Try parsing confidence score even if disabled, but fallback silently to 0.35 if invalid
                double.TryParse(PiiConfidenceTextBox.Text.Trim(), out confidenceScore);
                if (confidenceScore < 0.0 || confidenceScore > 1.0)
                {
                    confidenceScore = 0.35;
                }
            }

            // Determine active PII action
            string piiAction = "redact";
            if (PiiActionMask.IsChecked == true) piiAction = "mask";
            else if (PiiActionReplace.IsChecked == true) piiAction = "replace";
            else if (PiiActionHash.IsChecked == true) piiAction = "hash";
            else if (PiiActionKeep.IsChecked == true) piiAction = "keep";
            else if (PiiActionBlock.IsChecked == true) piiAction = "block";

            _configService.SetBlockedHosts(_configRoot, _blockedHosts);
            _configService.SetBlockedProcesses(_configRoot, _blockedProcesses);
            _configService.SetPiiSettings(_configRoot, piiEnabled, confidenceScore, piiAction);

            _configService.Save(_configPath, _configRoot);
            await _operations.ApplyBrowserPoliciesAsync(_installRoot, _configPath, CancellationToken.None);

            if (Interlocked.CompareExchange(ref _backgroundApplyInProgress, 1, 0) != 0)
            {
                StatusTextBlock.Text = "Apply already in progress.";
                MessageBox.Show(
                    "Ulti Guard is still applying the previous Save & Apply request. Wait for that restart to finish before saving again.",
                    "Ulti Guard Admin Console",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            StatusTextBlock.Text = "Saved. Restarting Ulti Guard...";

            MessageBox.Show(
                "Provider settings and PII configurations were saved successfully."
                + Environment.NewLine + Environment.NewLine
                + "Applying runtime changes in the background.",
                "Ulti Guard Admin Console",
                MessageBoxButton.OK,
                MessageBoxImage.Information);

            _ = ApplyRuntimeChangesInBackgroundAsync(_installRoot, _configPath, _windowLifetime.Token);
            backgroundApplyScheduled = true;
        }
        catch (Exception ex)
        {
            StatusTextBlock.Text = $"Save failed: {ex.Message}";
            MessageBox.Show(
                ex.Message,
                "Ulti Guard Admin Console",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        finally
        {
            SetBusy(false);
            if (!backgroundApplyScheduled && IsBackgroundApplyInProgress())
            {
                Interlocked.Exchange(ref _backgroundApplyInProgress, 0);
            }
        }
    }

    private void ReloadButton_Click(object sender, RoutedEventArgs e)
    {
        ReloadFromDisk();
        StatusTextBlock.Text = $"Reloaded config from {FormatConfigPathForDisplay(_configPath)}";
    }

    private void RemoveHostButton_Click(object sender, RoutedEventArgs e)
    {
        RemoveSelected(BlockedHostsListBox, _blockedHosts);
        StatusTextBlock.Text = "Removed selected hosts.";
    }

    private void RemoveProcessButton_Click(object sender, RoutedEventArgs e)
    {
        RemoveSelected(BlockedProcessesListBox, _blockedProcesses);
        StatusTextBlock.Text = "Removed selected processes.";
    }

    private void ChangePasswordButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new PasswordDialog(
            "Change Admin Password",
            "Enter a new password for Ulti Guard Admin Console.",
            "Save Password",
            requireConfirmation: true,
            minimumPasswordLength: _configService.GetMinimumPasswordLength(_configRoot))
        {
            Owner = this
        };

        if (dialog.ShowDialog() != true)
        {
            return;
        }

        var secretPath = _configService.ResolveSecretPath(_configPath, _configRoot);
        var payload = _secretStore.Create(dialog.Password, _configService.GetPasswordIterations(_configRoot));
        _secretStore.Save(secretPath, payload);
        StatusTextBlock.Text = "Admin console password updated.";
        MessageBox.Show(
            "Admin console password updated successfully.",
            "Ulti Guard Admin Console",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void BlockedHostTextBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            AddHostButton_Click(sender, e);
            e.Handled = true;
        }
    }

    private void BlockedProcessTextBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            AddProcessButton_Click(sender, e);
            e.Handled = true;
        }
    }

    private static void RemoveSelected(ListBox listBox, ObservableCollection<string> target)
    {
        foreach (var item in listBox.SelectedItems.Cast<string>().ToArray())
        {
            target.Remove(item);
        }
    }

    private static void AddUnique(ObservableCollection<string> target, string value)
    {
        if (target.Any(item => string.Equals(item, value, StringComparison.OrdinalIgnoreCase)))
        {
            return;
        }

        target.Add(value);
        var ordered = target.OrderBy(item => item, StringComparer.OrdinalIgnoreCase).ToArray();
        target.Clear();
        foreach (var item in ordered)
        {
            target.Add(item);
        }
    }

    private async Task ApplyRuntimeChangesInBackgroundAsync(
        string installRoot,
        string configPath,
        CancellationToken cancellationToken)
    {
        try
        {
            var runtimeResult = await _operations.RestartRuntimeAsync(installRoot, configPath, cancellationToken);
            if (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            await Dispatcher.InvokeAsync(() =>
            {
                if (runtimeResult.Success)
                {
                    StatusTextBlock.Text = $"Saved. {runtimeResult.Message}";
                    return;
                }

                StatusTextBlock.Text = "Saved, but Ulti Guard restart/readiness failed.";
                if (!IsLoaded)
                {
                    return;
                }

                MessageBox.Show(
                    this,
                    "Settings were saved successfully, but Ulti Guard could not restart or become ready."
                    + Environment.NewLine + Environment.NewLine
                    + "PII protection may remain unavailable until the service is restarted successfully."
                    + Environment.NewLine + Environment.NewLine
                    + runtimeResult.Message,
                    "Ulti Guard Admin Console",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            });
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            await Dispatcher.InvokeAsync(() =>
            {
                StatusTextBlock.Text = "Saved, but Ulti Guard restart/readiness failed.";
                if (!IsLoaded)
                {
                    return;
                }

                MessageBox.Show(
                    this,
                    "Settings were saved successfully, but Ulti Guard could not restart or become ready."
                    + Environment.NewLine + Environment.NewLine
                    + "PII protection may remain unavailable until the service is restarted successfully."
                    + Environment.NewLine + Environment.NewLine
                    + ex.Message,
                    "Ulti Guard Admin Console",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            });
        }
        finally
        {
            Interlocked.Exchange(ref _backgroundApplyInProgress, 0);
        }
    }

    private void SetBusy(bool busy)
    {
        SaveButton.IsEnabled = !busy;
        ReloadButton.IsEnabled = !busy;
        ChangePasswordButton.IsEnabled = !busy;
        AddPresetButton.IsEnabled = !busy;
        AddHostButton.IsEnabled = !busy;
        RemoveHostButton.IsEnabled = !busy;
        AddProcessButton.IsEnabled = !busy;
        RemoveProcessButton.IsEnabled = !busy;
        Cursor = busy ? Cursors.Wait : null;
    }

    private bool IsBackgroundApplyInProgress() =>
        Interlocked.CompareExchange(ref _backgroundApplyInProgress, 0, 0) == 1;

    private string? ParseNamedArgument(string name)
    {
        var args = Environment.GetCommandLineArgs();
        for (var index = 0; index < args.Length - 1; index += 1)
        {
            if (string.Equals(args[index], name, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }

        return null;
    }

    private bool HasCommandLineArgument(string name)
    {
        return Environment.GetCommandLineArgs()
            .Any(arg => string.Equals(arg, name, StringComparison.OrdinalIgnoreCase));
    }

    private static string FormatConfigPathForDisplay(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return string.Empty;
        }

        return path.Replace("AI Guard Agent", "Ulti Guard", StringComparison.OrdinalIgnoreCase)
            .Replace("Ulti Guard Agent", "Ulti Guard", StringComparison.OrdinalIgnoreCase);
    }
}

internal sealed record ProviderPreset(IReadOnlyList<string> BrowserHosts, IReadOnlyList<string> ProcessNames);
