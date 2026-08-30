#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Unified Read-Only System Scan Engine
.DESCRIPTION
    Orchestrates the validated inventory collectors into one coherent snapshot.
    Collector failures are isolated and reported honestly as a Partial scan.

    File-heavy discovery is opt-in. When file inventory, cleanup, or duplicate
    detection is requested, the filesystem is enumerated once and the resulting
    metadata is reused by downstream classifiers. Duplicate hashing therefore
    remains size-first and only occurs for size-collision candidates.

    SAFETY CONTRACT:
        - Read-only orchestration only; this engine never performs system mutation.
        - No cleanup or duplicate deletion decisions are made here.
        - File recursion requires explicit RootPaths.
        - Missing evidence is never manufactured as negative evidence.
        - Collector failures remain visible in Errors; successful sections survive.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:TetraSystemScanRequirements = @(
    [PSCustomObject]@{ Function = 'Get-TetraProcessInventory';              File = 'SystemInventoryEngine.ps1' },
    [PSCustomObject]@{ Function = 'Get-TetraServiceInventory';              File = 'ServiceInventoryEngine.ps1' },
    [PSCustomObject]@{ Function = 'Get-TetraStartupInventory';              File = 'StartupInventoryEngine.ps1' },
    [PSCustomObject]@{ Function = 'Get-TetraInstalledApplicationInventory'; File = 'InstalledApplicationInventoryEngine.ps1' },
    [PSCustomObject]@{ Function = 'Get-TetraScheduledTaskInventory';        File = 'ScheduledTaskInventoryEngine.ps1' },
    [PSCustomObject]@{ Function = 'Get-TetraDriverInventory';               File = 'DriverInventoryEngine.ps1' },
    [PSCustomObject]@{ Function = 'Get-TetraStorageVolumeInventory';        File = 'StorageInventoryEngine.ps1' },
    [PSCustomObject]@{ Function = 'Get-TetraCleanupInventory';              File = 'CleanupInventoryEngine.ps1' },
    [PSCustomObject]@{ Function = 'Get-TetraDuplicateInventory';            File = 'DuplicateInventoryEngine.ps1' }
)

foreach ($requirement in $Script:TetraSystemScanRequirements) {
    if (Get-Command $requirement.Function -ErrorAction SilentlyContinue) { continue }
    $dependencyPath = Join-Path $PSScriptRoot $requirement.File
    if (-not (Test-Path -LiteralPath $dependencyPath -PathType Leaf)) {
        throw "SystemScanEngine: Required engine '$($requirement.File)' was not found."
    }
    . $dependencyPath
}

function Import-TetraSystemScanDependencies {
    [CmdletBinding()] param()
    foreach ($requirement in $Script:TetraSystemScanRequirements) {
        if (-not (Get-Command $requirement.Function -ErrorAction SilentlyContinue)) {
            throw "Import-TetraSystemScanDependencies: Required function '$($requirement.Function)' is unavailable after dependency loading."
        }
    }
}

function Invoke-TetraSystemScanCollector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$DefaultCollector,
        [Parameter(Mandatory = $true)][hashtable]$CollectorOverrides,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[PSCustomObject]]$Errors
    )
    try {
        $collector = $DefaultCollector
        if ($CollectorOverrides.ContainsKey($Name)) {
            if ($CollectorOverrides[$Name] -isnot [scriptblock]) { throw "Collector override '$Name' must be a scriptblock." }
            $collector = [scriptblock]$CollectorOverrides[$Name]
        }
        return @(& $collector)
    }
    catch {
        $Errors.Add([PSCustomObject]@{ Section=$Name; ErrorMessage=$_.Exception.Message; ObservedUtc=(Get-Date).ToUniversalTime().ToString('o') })
        return @()
    }
}

function ConvertTo-TetraSystemScanAnalyzerState {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [AllowEmptyCollection()][object[]]$Processes = @(),
        [AllowEmptyCollection()][object[]]$Services = @(),
        [AllowEmptyCollection()][object[]]$Startup = @(),
        [AllowEmptyCollection()][object[]]$Drivers = @(),
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[PSCustomObject]]$Errors
    )
    $observations = [System.Collections.Generic.List[PSCustomObject]]::new()
    $mappings = @(
        [PSCustomObject]@{ Section='Processes'; Function='ConvertTo-TetraProcessSystemState'; Records=@($Processes) },
        [PSCustomObject]@{ Section='Services';  Function='ConvertTo-TetraServiceSystemState'; Records=@($Services) },
        [PSCustomObject]@{ Section='Startup';   Function='ConvertTo-TetraStartupSystemState'; Records=@($Startup) },
        [PSCustomObject]@{ Section='Drivers';   Function='ConvertTo-TetraDriverSystemState'; Records=@($Drivers) }
    )
    foreach ($mapping in $mappings) {
        if (-not (Get-Command $mapping.Function -ErrorAction SilentlyContinue)) { continue }
        try {
            foreach ($observation in @(& $mapping.Function -InventoryRecords $mapping.Records)) {
                if ($null -ne $observation) { $observations.Add($observation) }
            }
        }
        catch {
            $Errors.Add([PSCustomObject]@{ Section="AnalyzerState/$($mapping.Section)"; ErrorMessage=$_.Exception.Message; ObservedUtc=(Get-Date).ToUniversalTime().ToString('o') })
        }
    }
    return $observations.ToArray()
}

function Invoke-TetraSystemScan {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [AllowEmptyCollection()][string[]]$RootPaths = @(),
        [switch]$IncludeFileInventory,
        [switch]$IncludeCleanup,
        [switch]$IncludeDuplicates,
        [long]$MinimumFileSizeBytes = 0,
        [long]$LargeFileThresholdBytes = 1073741824,
        [long]$DuplicateMinimumSizeBytes = 1,
        [int]$MaxFiles = 5000,
        [ValidateSet('SHA256','SHA384','SHA512')][string]$DuplicateHashAlgorithm = 'SHA256',
        [hashtable]$CollectorOverrides = @{}
    )
    if ($MaxFiles -lt 1) { throw 'Invoke-TetraSystemScan: MaxFiles must be at least 1.' }
    if ($MinimumFileSizeBytes -lt 0) { throw 'Invoke-TetraSystemScan: MinimumFileSizeBytes cannot be negative.' }
    if ($DuplicateMinimumSizeBytes -lt 1) { throw 'Invoke-TetraSystemScan: DuplicateMinimumSizeBytes must be at least 1.' }
    $fileWorkRequested = ($IncludeFileInventory.IsPresent -or $IncludeCleanup.IsPresent -or $IncludeDuplicates.IsPresent)
    if ($fileWorkRequested -and (@($RootPaths).Count -eq 0)) { throw 'Invoke-TetraSystemScan: Explicit RootPaths are required when file inventory, cleanup, or duplicate detection is requested.' }

    Import-TetraSystemScanDependencies
    $scanId=[guid]::NewGuid().ToString(); $started=(Get-Date).ToUniversalTime(); $errors=[System.Collections.Generic.List[PSCustomObject]]::new()

    $processes=Invoke-TetraSystemScanCollector -Name 'Processes' -DefaultCollector { Get-TetraProcessInventory } -CollectorOverrides $CollectorOverrides -Errors $errors
    $services=Invoke-TetraSystemScanCollector -Name 'Services' -DefaultCollector { Get-TetraServiceInventory } -CollectorOverrides $CollectorOverrides -Errors $errors
    $startup=Invoke-TetraSystemScanCollector -Name 'Startup' -DefaultCollector { Get-TetraStartupInventory } -CollectorOverrides $CollectorOverrides -Errors $errors
    $applications=Invoke-TetraSystemScanCollector -Name 'Applications' -DefaultCollector { Get-TetraInstalledApplicationInventory } -CollectorOverrides $CollectorOverrides -Errors $errors
    $scheduledTasks=Invoke-TetraSystemScanCollector -Name 'ScheduledTasks' -DefaultCollector { Get-TetraScheduledTaskInventory } -CollectorOverrides $CollectorOverrides -Errors $errors
    $drivers=Invoke-TetraSystemScanCollector -Name 'Drivers' -DefaultCollector { Get-TetraDriverInventory } -CollectorOverrides $CollectorOverrides -Errors $errors
    $storageVolumes=Invoke-TetraSystemScanCollector -Name 'StorageVolumes' -DefaultCollector { Get-TetraStorageVolumeInventory } -CollectorOverrides $CollectorOverrides -Errors $errors

    $workingFiles=@(); $files=@(); $cleanup=@(); $duplicates=@()
    if ($fileWorkRequested) {
        $fileCollector={ Get-TetraFileInventory -RootPaths $RootPaths -MinimumSizeBytes $MinimumFileSizeBytes -MinimumLargeFileBytes $LargeFileThresholdBytes -MaxFiles $MaxFiles }.GetNewClosure()
        $workingFiles=Invoke-TetraSystemScanCollector -Name 'FileMetadata' -DefaultCollector $fileCollector -CollectorOverrides $CollectorOverrides -Errors $errors
        if ($IncludeFileInventory.IsPresent) { $files=@($workingFiles) }

        if ($IncludeCleanup.IsPresent) {
            if ($CollectorOverrides.ContainsKey('Cleanup')) {
                $cleanup=Invoke-TetraSystemScanCollector -Name 'Cleanup' -DefaultCollector { @() } -CollectorOverrides $CollectorOverrides -Errors $errors
            } else {
                try { $cleanup=@(Get-TetraCleanupInventory -FileData $workingFiles -MinimumSizeBytes $MinimumFileSizeBytes -MaxFiles $MaxFiles) }
                catch { $errors.Add([PSCustomObject]@{Section='Cleanup';ErrorMessage=$_.Exception.Message;ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')}) }
            }
        }
        if ($IncludeDuplicates.IsPresent) {
            if ($CollectorOverrides.ContainsKey('Duplicates')) {
                $duplicates=Invoke-TetraSystemScanCollector -Name 'Duplicates' -DefaultCollector { @() } -CollectorOverrides $CollectorOverrides -Errors $errors
            } else {
                try { $duplicates=@(Get-TetraDuplicateInventory -FileData $workingFiles -MinimumSizeBytes $DuplicateMinimumSizeBytes -MaxFiles ([math]::Max(2,$MaxFiles)) -Algorithm $DuplicateHashAlgorithm) }
                catch { $errors.Add([PSCustomObject]@{Section='Duplicates';ErrorMessage=$_.Exception.Message;ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')}) }
            }
        }
    }

    $analyzerState=ConvertTo-TetraSystemScanAnalyzerState -Processes $processes -Services $services -Startup $startup -Drivers $drivers -Errors $errors
    $completed=(Get-Date).ToUniversalTime(); $status=if($errors.Count -gt 0){'Partial'}else{'Complete'}
    $counts=[PSCustomObject]@{
        Processes=@($processes).Count; Services=@($services).Count; Startup=@($startup).Count; Applications=@($applications).Count
        ScheduledTasks=@($scheduledTasks).Count; Drivers=@($drivers).Count; StorageVolumes=@($storageVolumes).Count; Files=@($files).Count
        CleanupCandidates=@($cleanup|Where-Object{$_.IsCleanupCandidate -eq $true}).Count; CleanupRecords=@($cleanup).Count
        DuplicateGroups=@($duplicates).Count; AnalyzerObservations=@($analyzerState).Count; Errors=$errors.Count
    }
    $potentialDuplicateReclaim=0L
    foreach($group in @($duplicates)){try{$potentialDuplicateReclaim += [long]$group.PotentialReclaimBytes}catch{}}

    $snapshot=[PSCustomObject]@{
        RecordType='SystemScanSnapshot'; ScanId=$scanId; Status=$status; IsReadOnly=$true; StartedUtc=$started.ToString('o'); CompletedUtc=$completed.ToString('o')
        DurationMs=[math]::Round(($completed-$started).TotalMilliseconds,2); FileWorkRequested=$fileWorkRequested; RootPaths=@($RootPaths); Counts=$counts
        PotentialDuplicateReclaimBytes=$potentialDuplicateReclaim; Processes=@($processes); Services=@($services); Startup=@($startup); Applications=@($applications)
        ScheduledTasks=@($scheduledTasks); Drivers=@($drivers); StorageVolumes=@($storageVolumes); Files=@($files); Cleanup=@($cleanup); Duplicates=@($duplicates)
        AnalyzerState=@($analyzerState); Errors=$errors.ToArray()
    }
    if(Get-Command Write-TetraLog -ErrorAction SilentlyContinue){try{Write-TetraLog -Level 'Info' -Module 'SystemScanEngine' -Action 'SystemScan' -Target $scanId -Result $status -Message "System scan completed with status '$status', $($errors.Count) error(s), and $(@($analyzerState).Count) Analyzer observation(s)."|Out-Null}catch{}}
    return $snapshot
}

# Public Functions: Invoke-TetraSystemScan, ConvertTo-TetraSystemScanAnalyzerState
