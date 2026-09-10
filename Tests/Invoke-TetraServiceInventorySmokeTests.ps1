#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Windows Service Inventory smoke tests.
.DESCRIPTION
    Validates read-only service inventory behavior. Synthetic Win32_Service-
    shaped objects cover deterministic logic; one final smoke test exercises
    live read-only collection on Windows.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\ServiceInventoryEngine.ps1')

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

function New-SyntheticService {
    param(
        [string]$Name,
        [string]$DisplayName = '',
        [string]$State = 'Stopped',
        [string]$Status = 'OK',
        [string]$StartMode = 'Manual',
        [int]$ProcessId = 0,
        [string]$PathName = '',
        [string]$ServiceType = 'Own Process',
        [string]$Description = '',
        [string]$StartName = 'LocalSystem'
    )

    return [PSCustomObject]@{
        Name        = $Name
        DisplayName = $DisplayName
        State       = $State
        Status      = $Status
        StartMode   = $StartMode
        ProcessId   = $ProcessId
        PathName    = $PathName
        ServiceType = $ServiceType
        Description = $Description
        StartName   = $StartName
    }
}

Invoke-Test -Name 'Synthetic service becomes a correctly shaped inventory record' -Body {
    $raw = @(New-SyntheticService -Name 'WSearch' -DisplayName 'Windows Search' -State 'Running' -StartMode 'Auto' -ProcessId 2200 -PathName 'C:\Windows\System32\SearchIndexer.exe')
    $records = @(Get-TetraServiceInventory -ServiceData $raw)

    Assert-True ($records.Count -eq 1) "Expected one record, got $($records.Count)."
    $r = $records[0]
    Assert-True ($r.RecordType -eq 'Service') 'RecordType mismatch.'
    Assert-True ($r.Category -eq 'Services') 'Category mismatch.'
    Assert-True ($r.Name -eq 'WSearch') 'Name mismatch.'
    Assert-True ($r.IsRunning -eq $true) 'Running state was not normalized.'
    Assert-True ($r.StartMode -eq 'Auto') 'StartMode mismatch.'
    Assert-True ($r.EvidenceSource -eq 'Win32_Service') 'Evidence source mismatch.'
}

Invoke-Test -Name 'Service account identity is not retained' -Body {
    $raw = @(New-SyntheticService -Name 'WSearch' -StartName 'DOMAIN\SensitiveServiceUser')
    $record = @(Get-TetraServiceInventory -ServiceData $raw)[0]

    Assert-True ($record.PSObject.Properties.Name -notcontains 'StartName') 'StartName unexpectedly leaked into inventory record.'
    Assert-True (($record | Out-String) -notmatch 'SensitiveServiceUser') 'Service account identity leaked into normalized evidence.'
}

Invoke-Test -Name 'Running service creates active Analyzer observation' -Body {
    $raw = @(New-SyntheticService -Name 'WSearch' -State 'Running' -StartMode 'Auto' -ProcessId 2300)
    $states = @(ConvertTo-TetraServiceSystemState -InventoryRecords @(Get-TetraServiceInventory -ServiceData $raw))
    $state = $states | Where-Object { $_.KnowledgeBaseId -eq 'svc-wsearch' }

    Assert-True ($null -ne $state) 'svc-wsearch observation was not produced.'
    Assert-True ($state.IsInstalled -eq $true) 'Positive service evidence should set IsInstalled=true.'
    Assert-True ($state.IsActive -eq $true) 'Running service should set IsActive=true.'
    Assert-True ($state.CurrentState -like '*StartMode=Auto*') 'Start mode evidence is missing.'
    Assert-True ($state.CurrentState -like '*ProcessId=2300*') 'ProcessId evidence is missing.'
}

Invoke-Test -Name 'Stopped installed service is installed but inactive' -Body {
    $raw = @(New-SyntheticService -Name 'SysMain' -State 'Stopped' -StartMode 'Manual')
    $states = @(ConvertTo-TetraServiceSystemState -InventoryRecords @(Get-TetraServiceInventory -ServiceData $raw))
    $state = $states | Where-Object { $_.KnowledgeBaseId -eq 'svc-sysmain' }

    Assert-True ($null -ne $state) 'svc-sysmain observation was not produced.'
    Assert-True ($state.IsInstalled -eq $true) 'Stopped service should remain installed.'
    Assert-True ($state.IsActive -eq $false) 'Stopped service should be inactive.'
}

Invoke-Test -Name 'Disabled service state is preserved as evidence' -Body {
    $raw = @(New-SyntheticService -Name 'RemoteRegistry' -State 'Stopped' -StartMode 'Disabled')
    $record = @(Get-TetraServiceInventory -ServiceData $raw)[0]
    $state = @(ConvertTo-TetraServiceSystemState -InventoryRecords @($record)) | Where-Object { $_.KnowledgeBaseId -eq 'svc-remoteregistry' }

    Assert-True ($record.IsDisabled -eq $true) 'Disabled start mode was not normalized.'
    Assert-True ($state.CurrentState -like '*StartMode=Disabled*') 'Disabled evidence was lost during conversion.'
}

Invoke-Test -Name 'Service matching is case-insensitive' -Body {
    $raw = @(New-SyntheticService -Name 'wsearch' -State 'Running')
    $states = @(ConvertTo-TetraServiceSystemState -InventoryRecords @(Get-TetraServiceInventory -ServiceData $raw))
    Assert-True (@($states | Where-Object { $_.KnowledgeBaseId -eq 'svc-wsearch' }).Count -eq 1) 'Case-insensitive service-name match failed.'
}

Invoke-Test -Name 'Partial snapshot does not manufacture not-installed service evidence' -Body {
    $raw = @(New-SyntheticService -Name 'WSearch' -State 'Running')
    $states = @(ConvertTo-TetraServiceSystemState -InventoryRecords @(Get-TetraServiceInventory -ServiceData $raw))

    Assert-True (@($states | Where-Object { $_.KnowledgeBaseId -eq 'svc-wsearch' }).Count -eq 1) 'Positive WSearch evidence missing.'
    Assert-True (@($states | Where-Object { $_.KnowledgeBaseId -eq 'svc-fax' }).Count -eq 0) 'Partial snapshot incorrectly manufactured negative Fax evidence.'
}

Invoke-Test -Name 'Complete snapshot can prove Knowledge Base service absence' -Body {
    $raw = @(New-SyntheticService -Name 'WSearch' -State 'Running')
    $states = @(ConvertTo-TetraServiceSystemState -InventoryRecords @(Get-TetraServiceInventory -ServiceData $raw) -SnapshotComplete)
    $fax = $states | Where-Object { $_.KnowledgeBaseId -eq 'svc-fax' }

    Assert-True ($null -ne $fax) 'Complete snapshot did not produce svc-fax absence observation.'
    Assert-True ($fax.IsInstalled -eq $false) 'Complete-snapshot absence should set IsInstalled=false.'
    Assert-True ($fax.IsActive -eq $false) 'Absent service should be inactive.'
    Assert-True ($fax.CurrentState -like '*complete Win32_Service snapshot*') 'Absence evidence text is missing.'
}

Invoke-Test -Name 'Complete snapshot produces exactly one observation per service KB item' -Body {
    $raw = @(
        (New-SyntheticService -Name 'WSearch' -State 'Running'),
        (New-SyntheticService -Name 'SysMain' -State 'Stopped')
    )
    $kbCount = @(Get-TetraKnowledgeBaseItems -Category 'Services').Count
    $states = @(ConvertTo-TetraServiceSystemState -InventoryRecords @(Get-TetraServiceInventory -ServiceData $raw) -SnapshotComplete)

    Assert-True ($states.Count -eq $kbCount) "Expected $kbCount service observations from complete snapshot, got $($states.Count)."
    $uniqueIds = @($states | Select-Object -ExpandProperty KnowledgeBaseId -Unique)
    Assert-True ($uniqueIds.Count -eq $states.Count) 'Duplicate service observations were produced.'
}

Invoke-Test -Name 'Service inventory source contains no mutation commands' -Body {
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'Engine\ServiceInventoryEngine.ps1') -Raw -Encoding UTF8
    $forbidden = @(
        'Set-Service', 'Stop-Service', 'Start-Service', 'New-Service', 'Remove-Service',
        'sc.exe config', 'sc.exe delete', 'sc.exe stop', 'sc.exe start',
        'Set-ItemProperty', 'Remove-ItemProperty', 'Remove-Item', 'Start-Process',
        'Stop-Process', 'reg.exe delete'
    )

    foreach ($command in $forbidden) {
        Assert-True ($source -notmatch [regex]::Escape($command)) "Read-only service inventory engine unexpectedly references '$command'."
    }
}

Invoke-Test -Name 'Live Windows service inventory returns readable records' -Body {
    $records = @(Get-TetraServiceInventory)
    Assert-True ($records.Count -gt 0) 'Live service inventory returned zero records.'
    Assert-True (@($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) }).Count -gt 0) 'No live service record had a service name.'
    Assert-True (@($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.State) }).Count -gt 0) 'No live service record had a service state.'
    Assert-True (@($records | Where-Object { $_.EvidenceSource -eq 'Win32_Service' }).Count -eq $records.Count) 'Unexpected live service evidence source found.'
}

$pass = @($results | Where-Object { $_.Passed }).Count
$fail = @($results | Where-Object { -not $_.Passed }).Count

Write-Host ''
Write-Host '===== Tetra Optimizer - Service Inventory Smoke Tests =====' -ForegroundColor Cyan
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
