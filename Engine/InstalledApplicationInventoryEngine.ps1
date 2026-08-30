#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Installed Application Inventory Engine
.DESCRIPTION
    Collects read-only installed-application evidence from Windows uninstall
    registry locations. This module intentionally avoids Win32_Product because
    querying that provider can trigger MSI consistency checks/repairs.

    SAFETY CONTRACT:
        - Read-only. Never install, uninstall, repair, modify, or remove software.
        - Uninstall command strings are never retained in inventory output.
        - Registry evidence is collected from machine 64-bit, machine 32-bit,
          and current-user uninstall locations.
        - Duplicate registry evidence for the same scoped product key is merged
          while preserving every evidence source.
        - Missing entries are not interpreted as "unused" or "safe to remove".
          Usage classification belongs to a later evidence layer.
.NOTES
    Module      : InstalledApplicationInventoryEngine.ps1
    Layer       : Engine
    Build Phase : Phase 4 - System Inventory / Audit
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TetraObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
    return $property.Value
}

function ConvertTo-TetraApplicationInstallDate {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }

    if ($text -match '^\d{8}$') {
        try {
            $parsed = [datetime]::ParseExact($text, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
            return $parsed.ToString('yyyy-MM-dd')
        }
        catch { return $text }
    }

    return $text
}

function Get-TetraUninstallRegistryEntries {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    $targets = @(
        [PSCustomObject]@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64; Scope = 'Machine'; ViewName = '64-bit'; RootLabel = 'HKLM' },
        [PSCustomObject]@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32; Scope = 'Machine'; ViewName = '32-bit'; RootLabel = 'HKLM' },
        [PSCustomObject]@{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser;  View = [Microsoft.Win32.RegistryView]::Default;    Scope = 'CurrentUser'; ViewName = 'Default'; RootLabel = 'HKCU' }
    )

    $relativePath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($target in $targets) {
        $baseKey = $null
        $uninstallKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($target.Hive, $target.View)
            $uninstallKey = $baseKey.OpenSubKey($relativePath, $false)
            if ($null -eq $uninstallKey) { continue }

            foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                $subKey = $null
                try {
                    $subKey = $uninstallKey.OpenSubKey($subKeyName, $false)
                    if ($null -eq $subKey) { continue }

                    $results.Add([PSCustomObject]@{
                        DisplayName       = $subKey.GetValue('DisplayName', '')
                        DisplayVersion    = $subKey.GetValue('DisplayVersion', '')
                        Publisher         = $subKey.GetValue('Publisher', '')
                        InstallLocation   = $subKey.GetValue('InstallLocation', '')
                        InstallDate       = $subKey.GetValue('InstallDate', '')
                        EstimatedSize     = $subKey.GetValue('EstimatedSize', 0)
                        SystemComponent   = $subKey.GetValue('SystemComponent', 0)
                        WindowsInstaller  = $subKey.GetValue('WindowsInstaller', 0)
                        ReleaseType       = $subKey.GetValue('ReleaseType', '')
                        ParentDisplayName = $subKey.GetValue('ParentDisplayName', '')
                        RegistryKeyName   = $subKeyName
                        SourceScope       = $target.Scope
                        RegistryView      = $target.ViewName
                        RegistryKeyPath   = "$($target.RootLabel)\$relativePath\$subKeyName"
                    })
                }
                finally {
                    if ($null -ne $subKey) { $subKey.Dispose() }
                }
            }
        }
        finally {
            if ($null -ne $uninstallKey) { $uninstallKey.Dispose() }
            if ($null -ne $baseKey) { $baseKey.Dispose() }
        }
    }

    return $results.ToArray()
}

function New-TetraInstalledApplicationRecord {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][object]$RegistryEntry,
        [Parameter(Mandatory = $false)][string]$ObservedUtc = ((Get-Date).ToUniversalTime().ToString('o'))
    )

    $displayName = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'DisplayName' -DefaultValue '')
    $version = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'DisplayVersion' -DefaultValue '')
    $publisher = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'Publisher' -DefaultValue '')
    $location = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'InstallLocation' -DefaultValue '')
    $scope = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'SourceScope' -DefaultValue 'Unknown')
    $view = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'RegistryView' -DefaultValue 'Unknown')
    $keyName = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'RegistryKeyName' -DefaultValue '')
    $keyPath = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'RegistryKeyPath' -DefaultValue '')
    $estimatedSizeKb = 0L
    try { $estimatedSizeKb = [long](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'EstimatedSize' -DefaultValue 0) } catch { $estimatedSizeKb = 0L }

    $systemComponent = $false
    $windowsInstaller = $false
    try { $systemComponent = ([int](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'SystemComponent' -DefaultValue 0) -eq 1) } catch { }
    try { $windowsInstaller = ([int](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'WindowsInstaller' -DefaultValue 0) -eq 1) } catch { }

    return [PSCustomObject]@{
        RecordType                = 'InstalledApplication'
        Category                  = 'Applications'
        DisplayName               = $displayName.Trim()
        DisplayVersion            = $version.Trim()
        Publisher                 = $publisher.Trim()
        InstallLocation           = $location.Trim()
        InstallLocationAvailable  = (-not [string]::IsNullOrWhiteSpace($location))
        InstallDate               = (ConvertTo-TetraApplicationInstallDate -Value (Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'InstallDate' -DefaultValue ''))
        EstimatedSizeBytes        = ($estimatedSizeKb * 1024L)
        IsSystemComponent         = $systemComponent
        IsWindowsInstallerProduct = $windowsInstaller
        ReleaseType               = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'ReleaseType' -DefaultValue '')
        ParentDisplayName         = [string](Get-TetraObjectPropertyValue -InputObject $RegistryEntry -Name 'ParentDisplayName' -DefaultValue '')
        SourceScope               = $scope
        RegistryKeyName           = $keyName
        RegistryViews             = @($view)
        RegistryKeyPaths          = @($keyPath)
        SourceCount               = 1
        EvidenceSource            = 'WindowsUninstallRegistry'
        UninstallCommandCaptured  = $false
        ObservedUtc               = $ObservedUtc
    }
}

function Get-TetraApplicationIdentityKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][PSCustomObject]$Record)

    if (-not [string]::IsNullOrWhiteSpace($Record.RegistryKeyName)) {
        return ('{0}|KEY|{1}' -f $Record.SourceScope.ToLowerInvariant(), $Record.RegistryKeyName.ToLowerInvariant())
    }

    return ('{0}|META|{1}|{2}|{3}|{4}' -f
        $Record.SourceScope.ToLowerInvariant(),
        $Record.DisplayName.ToLowerInvariant(),
        $Record.DisplayVersion.ToLowerInvariant(),
        $Record.Publisher.ToLowerInvariant(),
        $Record.InstallLocation.ToLowerInvariant())
}

function Get-TetraInstalledApplicationInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$RegistryEntries = $null
    )

    try {
        if ($null -eq $RegistryEntries) {
            $RegistryEntries = @(Get-TetraUninstallRegistryEntries)
        }

        $observedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $byIdentity = @{}
        $order = [System.Collections.Generic.List[string]]::new()

        foreach ($entry in @($RegistryEntries)) {
            if ($null -eq $entry) { continue }
            $record = New-TetraInstalledApplicationRecord -RegistryEntry $entry -ObservedUtc $observedUtc
            if ([string]::IsNullOrWhiteSpace($record.DisplayName)) { continue }

            $identity = Get-TetraApplicationIdentityKey -Record $record
            if (-not $byIdentity.ContainsKey($identity)) {
                $byIdentity[$identity] = $record
                $order.Add($identity)
                continue
            }

            $existing = $byIdentity[$identity]
            $existing.SourceCount = [int]$existing.SourceCount + 1
            $existing.RegistryViews = @($existing.RegistryViews + $record.RegistryViews | Select-Object -Unique)
            $existing.RegistryKeyPaths = @($existing.RegistryKeyPaths + $record.RegistryKeyPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

            if ([string]::IsNullOrWhiteSpace($existing.InstallLocation) -and -not [string]::IsNullOrWhiteSpace($record.InstallLocation)) {
                $existing.InstallLocation = $record.InstallLocation
                $existing.InstallLocationAvailable = $true
            }
            if ([string]::IsNullOrWhiteSpace($existing.DisplayVersion) -and -not [string]::IsNullOrWhiteSpace($record.DisplayVersion)) { $existing.DisplayVersion = $record.DisplayVersion }
            if ([string]::IsNullOrWhiteSpace($existing.Publisher) -and -not [string]::IsNullOrWhiteSpace($record.Publisher)) { $existing.Publisher = $record.Publisher }
            if ($existing.EstimatedSizeBytes -eq 0 -and $record.EstimatedSizeBytes -gt 0) { $existing.EstimatedSizeBytes = $record.EstimatedSizeBytes }
        }

        $records = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($identity in $order) { $records.Add($byIdentity[$identity]) }

        if (Get-Command -Name Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Info' -Module 'InstalledApplicationInventoryEngine' -Action 'ApplicationInventory' -Target 'UninstallRegistry' `
                -Result 'Success' -Message "Collected $($records.Count) installed application record(s) without modifying system state." | Out-Null
        }

        return $records.ToArray()
    }
    catch {
        if (Get-Command -Name Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Error' -Module 'InstalledApplicationInventoryEngine' -Action 'ApplicationInventory' -Target 'UninstallRegistry' `
                -Result 'Failed' -Message $_.Exception.Message | Out-Null
        }
        throw "Get-TetraInstalledApplicationInventory: Failed to collect installed application inventory - $($_.Exception.Message)"
    }
}

# Public Functions:
#   - Get-TetraInstalledApplicationInventory
# Internal Functions:
#   - Get-TetraObjectPropertyValue
#   - ConvertTo-TetraApplicationInstallDate
#   - Get-TetraUninstallRegistryEntries
#   - New-TetraInstalledApplicationRecord
#   - Get-TetraApplicationIdentityKey
