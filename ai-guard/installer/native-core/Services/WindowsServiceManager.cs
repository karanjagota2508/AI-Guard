using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AIGuard.Native.Services;

public sealed class WindowsServiceManager
{
    public void EnsureService(string name, string displayName, string description, string binaryPath)
    {
        var manager = OpenSCManager(null, null, ScManagerAccess.AllAccess);
        if (manager == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Failed to open the Windows service control manager.");
        }

        try
        {
            var service = OpenService(manager, name, ServiceAccess.AllAccess);
            if (service == IntPtr.Zero)
            {
                service = CreateService(
                    manager,
                    name,
                    displayName,
                    ServiceAccess.AllAccess,
                    ServiceType.Win32OwnProcess,
                    ServiceStartType.AutoStart,
                    ServiceErrorControl.Normal,
                    binaryPath,
                    null,
                    IntPtr.Zero,
                    null,
                    null,
                    null);

                if (service == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), $"Failed to create Windows service {name}.");
                }
            }
            else
            {
                if (!ChangeServiceConfig(
                        service,
                        ServiceType.Win32OwnProcess,
                        ServiceStartType.AutoStart,
                        ServiceErrorControl.Normal,
                        binaryPath,
                        null,
                        IntPtr.Zero,
                        null,
                        null,
                        null,
                        displayName))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), $"Failed to update Windows service {name}.");
                }
            }

            try
            {
                ChangeServiceDescription(service, description);
            }
            catch
            {
            }
        }
        finally
        {
            CloseServiceHandle(manager);
        }
    }

    public void DeleteServiceIfPresent(string name)
    {
        var manager = OpenSCManager(null, null, ScManagerAccess.AllAccess);
        if (manager == IntPtr.Zero)
        {
            return;
        }

        try
        {
            var service = OpenService(manager, name, ServiceAccess.AllAccess);
            if (service == IntPtr.Zero)
            {
                return;
            }

            try
            {
                ControlService(service, ServiceControl.Stop, out _);
                DeleteService(service);
            }
            finally
            {
                CloseServiceHandle(service);
            }
        }
        finally
        {
            CloseServiceHandle(manager);
        }
    }

    private static void ChangeServiceDescription(IntPtr service, string description)
    {
        var descriptionStruct = new SERVICE_DESCRIPTION
        {
            lpDescription = description
        };
        var buffer = Marshal.AllocHGlobal(Marshal.SizeOf<SERVICE_DESCRIPTION>());
        try
        {
            Marshal.StructureToPtr(descriptionStruct, buffer, false);
            if (!ChangeServiceConfig2(service, 1, buffer))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Failed to set the Windows service description.");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr OpenSCManager(string? machineName, string? databaseName, ScManagerAccess desiredAccess);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateService(
        IntPtr hScManager,
        string lpServiceName,
        string lpDisplayName,
        ServiceAccess dwDesiredAccess,
        ServiceType dwServiceType,
        ServiceStartType dwStartType,
        ServiceErrorControl dwErrorControl,
        string lpBinaryPathName,
        string? lpLoadOrderGroup,
        IntPtr lpdwTagId,
        string? lpDependencies,
        string? lpServiceStartName,
        string? lpPassword);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr OpenService(IntPtr hScManager, string lpServiceName, ServiceAccess dwDesiredAccess);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool ChangeServiceConfig(
        IntPtr hService,
        ServiceType dwServiceType,
        ServiceStartType dwStartType,
        ServiceErrorControl dwErrorControl,
        string lpBinaryPathName,
        string? lpLoadOrderGroup,
        IntPtr lpdwTagId,
        string? lpDependencies,
        string? lpServiceStartName,
        string? lpPassword,
        string? lpDisplayName);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool ChangeServiceConfig2(IntPtr hService, int dwInfoLevel, IntPtr lpInfo);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DeleteService(IntPtr hService);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CloseServiceHandle(IntPtr hScObject);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool ControlService(IntPtr hService, ServiceControl dwControl, out SERVICE_STATUS lpServiceStatus);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SERVICE_DESCRIPTION
    {
        public string lpDescription;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS
    {
        public int dwServiceType;
        public int dwCurrentState;
        public int dwControlsAccepted;
        public int dwWin32ExitCode;
        public int dwServiceSpecificExitCode;
        public int dwCheckPoint;
        public int dwWaitHint;
    }

    [Flags]
    private enum ScManagerAccess : uint
    {
        AllAccess = 0xF003F
    }

    [Flags]
    private enum ServiceAccess : uint
    {
        AllAccess = 0xF01FF
    }

    private enum ServiceType : uint
    {
        Win32OwnProcess = 0x00000010
    }

    private enum ServiceStartType : uint
    {
        AutoStart = 0x00000002
    }

    private enum ServiceErrorControl : uint
    {
        Normal = 0x00000001
    }

    private enum ServiceControl : uint
    {
        Stop = 0x00000001
    }
}
