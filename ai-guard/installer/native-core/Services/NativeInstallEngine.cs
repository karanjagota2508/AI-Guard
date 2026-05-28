using AIGuard.Native.Contracts;
using AIGuard.Native.Interfaces;
using System.Diagnostics;

namespace AIGuard.Native.Services;

public sealed class NativeInstallEngine : IInstallEngine
{
    private readonly IPolicyService _policyService;
    private readonly IDesktopIntegrationService _desktopIntegrationService;
    private readonly RuntimeRestartService _runtimeRestartService;
    private readonly ConfigMaterializer _configMaterializer;
    private readonly InstallValidationService _installValidationService;
    private readonly WindowsServiceManager _serviceManager;
    private readonly NativeMessagingManifestService _nativeMessagingManifestService;

    public NativeInstallEngine(
        IPolicyService policyService,
        IDesktopIntegrationService desktopIntegrationService,
        RuntimeRestartService runtimeRestartService,
        ConfigMaterializer configMaterializer,
        InstallValidationService? installValidationService = null,
        WindowsServiceManager? serviceManager = null,
        NativeMessagingManifestService? nativeMessagingManifestService = null)
    {
        _policyService = policyService;
        _desktopIntegrationService = desktopIntegrationService;
        _runtimeRestartService = runtimeRestartService;
        _configMaterializer = configMaterializer;
        _nativeMessagingManifestService = nativeMessagingManifestService ?? new NativeMessagingManifestService();
        _installValidationService = installValidationService ?? new InstallValidationService(_nativeMessagingManifestService);
        _serviceManager = serviceManager ?? new WindowsServiceManager();
    }

    public Task<InstallerResult> RepairAsync(InstallRequest request, CancellationToken cancellationToken) =>
        InstallAsync(request, cancellationToken);

    public async Task<InstallerResult> InstallAsync(InstallRequest request, CancellationToken cancellationToken)
    {
        SetupActionLogger? logger = null;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var installRoot = request.InstallRoot;
            Directory.CreateDirectory(installRoot);
            Directory.CreateDirectory(Path.Combine(installRoot, "logs"));
            Directory.CreateDirectory(Path.Combine(installRoot, "manifests"));
            logger = new SetupActionLogger(installRoot);
            logger.Info("install", $"Starting native install flow for {installRoot}.");

            var warnings = new List<string>();
            var preflightResult = _installValidationService.ValidateInstallLayout(installRoot);
            warnings.AddRange(preflightResult.Warnings);
            LogResult(logger, "preflight", preflightResult);
            if (!preflightResult.Success)
            {
                return BuildFailure(
                    installRoot,
                    logger,
                    "preflight",
                    preflightResult.Message,
                    preflightResult.Errors,
                    warnings,
                    "Confirm the MSI payload completed file installation and rerun repair.");
            }

            var configPath = _configMaterializer.WriteInstallConfig(request);
            logger.Info("config", $"Generated install config at {configPath}.");
            var daemonPath = Path.Combine(installRoot, "ai-guard-daemon.exe");
            var hive = WindowsPolicyService.ResolveRegistryHive(configPath);

            if (hive == Microsoft.Win32.RegistryHive.LocalMachine)
            {
                var cleanupResult = _installValidationService.CleanupMachineScopeUserOverrides(installRoot);
                warnings.AddRange(cleanupResult.Warnings);
                LogResult(logger, "preflight", cleanupResult);
            }

            if (hive == Microsoft.Win32.RegistryHive.LocalMachine && File.Exists(daemonPath))
            {
                logger.Info("service create/update", $"Ensuring Windows service AIGuardAgent points to {daemonPath}.");
                _serviceManager.EnsureService(
                    "AIGuardAgent",
                    "Ulti Guard",
                    "Protects Claude sessions, scans prompts for PII, and blocks competing LLM tools.",
                    $"\"{daemonPath}\" --config \"{configPath}\" service");
            }

            var nativeManifestResult = _nativeMessagingManifestService.Configure(installRoot, configPath);
            warnings.AddRange(nativeManifestResult.Warnings);
            LogNativeManifestResult(logger, "native messaging", nativeManifestResult);
            if (!nativeManifestResult.Success)
            {
                return BuildFailure(
                    installRoot,
                    logger,
                    "native messaging",
                    nativeManifestResult.Message,
                    new[] { nativeManifestResult.Message },
                    warnings,
                    "Run repair again after confirming the native messaging manifest paths and registry entries are writable.");
            }

            var policyResult = await _policyService.ApplyFromConfigAsync(configPath, cancellationToken);
            warnings.AddRange(policyResult.Warnings);
            logger.Info("policy", policyResult.Message);
            foreach (var warning in policyResult.Warnings)
            {
                logger.Warn("policy", warning);
            }
            if (!policyResult.Success)
            {
                return BuildFailure(
                    installRoot,
                    logger,
                    "policy",
                    policyResult.Message,
                    new[] { policyResult.Message },
                    warnings,
                    "Run repair again after confirming Chrome and Edge policy keys can be updated.");
            }

            var desktopResult = await _desktopIntegrationService.ConfigureAsync(installRoot, configPath, cancellationToken);
            warnings.AddRange(desktopResult.Warnings);
            logger.Info("desktop", desktopResult.Message);
            foreach (var warning in desktopResult.Warnings)
            {
                logger.Warn("desktop", warning);
            }

            var runtimeResult = await _runtimeRestartService.RestartAsync(installRoot, configPath, cancellationToken, logger);
            if (!runtimeResult.Success)
            {
                warnings.Add(runtimeResult.Message);
                return BuildFailure(
                    installRoot,
                    logger,
                    "readyz",
                    runtimeResult.Message,
                    new[] { runtimeResult.DiagnosticMessage },
                    warnings,
                    "Run repair again with administrative rights and confirm the Ulti Guard daemon can bind its configured listen address.");
            }

            // Launch the desktop session helper in the interactive user's session
            LaunchDesktopSessionHelper(installRoot, configPath, logger);

            var verificationResult = await _installValidationService.VerifyRuntimeAsync(configPath, cancellationToken);
            warnings.AddRange(verificationResult.Warnings);
            LogResult(logger, "verification", verificationResult);
            if (!verificationResult.Success)
            {
                return BuildFailure(
                    installRoot,
                    logger,
                    "smoke scan",
                    verificationResult.Message,
                    verificationResult.Errors,
                    warnings,
                    "Review the setup-actions log and rerun repair after fixing the failing runtime probe.");
            }

            logger.Info("install", "Ulti Guard native install flow completed successfully.");
            return InstallerResult.Succeeded(
                "Ulti Guard installation completed.",
                installRoot,
                "machine",
                chromeReady: policyResult.Success,
                edgeReady: policyResult.Success,
                privateModeStrategy: "managed_policy",
                desktopProtectionMode: desktopResult.DesktopProtectionMode,
                warnings);
        }
        catch (Exception ex)
        {
            logger?.Error("rollback reason", "Ulti Guard native install flow failed.", ex);
            return BuildFailure(
                request.InstallRoot,
                logger,
                "rollback reason",
                ex.Message,
                new[] { ex.Message },
                Array.Empty<string>(),
                "Review the generated config and rerun repair after confirming the install layout.");
        }
    }

    public async Task<InstallerResult> UninstallAsync(UninstallRequest request, CancellationToken cancellationToken)
    {
        var configPath = Path.Combine(request.InstallRoot, "config", "ai-guard.json");
        var warnings = new List<string>();
        SetupActionLogger? logger = null;
        try
        {
            logger = new SetupActionLogger(request.InstallRoot);
            logger.Info("uninstall", $"Starting native uninstall cleanup for {request.InstallRoot}.");
            if (File.Exists(configPath))
            {
                var desktopResult = await _desktopIntegrationService.RestoreAsync(request.InstallRoot, configPath, cancellationToken);
                warnings.AddRange(desktopResult.Warnings);
                logger.Info("desktop", desktopResult.Message);
                var policyResult = await _policyService.RemoveManagedPoliciesAsync(configPath, cancellationToken);
                warnings.AddRange(policyResult.Warnings);
                logger.Info("policy", policyResult.Message);
                var manifestResult = _nativeMessagingManifestService.Remove(request.InstallRoot, configPath);
                warnings.AddRange(manifestResult.Warnings);
                LogNativeManifestResult(logger, "native messaging", manifestResult);
            }
            else
            {
                var manifestResult = _nativeMessagingManifestService.Remove(request.InstallRoot, null);
                warnings.AddRange(manifestResult.Warnings);
                LogNativeManifestResult(logger, "native messaging", manifestResult);
            }

            _serviceManager.DeleteServiceIfPresent("AIGuardAgent");
            logger.Info("service cleanup", "Removed Windows service AIGuardAgent if present.");

            return InstallerResult.Uninstalled(
                "Ulti Guard uninstall cleanup completed.",
                request.InstallRoot,
                "machine",
                warnings);
        }
        catch (Exception ex)
        {
            logger?.Error("rollback reason", "Ulti Guard native uninstall cleanup failed.", ex);
            return InstallerResult.Failed(
                ex.Message,
                request.InstallRoot,
                "machine",
                "Run uninstall cleanup again after closing Claude and the admin console.",
                errors: new[] { ex.Message },
                warnings: warnings);
        }
    }

    private static void LogResult(SetupActionLogger logger, string phase, InstallFlowResult result)
    {
        if (result.Success)
        {
            logger.Info(phase, result.Message);
        }
        else
        {
            logger.Error(phase, result.Message);
        }

        foreach (var error in result.Errors)
        {
            logger.Error(phase, error);
        }

        foreach (var warning in result.Warnings)
        {
            logger.Warn(phase, warning);
        }
    }

    private static void LogNativeManifestResult(SetupActionLogger logger, string phase, NativeManifestResult result)
    {
        if (result.Success)
        {
            logger.Info(phase, result.Message);
        }
        else
        {
            logger.Error(phase, result.Message);
        }

        foreach (var warning in result.Warnings)
        {
            logger.Warn(phase, warning);
        }
    }

    private static InstallerResult BuildFailure(
        string installRoot,
        SetupActionLogger? logger,
        string phase,
        string message,
        IEnumerable<string> errors,
        IEnumerable<string> warnings,
        string rollbackHint)
    {
        var logPath = logger?.LogPath ?? Path.Combine(installRoot, "logs", "setup-actions.log");
        logger?.Error("rollback reason", $"{phase} failed: {message}");
        return InstallerResult.Failed(
            message,
            installRoot,
            "machine",
            $"{rollbackHint} Review {logPath}.",
            errors: errors,
            warnings: warnings);
    }

    private static void LaunchDesktopSessionHelper(string installRoot, string configPath, SetupActionLogger? logger)
    {
        var helperPath = Path.Combine(installRoot, "desktop-session", "AIGuard.DesktopSessionHelper.exe");
        if (!File.Exists(helperPath))
        {
            logger?.Warn("desktop helper", $"Session helper executable not found at {helperPath}. Skipping interactive launch.");
            return;
        }

        logger?.Info("desktop helper", "Attempting interactive session launch of AIGuard.DesktopSessionHelper.exe via schtasks.");

        var taskName = "AIGuardSessionLaunch";
        var arguments = $"--config \\\"{configPath}\\\"";
        var schtasksCreateCmd = $"/create /tn \"{taskName}\" /tr \"\\\"{helperPath}\\\" {arguments}\" /sc once /st 00:00 /sd 01/01/2010 /ru \"INTERACTIVE\" /f";
        var schtasksRunCmd = $"/run /tn \"{taskName}\"";
        var schtasksDeleteCmd = $"/delete /tn \"{taskName}\" /f";

        try
        {
            RunCmd(schtasksCreateCmd);
            RunCmd(schtasksRunCmd);
            logger?.Info("desktop helper", "Interactive session launch scheduled and triggered successfully.");
        }
        catch (Exception ex)
        {
            logger?.Error("desktop helper", "Failed to schedule or run interactive session launch task.", ex);
        }
        finally
        {
            try
            {
                RunCmd(schtasksDeleteCmd);
            }
            catch { }
        }
    }

    private static void RunCmd(string arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "schtasks.exe",
            Arguments = arguments,
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        using (var process = Process.Start(startInfo))
        {
            process?.WaitForExit(5000);
        }
    }
}
