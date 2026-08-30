#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Windows Service Inventory Engine
.DESCRIPTION
    Collects evidence about installed Windows services without changing system
    state, then translates evidence-backed Knowledge Base matches into Analyzer
    system-state observations.

    SAFETY CONTRACT:
        - Read-only. This module must never start, stop, enable, disable, remove,
          create, reconfigure, or otherwise mutate a Windows service.
        - Positive Win32_Service evidence proves a service is installed.
        - Missing service evidence is NOT treated as proof of absence unless the
          caller explicitly declares the supplied snapshot complete.
        - Service activity is derived only from the reported service State.
        - No user/service-account identity is retained in inventory records.

    ARCHITECTURE:
        Discover -> normalize evidence -> inventory records -> Analyzer state.

    DEPENDENCIES:
        Engine/LoggerEngine.ps1, Engine/KnowledgeBaseEngine.ps1, and
        Engine/AnalyzerEngine.ps1 should already be dot-sourced by the caller.
.NOTES
    Module      : ServiceInventoryEngine.ps1
    Layer       : Engine
    Build Phase : Phase 4 - System Inventory / Audit
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# FUNCTION: New-TetraServiceInventoryRecord (internal)
# ============================================================
function New-TetraServiceInventoryRecord {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ServiceData,

        [Parameter(Mandatory = $false)]
        [string]$ObservedUtc = ((Get-Date).ToUniversalTime().ToString('o'))
    )

    $name        = if ($null -eq $ServiceData.Name)        { '' } else { [string]$ServiceData.Name }
    $displayName = if ($null -eq $ServiceData.DisplayName) { '' } else { [string]$ServiceData.DisplayName }
    $state       = if ($null -eq $ServiceData.State)       { '' } else { [string]$ServiceData.State }
    $status      = if ($null -eq $ServiceData.Status)      { '' } else { [string]$ServiceData.Status }
    $startMode   = if ($null -eq $ServiceData.StartMode)   { '' } else { [string]$ServiceData.StartMode }
    $processId   = if ($null -eq $ServiceData.ProcessId)   { 0 }  else { [int]$ServiceData.ProcessId }
    $pathName    = if ($null -eq $ServiceData.PathName)    { '' } else { [string]$ServiceData.PathName }
    $serviceType = if ($null -eq $ServiceData.ServiceType) { '' } else { [string]$ServiceData.ServiceType }
    $description = if ($null -eq $ServiceData.Description) { '' } else { [string]$ServiceData.Description }

    return [PSCustomObject]@{
        RecordType     = 'Service'
        Category       = 'Services'
        Name           = $name
        DisplayName    = $displayName
        State          = $state
        Status         = $status
        StartMode      = $startMode
        ProcessId      = $processId
        BinaryPath     = $pathName
        PathAvailable  = (-not [string]::IsNullOrWhiteSpace($pathName))
        ServiceType    = $serviceType
        Description    = $description
        IsRunning      = ($state -eq 'Running')
        IsDisabled     = ($startMode -eq 'Disabled')
        EvidenceSource = 'Win32_Service'
        EvidenceKey    = "Name=$name"
        ObservedUtc    = $ObservedUtc
    }
}

# ============================================================
# FUNCTION: Get-TetraServiceInventory
# ============================================================
<#
.SYNOPSIS
    Returns a read-only snapshot of installed Windows services.
.DESCRIPTION
    Uses Win32_Service via CIM when -ServiceData is not supplied. ServiceData is
    a dependency-injection seam for deterministic tests.

    The collector deliberately does not retain StartName/service-account data,
    because account identity is unnecessary for the Phase 1 audit contract.
.PARAMETER ServiceData
    Optional pre-collected Win32_Service-shaped objects, primarily for tests.
.OUTPUTS
    System.Management.Automation.PSCustomObject[]
#>
function Get-TetraServiceInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$ServiceData = $null
    )

    try {
        $observedUtc = (Get-Date).ToUniversalTime().ToString('o')

        if ($null -eq $ServiceData) {
            $ServiceData = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
        }

        $records = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($service in @($ServiceData)) {
            if ($null -eq $service) { continue }
            $records.Add((New-TetraServiceInventoryRecord -ServiceData $service -ObservedUtc $observedUtc))
        }

        if (Get-Command -Name Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Info' -Module 'ServiceInventoryEngine' -Action 'ServiceInventory' -Target 'Win32_Service' `
                -Result 'Success' -Message "Collected $($records.Count) installed service record(s) without modifying system state." | Out-Null
        }

        return $records.ToArray()
    }
    catch {
        if (Get-Command -Name Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Error' -Module 'ServiceInventoryEngine' -Action 'ServiceInventory' -Target 'Win32_Service' `
                -Result 'Failed' -Message $_.Exception.Message | Out-Null
        }

        throw "Get-TetraServiceInventory: Failed to collect service inventory - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: ConvertTo-TetraServiceSystemState
# ============================================================
<#
.SYNOPSIS
    Converts Windows service inventory evidence into Analyzer observations.
.DESCRIPTION
    Every exact Knowledge Base service-name match produces an installed
    observation. Running services are active; all other reported states are not
    active for Analyzer purposes.

    Missing Knowledge Base services are omitted by default because a caller may
    have supplied only a partial snapshot. When -SnapshotComplete is explicitly
    supplied, absence is considered evidence that the service is not installed
    and a negative observation is emitted.
.PARAMETER InventoryRecords
    Records returned by Get-TetraServiceInventory.
.PARAMETER SnapshotComplete
    Explicitly declares that InventoryRecords represent the complete installed
    Win32_Service snapshot. Enables evidence-backed not-installed observations.
.OUTPUTS
    System.Management.Automation.PSCustomObject[]
#>
function ConvertTo-TetraServiceSystemState {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$InventoryRecords,

        [Parameter(Mandatory = $false)]
        [switch]$SnapshotComplete
    )

    if (-not (Get-Command -Name New-TetraSystemStateObservation -ErrorAction SilentlyContinue)) {
        throw 'ConvertTo-TetraServiceSystemState: AnalyzerEngine is not loaded; New-TetraSystemStateObservation is unavailable.'
    }

    $recordsByName = @{}
    foreach ($record in @($InventoryRecords)) {
        if ($null -eq $record -or [string]::IsNullOrWhiteSpace($record.Name)) { continue }
        $key = $record.Name.ToLowerInvariant()
        if (-not $recordsByName.ContainsKey($key)) {
            $recordsByName[$key] = $record
        }
    }

    $observations = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($kbItem in (Get-TetraKnowledgeBaseItems -Category 'Services')) {
        $identifier = ([string]$kbItem.SystemIdentifier).Trim()
        if ([string]::IsNullOrWhiteSpace($identifier)) { continue }

        $key = $identifier.ToLowerInvariant()
        if ($recordsByName.ContainsKey($key)) {
            $record = $recordsByName[$key]
            $isRunning = ($record.State -eq 'Running')
            $stateText = "State=$($record.State); StartMode=$($record.StartMode); Status=$($record.Status); ProcessId=$($record.ProcessId)"

            $observations.Add((New-TetraSystemStateObservation `
                -Category 'Services' `
                -KnowledgeBaseId $kbItem.Id `
                -IsInstalled $true `
                -IsActive $isRunning `
                -CurrentState $stateText))
            continue
        }

        if ($SnapshotComplete) {
            $observations.Add((New-TetraSystemStateObservation `
                -Category 'Services' `
                -KnowledgeBaseId $kbItem.Id `
                -IsInstalled $false `
                -IsActive $false `
                -CurrentState 'Not present in complete Win32_Service snapshot'))
        }
    }

    return $observations.ToArray()
}

# ============================================================
# FUNCTION: Get-TetraLiveServiceSystemState
# ============================================================
<#
.SYNOPSIS
    Collects a complete live service snapshot and converts it to Analyzer state.
.DESCRIPTION
    Convenience read-only production path. Because this function itself obtains
    the complete Win32_Service result set, it can safely mark unmatched
    Knowledge Base services as not installed.
.OUTPUTS
    System.Management.Automation.PSCustomObject[]
#>
function Get-TetraLiveServiceSystemState {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    $inventory = @(Get-TetraServiceInventory)
    return @(ConvertTo-TetraServiceSystemState -InventoryRecords $inventory -SnapshotComplete)
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# Public Functions:
#   - Get-TetraServiceInventory
#   - ConvertTo-TetraServiceSystemState
#   - Get-TetraLiveServiceSystemState
#
# Internal Functions:
#   - New-TetraServiceInventoryRecord
