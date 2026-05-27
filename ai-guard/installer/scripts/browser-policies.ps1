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

function Get-RegistryDwordValue {
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
            $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $value) {
                return $null
            }

            return [int]$value
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Remove-RegistryKeyIfPresent {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $baseKey.DeleteSubKeyTree($KeyPath, $false)
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

function Get-BrowserPolicyStateRoot {
    param(
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser
    )

    return "SOFTWARE\WinInfoSoft\AI Guard Agent\PolicyState\$Browser"
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

function Get-PrivateBrowsingAvailabilityPolicyName {
    param(
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser
    )

    if ($Browser -eq "Chrome") {
        return "IncognitoModeAvailability"
    }

    return "InPrivateModeAvailability"
}

function Get-RegistryStringListValues {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.OpenSubKey($KeyPath, $false)
        if (-not $key) {
            return @()
        }

        try {
            $entries = foreach ($name in $key.GetValueNames()) {
                [pscustomobject]@{
                    Name = $name
                    Value = [string]$key.GetValue($name)
                }
            }

            return @(
                $entries |
                    Sort-Object @{
                        Expression = {
                            $number = 0
                            if ([int]::TryParse($_.Name, [ref]$number)) {
                                return $number
                            }
                            return [int]::MaxValue
                        }
                    }, @{ Expression = { $_.Name } } |
                    ForEach-Object { $_.Value } |
                    Where-Object { $_ }
            )
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Save-RegistryStringListValues {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$KeyPath,
        [string[]]$Values
    )

    $normalized = @($Values | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
    Remove-RegistryKeyIfPresent -Hive $Hive -KeyPath $KeyPath

    if (-not $normalized -or $normalized.Count -eq 0) {
        return
    }

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $baseKey.CreateSubKey($KeyPath)
        try {
            for ($index = 0; $index -lt $normalized.Count; $index++) {
                $key.SetValue([string]($index + 1), $normalized[$index], [Microsoft.Win32.RegistryValueKind]::String)
            }
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
}

function Get-AIGuardStateStringList {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string]$Name
    )

    $raw = Get-RegistryStringValue -Hive $Hive -KeyPath (Get-BrowserPolicyStateRoot -Browser $Browser) -Name $Name
    if (-not $raw) {
        return @()
    }

    try {
        $parsed = ConvertFrom-Json -InputObject $raw
        return @($parsed | ForEach-Object { [string]$_ } | Where-Object { $_ })
    } catch {
        return @()
    }
}

function Set-AIGuardStateStringList {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string]$Name,
        [string[]]$Values
    )

    $stateRoot = Get-BrowserPolicyStateRoot -Browser $Browser
    $normalized = @($Values | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $normalized -or $normalized.Count -eq 0) {
        Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $stateRoot -Name $Name
        return
    }

    $json = $normalized | ConvertTo-Json -Compress
    Set-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name $Name -Value $json
}

function Set-AIGuardTrackedDwordPolicy {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string]$Name,
        [int]$Value
    )

    $policyRoot = Get-BrowserPolicyRoot -Browser $Browser
    $stateRoot = Get-BrowserPolicyStateRoot -Browser $Browser
    $trackedName = "$Name.Tracked"
    $previousWasSetName = "$Name.PreviousWasSet"
    $previousValueName = "$Name.PreviousValue"
    $tracked = Get-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name $trackedName

    if (-not $tracked) {
        $previousValue = Get-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name $Name
        Set-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name $trackedName -Value "true"
        Set-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name $previousWasSetName -Value ([string]($null -ne $previousValue)).ToLowerInvariant()

        if ($null -ne $previousValue) {
            Set-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name $previousValueName -Value ([string]$previousValue)
        } else {
            Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $stateRoot -Name $previousValueName
        }
    }

    Set-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name $Name -Value $Value
}

function Restore-AIGuardTrackedDwordPolicy {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string]$Name
    )

    $policyRoot = Get-BrowserPolicyRoot -Browser $Browser
    $stateRoot = Get-BrowserPolicyStateRoot -Browser $Browser
    $trackedName = "$Name.Tracked"
    $previousWasSetName = "$Name.PreviousWasSet"
    $previousValueName = "$Name.PreviousValue"
    $tracked = Get-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name $trackedName

    if (-not $tracked) {
        return
    }

    $previousWasSet = (Get-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name $previousWasSetName) -eq "true"
    if ($previousWasSet) {
        $previousValue = Get-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name $previousValueName
        if ($previousValue -match '^\d+$') {
            Set-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name $Name -Value ([int]$previousValue)
        }
    } else {
        Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $policyRoot -Name $Name
    }

    Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $stateRoot -Name $trackedName
    Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $stateRoot -Name $previousWasSetName
    Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $stateRoot -Name $previousValueName
}

function Normalize-PolicyHostList {
    param(
        [string[]]$Hosts
    )

    return @(
        $Hosts |
            ForEach-Object { ([string]$_).Trim().ToLowerInvariant().Trim('.') } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Set-AIGuardBrowserHostBlocklistPolicy {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string[]]$Hosts
    )

    $policyPath = Join-Path (Get-BrowserPolicyRoot -Browser $Browser) "URLBlocklist"
    $managedName = "ManagedUrlBlocklist"
    $desired = Normalize-PolicyHostList -Hosts $Hosts
    $existing = @((Get-RegistryStringListValues -Hive $Hive -KeyPath $policyPath) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $previousManaged = Normalize-PolicyHostList -Hosts (Get-AIGuardStateStringList -Hive $Hive -Browser $Browser -Name $managedName)
    $preserved = @($existing | Where-Object { $previousManaged -notcontains ([string]$_).Trim().ToLowerInvariant().Trim('.') })
    $combined = @($preserved + $desired | Select-Object -Unique)

    Save-RegistryStringListValues -Hive $Hive -KeyPath $policyPath -Values $combined
    Set-AIGuardStateStringList -Hive $Hive -Browser $Browser -Name $managedName -Values $desired
}

function Remove-AIGuardBrowserHostBlocklistPolicy {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser
    )

    $policyPath = Join-Path (Get-BrowserPolicyRoot -Browser $Browser) "URLBlocklist"
    $managedName = "ManagedUrlBlocklist"
    $existing = @((Get-RegistryStringListValues -Hive $Hive -KeyPath $policyPath) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $previousManaged = Normalize-PolicyHostList -Hosts (Get-AIGuardStateStringList -Hive $Hive -Browser $Browser -Name $managedName)
    $remaining = @($existing | Where-Object { $previousManaged -notcontains ([string]$_).Trim().ToLowerInvariant().Trim('.') })

    Save-RegistryStringListValues -Hive $Hive -KeyPath $policyPath -Values $remaining
    Set-AIGuardStateStringList -Hive $Hive -Browser $Browser -Name $managedName -Values @()
}

function Remove-AIGuardBrowserHostBlocklistPolicyEntries {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [string[]]$Hosts
    )

    $policyPath = Join-Path (Get-BrowserPolicyRoot -Browser $Browser) "URLBlocklist"
    $managedName = "ManagedUrlBlocklist"
    $existing = @((Get-RegistryStringListValues -Hive $Hive -KeyPath $policyPath) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $hostsToRemove = Normalize-PolicyHostList -Hosts $Hosts

    if ($hostsToRemove.Count -eq 0 -and $existing.Count -eq 0) {
        Set-AIGuardStateStringList -Hive $Hive -Browser $Browser -Name $managedName -Values @()
        return
    }

    $remaining = @(
        $existing |
            Where-Object {
                $normalized = ([string]$_).Trim().ToLowerInvariant().Trim('.')
                $hostsToRemove -notcontains $normalized
            }
    )

    Save-RegistryStringListValues -Hive $Hive -KeyPath $policyPath -Values $remaining
    Set-AIGuardStateStringList -Hive $Hive -Browser $Browser -Name $managedName -Values @()
}

function Set-AIGuardPrivateBrowsingPolicy {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser,
        [switch]$Disable
    )

    $policyRoot = Get-BrowserPolicyRoot -Browser $Browser
    $stateRoot = Get-BrowserPolicyStateRoot -Browser $Browser
    $valueName = Get-PrivateBrowsingAvailabilityPolicyName -Browser $Browser

    if (-not $Disable) {
        Restore-AIGuardPrivateBrowsingPolicy -Hive $Hive -Browser $Browser
        if ((Get-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name $valueName) -eq 1) {
            Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $policyRoot -Name $valueName
        }
        return
    }

    $tracked = Get-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPolicyTracked"
    if (-not $tracked) {
        $previousValue = Get-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name $valueName
        Set-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPolicyTracked" -Value "true"
        Set-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPreviousWasSet" -Value ([string]($null -ne $previousValue)).ToLowerInvariant()
        if ($null -ne $previousValue) {
            Set-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPreviousValue" -Value ([string]$previousValue)
        } else {
            Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPreviousValue"
        }
    }

    Set-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name $valueName -Value 1
}

function Restore-AIGuardPrivateBrowsingPolicy {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [ValidateSet("Chrome", "Edge")]
        [string]$Browser
    )

    $policyRoot = Get-BrowserPolicyRoot -Browser $Browser
    $stateRoot = Get-BrowserPolicyStateRoot -Browser $Browser
    $valueName = Get-PrivateBrowsingAvailabilityPolicyName -Browser $Browser
    $tracked = Get-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPolicyTracked"

    if (-not $tracked) {
        return
    }

    $previousWasSet = (Get-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPreviousWasSet") -eq "true"
    if ($previousWasSet) {
        $previousValue = Get-RegistryStringValue -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPreviousValue"
        if ($previousValue -match '^\d+$') {
            Set-RegistryDwordValue -Hive $Hive -KeyPath $policyRoot -Name $valueName -Value ([int]$previousValue)
        }
    } else {
        Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $policyRoot -Name $valueName
    }

    Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPolicyTracked"
    Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPreviousWasSet"
    Remove-RegistryValueIfPresent -Hive $Hive -KeyPath $stateRoot -Name "PrivateBrowsingPreviousValue"
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
        Set-AIGuardTrackedDwordPolicy -Hive $Hive -Browser $Browser -Name "ExtensionDeveloperModeSettings" -Value 1
    }

    if ($DisableDeveloperTools) {
        Set-AIGuardTrackedDwordPolicy -Hive $Hive -Browser $Browser -Name "DeveloperToolsAvailability" -Value 2
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

    Remove-AIGuardBrowserHostBlocklistPolicy -Hive $Hive -Browser $Browser
    Restore-AIGuardPrivateBrowsingPolicy -Hive $Hive -Browser $Browser
    Restore-AIGuardTrackedDwordPolicy -Hive $Hive -Browser $Browser -Name "ExtensionDeveloperModeSettings"
    Restore-AIGuardTrackedDwordPolicy -Hive $Hive -Browser $Browser -Name "DeveloperToolsAvailability"
}
