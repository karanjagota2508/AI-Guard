using System.Windows;

namespace AIGuard.AdminConsole.Dialogs;

public partial class PasswordDialog : Window
{
    private readonly int _minimumPasswordLength;

    public PasswordDialog(
        string title,
        string message,
        string primaryButtonText,
        bool requireConfirmation,
        int minimumPasswordLength)
    {
        InitializeComponent();
        Title = title;
        PromptTitleBlock.Text = title;
        PromptMessageBlock.Text = message;
        PrimaryButton.Content = primaryButtonText;
        ConfirmPanel.Visibility = requireConfirmation ? Visibility.Visible : Visibility.Collapsed;
        SizeToContent = SizeToContent.Height;
        MinHeight = requireConfirmation ? 320 : 260;
        RequireConfirmation = requireConfirmation;
        _minimumPasswordLength = minimumPasswordLength > 0 ? minimumPasswordLength : 12;
        Loaded += (_, _) =>
        {
            PasswordBox.Focus();
            UpdateValidation();
        };
        PasswordBox.PasswordChanged += (_, _) => UpdateValidation();
        ConfirmPasswordBox.PasswordChanged += (_, _) => UpdateValidation();
    }

    public bool RequireConfirmation { get; }

    public string Password => PasswordBox.Password;

    public string Confirmation => ConfirmPasswordBox.Password;

    private void Confirm_Click(object sender, RoutedEventArgs e)
    {
        if (!ValidateInputs())
        {
            return;
        }

        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void UpdateValidation()
    {
        ValidateInputs();
        PrimaryButton.IsEnabled = string.IsNullOrWhiteSpace(ValidationBlock.Text);
    }

    private bool ValidateInputs()
    {
        ValidationBlock.Text = string.Empty;

        if (string.IsNullOrWhiteSpace(Password))
        {
            ValidationBlock.Text = "Password is required.";
            return false;
        }

        if (Password.Length < _minimumPasswordLength)
        {
            ValidationBlock.Text = $"Password must be at least {_minimumPasswordLength} characters.";
            return false;
        }

        if (RequireConfirmation && Password != Confirmation)
        {
            ValidationBlock.Text = "Passwords do not match.";
            return false;
        }

        return true;
    }
}
