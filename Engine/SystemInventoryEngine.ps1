#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - System Inventory Engine (Phase 1: Processes)
.DESCRIPTION
    Collects evidence about the live Windows system without changing it.
    Phase 1 implements read-only process inventory and conversion of exact,
    evidence-backed process matches into Analyzer system-state observations.

    SAFETY CONTRACT:
        - Read-only. This module must never stop, start, kill, remove, set,
          disable, enable, install, uninstall, or otherwise mutate system state.
        - Absence of a running process is NOT treated as proof that software is
          not installed. Only positive runtime evidence produces an observation.
        - Ambiguous Knowledge Base identifiers are deliberately left unmatched
          until a collector can prove the intended state with sufficient evidence.
        - Command lines are privacy-sensitive and are not retained unless the
          caller explicitly supplies -IncludeCommandLine.

    ARCHITECTURE:
        Discover -> normalize evidence -> produce inventory records -> optionally
        translate high-confidence matches to Analyzer observations.

    DEPENDENCIES:
        Engine/LoggerEngine.ps1, Engine/KnowledgeBaseEngine.ps1, and
        Engine/AnalyzerEngine.ps1 should already be dot-sourced by the caller.
.NOTES
    Module      : SystemInventoryEngine.ps1
    Layer       : Engine
    Build Phase : Phase 4 - System Inventory / Audit
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# FUNCTION: ConvertTo-TetraIsoTimestamp (internal)
# ============================================================
function ConvertTo-TetraIsoTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return '' }

    try {
        if ($Value -is [datetime]) {
            return $Value.ToUniversalTime().ToString('o')
        }

        $parsed = [datetime]::Parse([string]$Value)
        return $parsed.ToUniversalTime().ToString('o')
    }
    catch {
        # Evidence collection must not fail merely because a provider returned
        # an unfamiliar timestamp representation. Preserve it as text instead.
        return [string]$Value
    }
}

# ============================================================
# FUNCTION: New-TetraProcessInventoryRecord (internal)
# ============================================================
function New-TetraProcessInventoryRecord {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ProcessData,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeCommandLine,

        [Parameter(Mandatory = $false)]
        [string]$ObservedUtc = ((Get-Date).ToUniversalTime().ToString('o'))
    )

    $name = if ($null -eq $ProcessData.Name) { '' } else { [string]$ProcessData.Name }
    $pidValue = if ($null -eq $ProcessData.ProcessId) { 0 } else { [int]$ProcessData.ProcessId }
    $parentPid = if ($null -eq $ProcessData.ParentProcessId) { 0 } else { [int]$ProcessData.ParentProcessId }
    $sessionId = if ($null -eq $ProcessData.SessionId) { 0 } else { [int]$ProcessData.SessionId }
    $threadCount = if ($null -eq $ProcessData.ThreadCount) { 0 } else { [int]$ProcessData.ThreadCount }
    $workingSet = if ($null -eq $ProcessData.WorkingSetSize) { 0L } else { [long]$ProcessData.WorkingSetSize }
    $path = if ($null -eq $ProcessData.ExecutablePath) { '' } else { [string]$ProcessData.ExecutablePath }
    $commandLine = ''

    if ($IncludeCommandLine -and $null -ne $ProcessData.CommandLine) {
        $commandLine = [string]$ProcessData.CommandLine
    }

    return [PSCustomObject]@{
        RecordType          = 'Process'
        Category            = 'Processes'
        Name                = $name
        ProcessId           = $pidValue
        ParentProcessId     = $parentPid
        SessionId           = $sessionId
        ExecutablePath      = $path
        PathAvailable       = (-not [string]::IsNullOrWhiteSpace($path))
        WorkingSetBytes     = $workingSet
        ThreadCount         = $threadCount
        CreationUtc         = (ConvertTo-TetraIsoTimestamp -Value $ProcessData.CreationDate)
        CommandLine         = $commandLine
        CommandLineCaptured = [bool]$IncludeCommandLine
        EvidenceSource      = 'Win32_Process'
        EvidenceKey         = "ProcessId=$pidValue;Name=$name"
        ObservedUtc         = $ObservedUtc
    }
}

# ============================================================
# FUNCTION: Get-TetraProcessInventory
# ============================================================
<#
.SYNOPSIS
    Returns a read-only snapshot of currently running Windows processes.
.DESCRIPTION
    Uses Win32_Process via CIM when -ProcessData is not supplied. ProcessData is
    an explicit dependency-injection seam for deterministic tests; production
    callers normally omit it.

    Access-restricted fields such as ExecutablePath may legitimately be blank.
    That is evidence uncertainty, not a collection failure.
.PARAMETER IncludeCommandLine
    Explicit opt-in to retain process command lines in returned records.
.PARAMETER ProcessData
    Optional pre-collected Win32_Process-shaped objects, primarily for tests.
.OUTPUTS
    System.Management.Automation.PSCustomObject[]
#>
function Get-TetraProcessInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$IncludeCommandLine,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$ProcessData = $null
    )

    try {
        $observedUtc = (Get-Date).ToUniversalTime().ToString('o')

        if ($null -eq $ProcessData) {
            $ProcessData = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        }

        $records = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($process in @($ProcessData)) {
            if ($null -eq $process) { continue }
            $records.Add((New-TetraProcessInventoryRecord -ProcessData $process -IncludeCommandLine:$IncludeCommandLine -ObservedUtc $observedUtc))
        }

        if (Get-Command -Name Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Info' -Module 'SystemInventoryEngine' -Action 'ProcessInventory' -Target 'Win32_Process' `
                -Result 'Success' -Message "Collected $($records.Count) running process record(s) without modifying system state." | Out-Null
        }

        return $records.ToArray()
    }
    catch {
        if (Get-Command -Name Write-TetraLog -ErrorAction SilentlyContinue) {
            Write-TetraLog -Level 'Error' -Module 'SystemInventoryEngine' -Action 'ProcessInventory' -Target 'Win32_Process' `
                -Result 'Failed' -Message $_.Exception.Message | Out-Null
        }

        throw "Get-TetraProcessInventory: Failed to collect process inventory - $($_.Exception.Message)"
    }
}

# ============================================================
# FUNCTION: Get-TetraExactProcessIdentifier (internal)
# ============================================================
function Get-TetraExactProcessIdentifier {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SystemIdentifier
    )

    $identifier = $SystemIdentifier.Trim()

    # Phase 1 intentionally supports only one exact executable name. Composite
    # identifiers (for example browser background-mode abstractions) require
    # richer evidence than "a process with this name is running".
    if ($identifier -match '[\\/|]') { return '' }
    if ($identifier -notmatch '^[^\\/]+\.exe$') { return '' }

    return $identifier
}

# ============================================================
# FUNCTION: ConvertTo-TetraProcessSystemState
# ============================================================
<#
.SYNOPSIS
    Converts high-confidence running-process evidence into Analyzer observations.
.DESCRIPTION
    Produces observations only where an exact Knowledge Base executable name can
    be proven from the supplied inventory. It never manufactures negative state:
    a missing process is omitted rather than incorrectly marked "not installed".

    This distinction is critical: runtime absence proves only "not observed
    running now", not "software is not installed".
.PARAMETER InventoryRecords
    Records returned by Get-TetraProcessInventory.
.OUTPUTS
    System.Management.Automation.PSCustomObject[]
#>
function ConvertTo-TetraProcessSystemState {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$InventoryRecords
    )

    if (-not (Get-Command -Name New-TetraSystemStateObservation -ErrorAction SilentlyContinue)) {
        throw 'ConvertTo-TetraProcessSystemState: AnalyzerEngine is not loaded; New-TetraSystemStateObservation is unavailable.'
    }

    $recordsByName = @{}
    foreach ($record in @($InventoryRecords)) {
        if ($null -eq $record -or [string]::IsNullOrWhiteSpace($record.Name)) { continue }
        $key = $record.Name.ToLowerInvariant()
        if (-not $recordsByName.ContainsKey($key)) {
            $recordsByName[$key] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $recordsByName[$key].Add($record)
    }

    $observations = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($kbItem in (Get-TetraKnowledgeBaseItems -Category 'Processes')) {
        $exactIdentifier = Get-TetraExactProcessIdentifier -SystemIdentifier $kbItem.SystemIdentifier
        if ([string]::IsNullOrWhiteSpace($exactIdentifier)) { continue }

        $key = $exactIdentifier.ToLowerInvariant()
        if (-not $recordsByName.ContainsKey($key)) { continue }

        $matches = $recordsByName[$key]
        $pids = @($matches | ForEach-Object { $_.ProcessId })
        $stateText = "Running; Instances=$($matches.Count); PIDs=$($pids -join ',')"

        $observations.Add((New-TetraSystemStateObservation `
            -Category 'Processes' `
            -KnowledgeBaseId $kbItem.Id `
            -IsInstalled $true `
            -IsActive $true `
            -CurrentState $stateText))
    }

    return $observations.ToArray()
}

# ============================================================
# MODULE API SURFACE
# ============================================================
# Public Functions:
#   - Get-TetraProcessInventory
#   - ConvertTo-TetraProcessSystemState
#
# Internal Functions:
#   - ConvertTo-TetraIsoTimestamp
#   - New-TetraProcessInventoryRecord
#   - Get-TetraExactProcessIdentifier
