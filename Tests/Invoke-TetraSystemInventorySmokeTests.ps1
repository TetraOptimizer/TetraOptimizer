#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - System Inventory Engine smoke tests.
.DESCRIPTION
    Validates Phase 1 process inventory behavior without mutating the live system.
    Most tests use synthetic Win32_Process-shaped objects. One final smoke check
    exercises live read-only collection on Windows.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\SystemInventoryEngine.ps1')

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

function New-SyntheticProcess {
    param(
        [string]$Name,
        [int]$ProcessId,
        [int]$ParentProcessId = 4,
        [int]$SessionId = 1,
        [string]$ExecutablePath = '',
        [string]$CommandLine = '',
        [long]$WorkingSetSize = 1024,
        [int]$ThreadCount = 2
    )

    return [PSCustomObject]@{
        Name = $Name
        ProcessId = $ProcessId
        ParentProcessId = $ParentProcessId
        SessionId = $SessionId
        ExecutablePath = $ExecutablePath
        CommandLine = $CommandLine
        WorkingSetSize = $WorkingSetSize
        ThreadCount = $ThreadCount
        CreationDate = (Get-Date).AddMinutes(-5)
    }
}

Invoke-Test -Name 'Synthetic process becomes a correctly shaped inventory record' -Body {
    $raw = @(New-SyntheticProcess -Name 'Widgets.exe' -ProcessId 1200 -ExecutablePath 'C:\Windows\SystemApps\Widgets.exe')
    $records = @(Get-TetraProcessInventory -ProcessData $raw)

    Assert-True ($records.Count -eq 1) "Expected one record, got $($records.Count)."
    $r = $records[0]
    Assert-True ($r.RecordType -eq 'Process') 'RecordType mismatch.'
    Assert-True ($r.Category -eq 'Processes') 'Category mismatch.'
    Assert-True ($r.Name -eq 'Widgets.exe') 'Name mismatch.'
    Assert-True ($r.ProcessId -eq 1200) 'ProcessId mismatch.'
    Assert-True ($r.EvidenceSource -eq 'Win32_Process') 'Evidence source mismatch.'
    Assert-True ($r.PathAvailable -eq $true) 'PathAvailable should be true.'
}

Invoke-Test -Name 'Command line is private by default' -Body {
    $raw = @(New-SyntheticProcess -Name 'Teams.exe' -ProcessId 1300 -CommandLine 'Teams.exe --sensitive-example')
    $records = @(Get-TetraProcessInventory -ProcessData $raw)

    Assert-True ([string]::IsNullOrEmpty($records[0].CommandLine)) 'Command line was retained without explicit opt-in.'
    Assert-True ($records[0].CommandLineCaptured -eq $false) 'CommandLineCaptured should be false.'
}

Invoke-Test -Name 'Command line requires explicit opt-in' -Body {
    $raw = @(New-SyntheticProcess -Name 'Teams.exe' -ProcessId 1301 -CommandLine 'Teams.exe --example')
    $records = @(Get-TetraProcessInventory -ProcessData $raw -IncludeCommandLine)

    Assert-True ($records[0].CommandLine -eq 'Teams.exe --example') 'Command line was not retained after opt-in.'
    Assert-True ($records[0].CommandLineCaptured -eq $true) 'CommandLineCaptured should be true.'
}

Invoke-Test -Name 'Exact process match creates Analyzer observation' -Body {
    $raw = @(New-SyntheticProcess -Name 'Widgets.exe' -ProcessId 1400)
    $records = @(Get-TetraProcessInventory -ProcessData $raw)
    $states = @(ConvertTo-TetraProcessSystemState -InventoryRecords $records)

    $state = $states | Where-Object { $_.KnowledgeBaseId -eq 'proc-widgets' }
    Assert-True ($null -ne $state) 'proc-widgets observation was not produced.'
    Assert-True ($state.IsInstalled -eq $true) 'Positive runtime evidence should set IsInstalled=true.'
    Assert-True ($state.IsActive -eq $true) 'Running process should set IsActive=true.'
    Assert-True ($state.CurrentState -like '*PIDs=1400*') 'CurrentState did not retain process evidence.'
}

Invoke-Test -Name 'Matching is case-insensitive' -Body {
    $raw = @(New-SyntheticProcess -Name 'widgets.EXE' -ProcessId 1401)
    $states = @(ConvertTo-TetraProcessSystemState -InventoryRecords @(Get-TetraProcessInventory -ProcessData $raw))
    Assert-True (@($states | Where-Object { $_.KnowledgeBaseId -eq 'proc-widgets' }).Count -eq 1) 'Case-insensitive executable match failed.'
}

Invoke-Test -Name 'Multiple process instances become one observation with evidence count' -Body {
    $raw = @(
        (New-SyntheticProcess -Name 'Widgets.exe' -ProcessId 1500),
        (New-SyntheticProcess -Name 'Widgets.exe' -ProcessId 1501)
    )
    $states = @(ConvertTo-TetraProcessSystemState -InventoryRecords @(Get-TetraProcessInventory -ProcessData $raw))
    $state = $states | Where-Object { $_.KnowledgeBaseId -eq 'proc-widgets' }

    Assert-True (@($state).Count -eq 1) 'Expected one consolidated proc-widgets observation.'
    Assert-True ($state.CurrentState -like '*Instances=2*') 'Instance count evidence is missing.'
    Assert-True ($state.CurrentState -like '*1500*' -and $state.CurrentState -like '*1501*') 'PID evidence is incomplete.'
}

Invoke-Test -Name 'Runtime absence does not manufacture not-installed evidence' -Body {
    $states = @(ConvertTo-TetraProcessSystemState -InventoryRecords @())
    Assert-True ($states.Count -eq 0) "Expected zero observations from zero runtime evidence, got $($states.Count)."
}

Invoke-Test -Name 'Ambiguous composite browser identifier is deliberately not inferred' -Body {
    $raw = @(New-SyntheticProcess -Name 'chrome.exe' -ProcessId 1600)
    $states = @(ConvertTo-TetraProcessSystemState -InventoryRecords @(Get-TetraProcessInventory -ProcessData $raw))

    Assert-True (@($states | Where-Object { $_.KnowledgeBaseId -eq 'proc-browser-background' }).Count -eq 0) 'Composite browser-background item was inferred from insufficient evidence.'
}

Invoke-Test -Name 'Inventory source contains no mutation commands' -Body {
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'Engine\SystemInventoryEngine.ps1') -Raw -Encoding UTF8
    $forbidden = @(
        'Stop-Process', 'Start-Process', 'Remove-Item', 'Set-Item', 'Set-ItemProperty',
        'Remove-ItemProperty', 'Set-Service', 'Stop-Service', 'Start-Service',
        'Disable-ScheduledTask', 'Enable-ScheduledTask', 'Uninstall-Package',
        'Remove-AppxPackage', 'reg.exe delete', 'taskkill.exe'
    )

    foreach ($command in $forbidden) {
        Assert-True ($source -notmatch [regex]::Escape($command)) "Read-only inventory engine unexpectedly references '$command'."
    }
}

Invoke-Test -Name 'Live Windows process inventory returns readable records' -Body {
    $records = @(Get-TetraProcessInventory)
    Assert-True ($records.Count -gt 0) 'Live process inventory returned zero records.'
    Assert-True (@($records | Where-Object { $_.ProcessId -gt 0 }).Count -gt 0) 'No live process record had a valid PID.'
    Assert-True (@($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) }).Count -gt 0) 'No live process record had a process name.'
}

$pass = @($results | Where-Object { $_.Passed }).Count
$fail = @($results | Where-Object { -not $_.Passed }).Count

Write-Host ''
Write-Host '===== Tetra Optimizer - System Inventory Smoke Tests =====' -ForegroundColor Cyan
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
