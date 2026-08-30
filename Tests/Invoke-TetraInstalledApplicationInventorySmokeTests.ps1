#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\InstalledApplicationInventoryEngine.ps1')

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body | Out-Null
        $results.Add([PSCustomObject]@{ TestName = $Name; Passed = $true; ErrorMessage = '' })
    }
    catch {
        $results.Add([PSCustomObject]@{ TestName = $Name; Passed = $false; ErrorMessage = $_.Exception.Message })
    }
}

function New-SyntheticApplicationEntry {
    param(
        [string]$DisplayName = 'Example App',
        [string]$DisplayVersion = '1.0.0',
        [string]$Publisher = 'Example Publisher',
        [string]$InstallLocation = 'C:\Program Files\Example App',
        [string]$InstallDate = '20260830',
        [long]$EstimatedSize = 2048,
        [int]$SystemComponent = 0,
        [int]$WindowsInstaller = 0,
        [string]$ReleaseType = '',
        [string]$ParentDisplayName = '',
        [string]$RegistryKeyName = '{11111111-1111-1111-1111-111111111111}',
        [string]$SourceScope = 'Machine',
        [string]$RegistryView = '64-bit',
        [string]$RegistryKeyPath = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\{11111111-1111-1111-1111-111111111111}',
        [string]$UninstallString = 'msiexec.exe /x {PRIVATE}'
    )

    return [PSCustomObject]@{
        DisplayName = $DisplayName
        DisplayVersion = $DisplayVersion
        Publisher = $Publisher
        InstallLocation = $InstallLocation
        InstallDate = $InstallDate
        EstimatedSize = $EstimatedSize
        SystemComponent = $SystemComponent
        WindowsInstaller = $WindowsInstaller
        ReleaseType = $ReleaseType
        ParentDisplayName = $ParentDisplayName
        RegistryKeyName = $RegistryKeyName
        SourceScope = $SourceScope
        RegistryView = $RegistryView
        RegistryKeyPath = $RegistryKeyPath
        UninstallString = $UninstallString
    }
}

Invoke-Test -Name 'Synthetic application becomes a correctly shaped inventory record' -Body {
    $records = @(Get-TetraInstalledApplicationInventory -RegistryEntries @((New-SyntheticApplicationEntry)))
    Assert-True ($records.Count -eq 1) "Expected one record, got $($records.Count)."
    $r = $records[0]
    Assert-True ($r.RecordType -eq 'InstalledApplication') 'RecordType mismatch.'
    Assert-True ($r.Category -eq 'Applications') 'Category mismatch.'
    Assert-True ($r.DisplayName -eq 'Example App') 'DisplayName mismatch.'
    Assert-True ($r.DisplayVersion -eq '1.0.0') 'DisplayVersion mismatch.'
    Assert-True ($r.Publisher -eq 'Example Publisher') 'Publisher mismatch.'
    Assert-True ($r.EvidenceSource -eq 'WindowsUninstallRegistry') 'Evidence source mismatch.'
}

Invoke-Test -Name 'Uninstall command is deliberately not retained' -Body {
    $record = @(Get-TetraInstalledApplicationInventory -RegistryEntries @((New-SyntheticApplicationEntry -UninstallString 'secret uninstall command')))[0]
    Assert-True (-not ($record.PSObject.Properties.Name -contains 'UninstallString')) 'UninstallString leaked into inventory output.'
    Assert-True (-not ($record.PSObject.Properties.Name -contains 'QuietUninstallString')) 'QuietUninstallString leaked into inventory output.'
    Assert-True ($record.UninstallCommandCaptured -eq $false) 'UninstallCommandCaptured should be false.'
}

Invoke-Test -Name 'YYYYMMDD install date is normalized' -Body {
    $record = @(Get-TetraInstalledApplicationInventory -RegistryEntries @((New-SyntheticApplicationEntry -InstallDate '20260131')))[0]
    Assert-True ($record.InstallDate -eq '2026-01-31') "Unexpected normalized install date '$($record.InstallDate)'."
}

Invoke-Test -Name 'Estimated registry size is converted from KB to bytes' -Body {
    $record = @(Get-TetraInstalledApplicationInventory -RegistryEntries @((New-SyntheticApplicationEntry -EstimatedSize 4096)))[0]
    Assert-True ($record.EstimatedSizeBytes -eq 4194304) "Expected 4194304 bytes, got $($record.EstimatedSizeBytes)."
}

Invoke-Test -Name 'System component and Windows Installer flags are preserved as evidence' -Body {
    $record = @(Get-TetraInstalledApplicationInventory -RegistryEntries @((New-SyntheticApplicationEntry -SystemComponent 1 -WindowsInstaller 1)))[0]
    Assert-True ($record.IsSystemComponent -eq $true) 'SystemComponent flag was not preserved.'
    Assert-True ($record.IsWindowsInstallerProduct -eq $true) 'WindowsInstaller flag was not preserved.'
}

Invoke-Test -Name 'Mirrored registry views for the same scoped product key are consolidated' -Body {
    $a = New-SyntheticApplicationEntry -RegistryView '64-bit' -RegistryKeyPath 'HKLM\64\ProductA'
    $b = New-SyntheticApplicationEntry -RegistryView '32-bit' -RegistryKeyPath 'HKLM\32\ProductA'
    $records = @(Get-TetraInstalledApplicationInventory -RegistryEntries @($a, $b))
    Assert-True ($records.Count -eq 1) "Expected one consolidated record, got $($records.Count)."
    Assert-True ($records[0].SourceCount -eq 2) 'SourceCount should be 2.'
    Assert-True (@($records[0].RegistryViews).Count -eq 2) 'Both registry views were not preserved.'
    Assert-True (@($records[0].RegistryKeyPaths).Count -eq 2) 'Both registry key paths were not preserved.'
}

Invoke-Test -Name 'Same product key in machine and current-user scope remains separate' -Body {
    $machine = New-SyntheticApplicationEntry -SourceScope 'Machine' -RegistryView '64-bit' -RegistryKeyPath 'HKLM\ProductA'
    $user = New-SyntheticApplicationEntry -SourceScope 'CurrentUser' -RegistryView 'Default' -RegistryKeyPath 'HKCU\ProductA'
    $records = @(Get-TetraInstalledApplicationInventory -RegistryEntries @($machine, $user))
    Assert-True ($records.Count -eq 2) "Expected two scoped records, got $($records.Count)."
}

Invoke-Test -Name 'Blank DisplayName registry entries are ignored' -Body {
    $records = @(Get-TetraInstalledApplicationInventory -RegistryEntries @((New-SyntheticApplicationEntry -DisplayName '   ')))
    Assert-True ($records.Count -eq 0) "Expected blank DisplayName entry to be ignored, got $($records.Count) record(s)."
}

Invoke-Test -Name 'Install location and registry evidence paths are preserved' -Body {
    $entry = New-SyntheticApplicationEntry -InstallLocation 'D:\Apps\Example' -RegistryKeyPath 'HKLM\Software\Example'
    $record = @(Get-TetraInstalledApplicationInventory -RegistryEntries @($entry))[0]
    Assert-True ($record.InstallLocation -eq 'D:\Apps\Example') 'InstallLocation was not preserved.'
    Assert-True ($record.InstallLocationAvailable -eq $true) 'InstallLocationAvailable should be true.'
    Assert-True (@($record.RegistryKeyPaths) -contains 'HKLM\Software\Example') 'Registry evidence path was not preserved.'
}

Invoke-Test -Name 'Empty supplied snapshot is valid and produces zero records' -Body {
    $records = @(Get-TetraInstalledApplicationInventory -RegistryEntries @())
    Assert-True ($records.Count -eq 0) "Expected zero records from empty snapshot, got $($records.Count)."
}

Invoke-Test -Name 'Application inventory source avoids Win32_Product and mutation commands' -Body {
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'Engine\InstalledApplicationInventoryEngine.ps1') -Raw -Encoding UTF8

    # Mentions in comments/documentation are allowed. Reject executable query
    # patterns that would actually invoke the MSI-backed provider.
    $win32ProductQueryPatterns = @(
        '(?im)^\s*Get-CimInstance\b[^\r\n]*\bWin32_Product\b',
        '(?im)^\s*Get-WmiObject\b[^\r\n]*\bWin32_Product\b',
        '(?im)^\s*gwmi\b[^\r\n]*\bWin32_Product\b',
        '(?im)^\s*gcim\b[^\r\n]*\bWin32_Product\b'
    )
    foreach ($pattern in $win32ProductQueryPatterns) {
        Assert-True ($source -notmatch $pattern) 'Inventory engine must not query Win32_Product.'
    }

    $forbidden = @(
        'Remove-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
        'Uninstall-Package', 'Remove-AppxPackage', 'msiexec.exe /x', 'winget uninstall',
        'choco uninstall', 'reg.exe delete'
    )
    foreach ($command in $forbidden) {
        Assert-True ($source -notmatch [regex]::Escape($command)) "Read-only application engine unexpectedly references '$command'."
    }
}

Invoke-Test -Name 'Live Windows installed application inventory returns readable records or valid empty snapshot' -Body {
    $records = @(Get-TetraInstalledApplicationInventory)
    foreach ($record in $records) {
        Assert-True ($record.RecordType -eq 'InstalledApplication') 'Live application record shape mismatch.'
        Assert-True (-not [string]::IsNullOrWhiteSpace($record.DisplayName)) 'Live application record has blank DisplayName.'
        Assert-True ($record.UninstallCommandCaptured -eq $false) 'Live record unexpectedly captured uninstall command.'
    }
    Assert-True ($records.Count -ge 0) 'Application inventory count cannot be negative.'
}

$pass = @($results | Where-Object { $_.Passed }).Count
$fail = @($results | Where-Object { -not $_.Passed }).Count

Write-Host ''
Write-Host '===== Tetra Optimizer - Installed Application Inventory Smoke Tests =====' -ForegroundColor Cyan
foreach ($result in $results) {
    $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
    $color = if ($result.Passed) { 'Green' } else { 'Red' }
    Write-Host "[$status] $($result.TestName)" -ForegroundColor $color
    if (-not $result.Passed) {
        Write-Host "        -> $($result.ErrorMessage)" -ForegroundColor DarkYellow
    }
}
Write-Host ''
Write-Host "PASS: $pass/$($results.Count)" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "FAIL: $fail/$($results.Count)" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "Overall: $(if ($fail -eq 0) { 'PASS' } else { 'FAIL' })" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''

if ($fail -gt 0) { exit 1 }
