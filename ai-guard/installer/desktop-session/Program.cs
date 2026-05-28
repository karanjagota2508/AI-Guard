using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Automation;
using System.Windows.Forms;

ApplicationConfiguration.Initialize();
using var mutex = new Mutex(true, @"Global\AIGuardClaudeDesktopUiaGuard", out var createdNew);
if (!createdNew)
{
    return;
}

var configPath = ParseNamedArgument(Environment.GetCommandLineArgs().Skip(1).ToArray(), "--config");
if (string.IsNullOrWhiteSpace(configPath) || !File.Exists(configPath))
{
    return;
}

Application.Run(new DesktopSessionContext(configPath));

static string? ParseNamedArgument(string[] args, string name)
{
    for (var index = 0; index < args.Length - 1; index += 1)
    {
        if (string.Equals(args[index], name, StringComparison.OrdinalIgnoreCase))
        {
            return args[index + 1];
        }
    }

    return null;
}

internal sealed class DesktopSessionContext : ApplicationContext
{
    private readonly string _configPath;
    private readonly System.Windows.Forms.Timer _stateTimer;
    private readonly System.Windows.Forms.Timer _debounceTimer;
    private readonly HttpClient _httpClient = new();
    private SessionConfig? _config;
    private AutomationElement? _currentEditor;
    private IntPtr _currentWindowHandle;
    private string _lastNormalizedText = string.Empty;
    private string _lastWarningKey = string.Empty;
    private DateTimeOffset _lastWarningAt = DateTimeOffset.MinValue;
    private bool _scanInFlight;

    public DesktopSessionContext(string configPath)
    {
        _configPath = configPath;
        _stateTimer = new System.Windows.Forms.Timer { Interval = 1200 };
        _stateTimer.Tick += (_, _) => RefreshState();
        _debounceTimer = new System.Windows.Forms.Timer { Interval = 350 };
        _debounceTimer.Tick += async (_, _) => await ScanActiveEditorAsync();

        Automation.AddAutomationFocusChangedEventHandler(OnAutomationFocusChanged);
        ReloadConfig();
        _stateTimer.Start();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            Automation.RemoveAutomationFocusChangedEventHandler(OnAutomationFocusChanged);
            DetachEditor();
            _stateTimer.Dispose();
            _debounceTimer.Dispose();
            _httpClient.Dispose();
        }

        base.Dispose(disposing);
    }

    private void ReloadConfig()
    {
        try
        {
            _config = SessionConfig.Load(_configPath);
            _httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", _config.AuthToken);
            _httpClient.DefaultRequestHeaders.Remove("Origin");
            _httpClient.DefaultRequestHeaders.Add("Origin", _config.Origin);
        }
        catch
        {
            _config = null;
        }
    }

    private void RefreshState()
    {
        if (_config is null || !File.Exists(_configPath))
        {
            ReloadConfig();
            return;
        }

        if (string.Equals(_config.DesktopProtectionMode, "hook_preferred", StringComparison.OrdinalIgnoreCase))
        {
            DetachEditor();
            return;
        }

        var windowHandle = GetClaudeWindowHandle();
        if (windowHandle == IntPtr.Zero)
        {
            _currentWindowHandle = IntPtr.Zero;
            _lastNormalizedText = string.Empty;
            DetachEditor();
            return;
        }

        if (windowHandle != _currentWindowHandle || _currentEditor is null)
        {
            _currentWindowHandle = windowHandle;
            AttachToEditor(windowHandle);
        }
    }

    private void OnAutomationFocusChanged(object src, AutomationFocusChangedEventArgs e)
    {
        if (_config is null || string.Equals(_config.DesktopProtectionMode, "hook_preferred", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var focused = src as AutomationElement;
        if (focused is null)
        {
            return;
        }

        var window = TreeWalker.ControlViewWalker.GetParent(focused);
        if (window?.Current.NativeWindowHandle == GetClaudeWindowHandle().ToInt32())
        {
            _debounceTimer.Stop();
            _debounceTimer.Start();
        }
    }

    private void AttachToEditor(IntPtr windowHandle)
    {
        DetachEditor();

        var window = AutomationElement.FromHandle(windowHandle);
        if (window is null)
        {
            return;
        }

        var editCondition = new PropertyCondition(
            AutomationElement.ControlTypeProperty,
            ControlType.Edit);
        var editors = window.FindAll(TreeScope.Descendants, editCondition);
        for (var index = 0; index < editors.Count; index += 1)
        {
            var editor = editors[index];
            var name = editor.Current.Name ?? string.Empty;
            var className = editor.Current.ClassName ?? string.Empty;
            if (name.Contains("prompt", StringComparison.OrdinalIgnoreCase) ||
                name.Contains("claude", StringComparison.OrdinalIgnoreCase) ||
                className.Contains("ProseMirror", StringComparison.OrdinalIgnoreCase))
            {
                _currentEditor = editor;
                break;
            }
        }

        _currentEditor ??= editors.Count > 0 ? editors[0] : null;
        if (_currentEditor is null)
        {
            return;
        }

        try
        {
            Automation.AddAutomationPropertyChangedEventHandler(
                _currentEditor,
                TreeScope.Element,
                OnEditorPropertyChanged,
                ValuePattern.ValueProperty,
                AutomationElement.IsEnabledProperty);

            Automation.AddAutomationEventHandler(
                TextPattern.TextChangedEvent,
                _currentEditor,
                TreeScope.Element,
                OnEditorTextChanged);
        }
        catch
        {
        }
    }

    private void DetachEditor()
    {
        if (_currentEditor is null)
        {
            return;
        }

        try
        {
            Automation.RemoveAutomationPropertyChangedEventHandler(_currentEditor, OnEditorPropertyChanged);
        }
        catch
        {
        }

        try
        {
            Automation.RemoveAutomationEventHandler(TextPattern.TextChangedEvent, _currentEditor, OnEditorTextChanged);
        }
        catch
        {
        }

        _currentEditor = null;
    }

    private void OnEditorPropertyChanged(object sender, AutomationPropertyChangedEventArgs e)
    {
        _debounceTimer.Stop();
        _debounceTimer.Start();
    }

    private void OnEditorTextChanged(object sender, AutomationEventArgs e)
    {
        _debounceTimer.Stop();
        _debounceTimer.Start();
    }

    private async Task ScanActiveEditorAsync()
    {
        _debounceTimer.Stop();
        if (_scanInFlight || _config is null || _currentEditor is null)
        {
            return;
        }

        _scanInFlight = true;
        try
        {
            var text = ReadEditorText(_currentEditor);
            var normalized = NormalizeText(text);
            if (string.IsNullOrWhiteSpace(normalized) || string.Equals(normalized, _lastNormalizedText, StringComparison.Ordinal))
            {
                return;
            }

            var response = await ScanTextAsync(text);
            _lastNormalizedText = normalized;
            if (response is null || string.IsNullOrWhiteSpace(response.Action))
            {
                return;
            }

            if (string.Equals(response.Action, "allow", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            if (string.Equals(response.Action, "redact", StringComparison.OrdinalIgnoreCase))
            {
                var replacement = string.IsNullOrWhiteSpace(response.RedactedText) ? text : response.RedactedText!;
                if (!string.Equals(NormalizeText(replacement), normalized, StringComparison.Ordinal))
                {
                    SetEditorText(_currentEditor, replacement);
                    _lastNormalizedText = NormalizeText(replacement);
                }

                ShowToast(response.Reason ?? "Sensitive content was redacted.", $"redact:{response.Reason}");
                return;
            }

            if (string.Equals(response.Action, "block", StringComparison.OrdinalIgnoreCase))
            {
                SetEditorText(_currentEditor, string.Empty);
                _lastNormalizedText = string.Empty;
                ShowToast(response.Reason ?? "Ulti Guard blocked this Claude Desktop prompt.", $"block:{response.Reason}");
            }
        }
        catch
        {
        }
        finally
        {
            _scanInFlight = false;
        }
    }

    private async Task<ScanResponse?> ScanTextAsync(string text)
    {
        if (_config is null)
        {
            return null;
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{_config.BaseUrl}/scan");
        request.Content = new StringContent(
            JsonSerializer.Serialize(new { text }),
            Encoding.UTF8,
            "application/json");

        using var response = await _httpClient.SendAsync(request);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        await using var stream = await response.Content.ReadAsStreamAsync();
        return await JsonSerializer.DeserializeAsync<ScanResponse>(stream);
    }

    private void ShowToast(string message, string warningKey)
    {
        var now = DateTimeOffset.UtcNow;
        if (string.Equals(_lastWarningKey, warningKey, StringComparison.Ordinal) &&
            (now - _lastWarningAt).TotalMilliseconds < 2500)
        {
            return;
        }

        _lastWarningKey = warningKey;
        _lastWarningAt = now;

        var toast = new System.Windows.Forms.Form
        {
            FormBorderStyle = System.Windows.Forms.FormBorderStyle.None,
            ShowInTaskbar = false,
            TopMost = true,
            StartPosition = System.Windows.Forms.FormStartPosition.Manual,
            BackColor = Color.FromArgb(161, 23, 23),
            ForeColor = Color.White,
            Size = new Size(460, 108)
        };

        var label = new System.Windows.Forms.Label
        {
            Dock = DockStyle.Fill,
            Text = $"Ulti Guard: {message}",
            ForeColor = Color.White,
            BackColor = toast.BackColor,
            Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
            Padding = new Padding(16, 14, 16, 14),
            TextAlign = ContentAlignment.MiddleLeft
        };
        toast.Controls.Add(label);

        var timer = new System.Windows.Forms.Timer { Interval = 3500 };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            toast.Close();
            timer.Dispose();
        };

        var bounds = Screen.FromHandle(GetClaudeWindowHandle()).WorkingArea;
        toast.Location = new Point(Math.Max(bounds.Left + 18, bounds.Right - toast.Width - 24), Math.Max(bounds.Top + 18, bounds.Bottom - toast.Height - 18));
        toast.Shown += (_, _) => timer.Start();
        toast.Show();
    }

    private static string ReadEditorText(AutomationElement editor)
    {
        if (editor.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePattern))
        {
            return ((ValuePattern)valuePattern).Current.Value ?? string.Empty;
        }

        if (editor.TryGetCurrentPattern(TextPattern.Pattern, out var textPattern))
        {
            return ((TextPattern)textPattern).DocumentRange.GetText(-1) ?? string.Empty;
        }

        return string.Empty;
    }

    private static void SetEditorText(AutomationElement editor, string value)
    {
        if (editor.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePattern))
        {
            ((ValuePattern)valuePattern).SetValue(value);
        }
    }

    private static string NormalizeText(string value) =>
        (value ?? string.Empty).Replace("\r\n", "\n", StringComparison.Ordinal).Replace("\r", "\n", StringComparison.Ordinal).Trim();

    private static IntPtr GetClaudeWindowHandle()
    {
        return Process.GetProcessesByName("claude")
            .Where(item => item.MainWindowHandle != IntPtr.Zero)
            .OrderByDescending(item => item.StartTime)
            .Select(item => item.MainWindowHandle)
            .Cast<IntPtr?>()
            .FirstOrDefault() ?? IntPtr.Zero;
    }
}

internal sealed class SessionConfig
{
    public required string BaseUrl { get; init; }
    public required string AuthToken { get; init; }
    public required string Origin { get; init; }
    public required string DesktopProtectionMode { get; init; }

    public static SessionConfig Load(string path)
    {
        var root = JsonNode.Parse(File.ReadAllText(path)) as JsonObject
            ?? throw new InvalidOperationException($"Invalid config JSON: {path}");
        var extensionId =
            root["package"]?["edge_extension_id"]?.GetValue<string>()
            ?? root["package"]?["chrome_extension_id"]?.GetValue<string>()
            ?? root["package"]?["extension_id"]?.GetValue<string>()
            ?? root["extension_ids"]?.AsArray().FirstOrDefault()?.GetValue<string>()
            ?? throw new InvalidOperationException("Missing extension ID.");

        return new SessionConfig
        {
            BaseUrl = $"http://{root["listen_address"]?.GetValue<string>()?.Trim() ?? "127.0.0.1:48555"}",
            AuthToken = root["auth_token"]?.GetValue<string>()?.Trim() ?? throw new InvalidOperationException("Missing auth token."),
            Origin = $"chrome-extension://{extensionId}",
            DesktopProtectionMode = root["claude"]?["desktop_protection_mode"]?.GetValue<string>()?.Trim() ?? "hook_preferred"
        };
    }
}

internal sealed class ScanResponse
{
    public string? Action { get; set; }
    public string? RedactedText { get; set; }
    public string? Reason { get; set; }
}
