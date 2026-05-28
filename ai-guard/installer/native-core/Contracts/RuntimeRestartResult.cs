namespace AIGuard.Native.Contracts;

public sealed record RuntimeRestartResult(bool Success, string Message, string DiagnosticMessage)
{
    public static RuntimeRestartResult Succeeded(string message) =>
        new(true, message, message);

    public static RuntimeRestartResult Failure(string message, string diagnosticMessage) =>
        new(false, message, diagnosticMessage);
}
