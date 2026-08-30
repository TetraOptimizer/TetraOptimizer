#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\StartupInventoryEngine.ps1')

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

function New-SyntheticStartup {
    param(
        [string]$Name,
        [string]$Command,
        [string]$Location = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        [string]$User = 'EXAMPLE\User'
    )

    return [PSCustomObject]@{
        Name = $Name
        Command = $Command
        Location = $Location
        User = $User
    }
}

Invoke-Test -Name 'Quoted executable path is parsed correctly' -Body {
    $entry = New-SyntheticStartup -Name 'OneDrive' -Command '"C:\Program Files\Microsoft OneDrive\OneDrive.exe" /background'
    $records = @(Get-TetraStartupInventory -StartupData @($entry))
    Assert-True ($records.Count -eq 1) 'Expected one startup record.'
    Assert-True ($records[0].ExecutableName -eq 'OneDrive.exe') "Expected OneDrive.exe, got '$($records[0].ExecutableName)'."
}

Invoke-Test -Name 'Unquoted executable command is parsed correctly' -Body {
    $entry = New-SyntheticStartup -Name 'Steam' -Command 'C:\Steam\Steam.exe -silent'
    $records = @(Get-TetraStartupInventory -StartupData @($entry))
    Assert-True ($records[0].ExecutableName -eq 'Steam.exe') "Expected Steam.exe, got '$($records[0].ExecutableName)'."
}

Invoke-Test -Name 'Startup record preserves evidence source and location' -Body {
    $entry = New-SyntheticStartup -Name 'Spotify' -Command 'Spotify.exe --autostart' -Location 'Startup Folder'
    $record = @(Get-TetraStartupInventory -StartupData @($entry))[0]
    Assert-True ($record.RecordType -eq 'Startup') 'RecordType mismatch.'
    Assert-True ($record.Category -eq 'Startup') 'Category mismatch.'
    Assert-True ($record.EvidenceSource -eq 'Win32_StartupCommand') 'Evidence source mismatch.'
    Assert-True ($record.Location -eq 'Startup Folder') 'Startup location was not preserved.'
}

Invoke-Test -Name 'User identity is not retained' -Body {
    $entry = New-SyntheticStartup -Name 'Teams' -Command 'Teams.exe' -User 'PRIVATE\Alice'
    $record = @(Get-TetraStartupInventory -StartupData @($entry))[0]
    Assert-True (-not ($record.PSObject.Properties.Name -contains 'User')) 'Startup record unexpectedly retains User identity.'
    Assert-True ($record.UserIdentityKept -eq $false) 'UserIdentityKept should be false.'
}

Invoke-Test -Name 'Exact startup executable creates Analyzer observation' -Body {
    $entry = New-SyntheticStartup -Name 'OneDrive' -Command '"C:\OneDrive\OneDrive.exe" /background'
    $records = @(Get-TetraStartupInventory -StartupData @($entry))
    $states = @(ConvertTo-TetraStartupSystemState -InventoryRecords $records)
    $state = $states | Where-Object { $_.KnowledgeBaseId -eq 'startup-onedrive' }
    Assert-True ($null -ne $state) 'startup-onedrive observation was not produced.'
    Assert-True ($state.IsInstalled -eq $true) 'Positive startup evidence should set IsInstalled=true.'
    Assert-True ($state.IsActive -eq $true) 'Present startup entry should set IsActive=true.'
}

Invoke-Test -Name 'Startup matching is case-insensitive' -Body {
    $entry = New-SyntheticStartup -Name 'Discord' -Command 'DISCORD.EXE --start-minimized'
    $states = @(ConvertTo-TetraStartupSystemState -InventoryRecords @(Get-TetraStartupInventory -StartupData @($entry)))
    Assert-True (@($states | Where-Object { $_.KnowledgeBaseId -eq 'startup-discord' }).Count -eq 1) 'Case-insensitive startup matching failed.'
}

Invoke-Test -Name 'Multiple matching startup entries consolidate into one observation' -Body {
    $entries = @(
        (New-SyntheticStartup -Name 'Teams User' -Command 'Teams.exe' -Location 'HKCU Run'),
        (New-SyntheticStartup -Name 'Teams Machine' -Command '"C:\Program Files\Teams\Teams.exe"' -Location 'Startup Folder')
    )
    $states = @(ConvertTo-TetraStartupSystemState -InventoryRecords @(Get-TetraStartupInventory -StartupData $entries))
    $state = $states | Where-Object { $_.KnowledgeBaseId -eq 'startup-teams' }
    Assert-True (@($state).Count -eq 1) 'Expected one consolidated startup-teams observation.'
    Assert-True ($state.CurrentState -like '*Entries=2*') 'Entry count evidence is missing.'
}

Invoke-Test -Name 'Absence does not manufacture negative startup evidence' -Body {
    $states = @(ConvertTo-TetraStartupSystemState -InventoryRecords @())
    Assert-True ($states.Count -eq 0) "Expected zero observations from zero startup evidence, got $($states.Count)."
}

Invoke-Test -Name 'Ambiguous GPU tray identifier is deliberately not inferred' -Body {
    $entry = New-SyntheticStartup -Name 'NVIDIA App' -Command 'NVIDIA.exe'
    $states = @(ConvertTo-TetraStartupSystemState -InventoryRecords @(Get-TetraStartupInventory -StartupData @($entry)))
    Assert-True (@($states | Where-Object { $_.KnowledgeBaseId -eq 'startup-gpu-tray' }).Count -eq 0) 'Ambiguous GPU tray item was inferred from insufficient evidence.'
}

Invoke-Test -Name 'Startup inventory source contains no mutation commands' -Body {
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'Engine\StartupInventoryEngine.ps1') -Raw -Encoding UTF8
    $forbidden = @(
        'Set-ItemProperty', 'Remove-ItemProperty', 'New-ItemProperty', 'Remove-Item',
        'Disable-ScheduledTask', 'Enable-ScheduledTask', 'Stop-Process', 'Start-Process',
        'reg.exe add', 'reg.exe delete'
    )
    foreach ($command in $forbidden) {
        Assert-True ($source -notmatch [regex]::Escape($command)) "Read-only startup engine unexpectedly references '$command'."
    }
}

Invoke-Test -Name 'Live Windows startup inventory returns readable records or a valid empty snapshot' -Body {
    $records = @(Get-TetraStartupInventory)
    foreach ($record in $records) {
        Assert-True ($record.RecordType -eq 'Startup') 'Live startup record shape mismatch.'
        Assert-True ($record.EvidenceSource -eq 'Win32_StartupCommand') 'Live startup evidence source mismatch.'
    }
    Assert-True ($records.Count -ge 0) 'Startup snapshot count cannot be negative.'
}

$pass = @($results | Where-Object { $_.Passed }).Count
$fail = @($results | Where-Object { -not $_.Passed }).Count

Write-Host ''
Write-Host '===== Tetra Optimizer - Startup Inventory Smoke Tests =====' -ForegroundColor Cyan
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
