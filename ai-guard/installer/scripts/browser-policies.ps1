function Convert-PolicyObjectToHashtable {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) {
            $table[$key] = Convert-PolicyObjectToHashtable $InputObject[$key]
        }
        return $table
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(Convert-PolicyObjectToHashtable $item)
        }
        return $items
    }

    if ($InputObject -is [pscustomobject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = Convert-PolicyObjectToHashtable $property.Value
        }
        return $table
    }

    return $InputObject
}

function Get-RegistryStringValue {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Name
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.OpenSubKey($KeyPath, $false)
        if (-not $key) {
            return $null
        }

        try {
            return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Set-RegistryStringValue {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Name,
        [string]$Value
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.CreateSubKey($KeyPath)
        try {
            $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String)
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Remove-RegistryValueIfPresent {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Name
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.OpenSubKey($KeyPath, $true)
        if (-not $key) {
            return
        }

        try {
            $key.DeleteValue($Name, $false)
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Set-RegistryStringListEntry {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Value
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.CreateSubKey($KeyPath)
        try {
            $matchingName = $null
            $maxIndex = 0

            foreach ($name in $key.GetValueNames()) {
                $currentValue = [string]$key.GetValue($name)
                if ($currentValue -eq $Value) {
                    $matchingName = $name
                }

                $index = 0
                if ([int]::TryParse($name, [ref]$index) -and $index -gt $maxIndex) {
                    $maxIndex = $index
                }
            }

            if (-not $matchingName) {
                $matchingName = [string]($maxIndex + 1)
            }

            $key.SetValue($matchingName, $Value, [Microsoft.Win32.RegistryValueKind]::String)
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Remove-RegistryStringListEntry {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Value
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.OpenSubKey($KeyPath, $true)
        if (-not $key) {
            return
        }

        try {
            foreach ($name in @($key.GetValueNames())) {
                $currentValue = [string]$key.GetValue($name)
                if ($currentValue -eq $Value) {
                    $key.DeleteValue($name, $false)
                }
            }
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Set-RegistryDwordValue {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string]$Name,
        [int]$Value
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.CreateSubKey($KeyPath)
        try {
            $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Get-BrowserPolicyRoot {
    param(
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser
    )

    if ($Browser -eq "Chrome") {
        return "SOFTWARE\Policies\Google\Chrome"
    }

    return "SOFTWARE\Policies\Microsoft\Edge"
}

function Get-MandatoryPrivateBrowsingPolicyPath {
    param(
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser
    )

    if ($Browser -eq "Chrome") {
        return "SOFTWARE\Policies\Google\Chrome\MandatoryExtensionsForIncognitoNavigation"
    }

    return "SOFTWARE\Policies\Microsoft\Edge\MandatoryExtensionsForInPrivateNavigation"
}

function Get-ExtensionSettingsValue {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser
    )

    $policyRoot = Get-BrowserPolicyRoot -Browser $Browser
    $raw = Get-RegistryStringValue -Hive $Hive -KeyPath $policyRoot -Name "ExtensionSettings"
    if (-not $raw) {
        return @{}
    }

    try {
        $parsed = ConvertFrom-Json -InputObject $raw
    } catch {
        throw "Existing $Browser ExtensionSettings policy is not valid JSON and won't be overwritten."
    }

    $table = Convert-PolicyObjectToHashtable $parsed
    if (-not $table) {
        return @{}
    }

    return $table
}

function Save-ExtensionSettingsValue {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [hashtable]$Settings
    )

    $policyRoot = Get-BrowserPolicyRoot -Browser $Browser
    if (-not $Settings -or $Settings.Count -eq 0) {
        Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $policyRoot -Name "ExtensionSettings"
        return
    }

    $json = $Settings | ConvertTo-Json -Depth 20 -Compress
    Set-RegistryStringValue -Hive $Hive -KeyPath $policyRoot -Name "ExtensionSettings" -Value $json
}

function Set-ForceInstallListEntry {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string]$ExtensionId,
        [string]$UpdateUrl
    )

    $policyRoot = Join-Path (Get-BrowserPolicyRoot -Browser $Browser) "ExtensionInstallForcelist"
    $entryValue = if ($UpdateUrl) { "$ExtensionId;$UpdateUrl" } else { $ExtensionId }

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.CreateSubKey($policyRoot)
        try {
            $matchingName = $null
            $maxIndex = 0

            foreach ($name in $key.GetValueNames()) {
                $currentValue = [string]$key.GetValue($name)
                $prefix = if ($currentValue.Contains(";")) { $currentValue.Split(";", 2)[0] } else { $currentValue }
                if ($prefix -eq $ExtensionId) {
                    $matchingName = $name
                }

                $index = 0
                if ([int]::TryParse($name, [ref]$index) -and $index -gt $maxIndex) {
                    $maxIndex = $index
                }
            }

            if (-not $matchingName) {
                $matchingName = [string]($maxIndex + 1)
            }

            $key.SetValue($matchingName, $entryValue, [Microsoft.Win32.RegistryValueKind]::String)
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Remove-ForceInstallListEntry {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string]$ExtensionId
    )

    $policyRoot = Join-Path (Get-BrowserPolicyRoot -Browser $Browser) "ExtensionInstallForcelist"
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.OpenSubKey($policyRoot, $true)
        if (-not $key) {
            return
        }

        try {
            foreach ($name in @($key.GetValueNames())) {
                $currentValue = [string]$key.GetValue($name)
                $prefix = if ($currentValue.Contains(";")) { $currentValue.Split(";", 2)[0] } else { $currentValue }
                if ($prefix -eq $ExtensionId) {
                    $key.DeleteValue($name, $false)
                }
            }
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Set-ManagedExtensionPolicy {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string]$ExtensionId,
        [string]$UpdateUrl,
        [string]$MinimumVersionRequired,
        [switch]$BlockOtherExtensions,
        [string[]]$AllowedExtensionIds = @(),
        [string]$BlockedInstallMessage = "Only company-approved browser extensions are allowed.",
        [switch]$RequirePrivateBrowsingGuard,
        [switch]$DisallowExtensionDeveloperMode,
        [switch]$DisableDeveloperTools
    )

    $settings = Get-ExtensionSettingsValue -Hive $Hive -Browser $Browser
    if (-not $settings.ContainsKey($ExtensionId)) {
        $settings[$ExtensionId] = @{}
    }

    $settings[$ExtensionId]["installation_mode"] = "force_installed"
    $settings[$ExtensionId]["update_url"] = $UpdateUrl
    $settings[$ExtensionId]["override_update_url"] = $true

    if ($MinimumVersionRequired) {
        $settings[$ExtensionId]["minimum_version_required"] = $MinimumVersionRequired
    }

    if ($BlockOtherExtensions) {
        if (-not $settings.ContainsKey("*")) {
            $settings["*"] = @{}
        }
        $settings["*"]["installation_mode"] = "blocked"
        $settings["*"]["blocked_install_message"] = $BlockedInstallMessage
    }

    foreach ($allowedExtensionId in @($AllowedExtensionIds | Where-Object { $_ -and $_ -ne $ExtensionId } | Select-Object -Unique)) {
        if (-not $settings.ContainsKey($allowedExtensionId)) {
            $settings[$allowedExtensionId] = @{
                installation_mode = "allowed"
            }
        }
    }

    Save-ExtensionSettingsValue -Hive $Hive -Browser $Browser -Settings $settings
    Set-ForceInstallListEntry -Hive $Hive -Browser $Browser -ExtensionId $ExtensionId -UpdateUrl $UpdateUrl

    $policyRoot = Get-BrowserPolicyRoot -Browser $Browser
    if ($DisallowExtensionDeveloperMode) {
        Set-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name "ExtensionDeveloperModeSettings" -Value 1
    }

    if ($DisableDeveloperTools) {
        Set-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name "DeveloperToolsAvailability" -Value 2
    }

    $privateBrowsingPolicyPath = Get-MandatoryPrivateBrowsingPolicyPath -Browser $Browser
    if ($RequirePrivateBrowsingGuard) {
        Set-RegistryStringListEntry -Hive $Hive -KeyPath $privateBrowsingPolicyPath -Value $ExtensionId
    } else {
        Remove-RegistryStringListEntry -Hive $Hive -KeyPath $privateBrowsingPolicyPath -Value $ExtensionId
    }
}

function Remove-ManagedExtensionPolicy {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string]$ExtensionId
    )

    $settings = Get-ExtensionSettingsValue -Hive $Hive -Browser $Browser
    if ($settings.ContainsKey($ExtensionId)) {
        $settings.Remove($ExtensionId)
        Save-ExtensionSettingsValue -Hive $Hive -Browser $Browser -Settings $settings
    }

    Remove-ForceInstallListEntry -Hive $Hive -Browser $Browser -ExtensionId $ExtensionId
    Remove-RegistryStringListEntry `
        -Hive $Hive `
        -KeyPath (Get-MandatoryPrivateBrowsingPolicyPath -Browser $Browser) `
        -Value $ExtensionId
}
