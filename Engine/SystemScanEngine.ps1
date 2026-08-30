#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Unified Read-Only System Scan Engine
.DESCRIPTION
    Orchestrates the validated inventory collectors into one coherent snapshot.
    Collector failures are isolated and reported honestly as a Partial scan.
    File-heavy discovery is opt-in and collected metadata is reused downstream.
#>
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$Script:TetraSystemScanRequirements=@(
 [PSCustomObject]@{Function='Get-TetraProcessInventory';File='SystemInventoryEngine.ps1'},
 [PSCustomObject]@{Function='Get-TetraServiceInventory';File='ServiceInventoryEngine.ps1'},
 [PSCustomObject]@{Function='Get-TetraStartupInventory';File='StartupInventoryEngine.ps1'},
 [PSCustomObject]@{Function='Get-TetraInstalledApplicationInventory';File='InstalledApplicationInventoryEngine.ps1'},
 [PSCustomObject]@{Function='Get-TetraScheduledTaskInventory';File='ScheduledTaskInventoryEngine.ps1'},
 [PSCustomObject]@{Function='Get-TetraDriverInventory';File='DriverInventoryEngine.ps1'},
 [PSCustomObject]@{Function='Get-TetraStorageVolumeInventory';File='StorageInventoryEngine.ps1'},
 [PSCustomObject]@{Function='Get-TetraCleanupInventory';File='CleanupInventoryEngine.ps1'},
 [PSCustomObject]@{Function='Get-TetraDuplicateInventory';File='DuplicateInventoryEngine.ps1'}
)
foreach($r in $Script:TetraSystemScanRequirements){if(Get-Command $r.Function -ErrorAction SilentlyContinue){continue};$p=Join-Path $PSScriptRoot $r.File;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "SystemScanEngine: Required engine '$($r.File)' was not found."};. $p}

function Import-TetraSystemScanDependencies{foreach($r in $Script:TetraSystemScanRequirements){if(-not(Get-Command $r.Function -ErrorAction SilentlyContinue)){throw "Import-TetraSystemScanDependencies: Required function '$($r.Function)' is unavailable after dependency loading."}}}
function Invoke-TetraSystemScanCollector{
 param([Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][scriptblock]$DefaultCollector,[Parameter(Mandatory=$true)][hashtable]$CollectorOverrides,[Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.List[PSCustomObject]]$Errors)
 try{$c=$DefaultCollector;if($CollectorOverrides.ContainsKey($Name)){if($CollectorOverrides[$Name] -isnot [scriptblock]){throw "Collector override '$Name' must be a scriptblock."};$c=[scriptblock]$CollectorOverrides[$Name]};return @(& $c)}catch{$Errors.Add([PSCustomObject]@{Section=$Name;ErrorMessage=$_.Exception.Message;ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')});return @()}
}
function ConvertTo-TetraSystemScanAnalyzerState{
 [OutputType([PSCustomObject[]])]param([AllowEmptyCollection()][object[]]$Processes=@(),[AllowEmptyCollection()][object[]]$Services=@(),[AllowEmptyCollection()][object[]]$Startup=@(),[AllowEmptyCollection()][object[]]$Drivers=@(),[Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.Generic.List[PSCustomObject]]$Errors)
 $out=[System.Collections.Generic.List[PSCustomObject]]::new();$maps=@(
  [PSCustomObject]@{Section='Processes';Function='ConvertTo-TetraProcessSystemState';Records=@($Processes)},[PSCustomObject]@{Section='Services';Function='ConvertTo-TetraServiceSystemState';Records=@($Services)},[PSCustomObject]@{Section='Startup';Function='ConvertTo-TetraStartupSystemState';Records=@($Startup)},[PSCustomObject]@{Section='Drivers';Function='ConvertTo-TetraDriverSystemState';Records=@($Drivers)})
 foreach($m in $maps){if(-not(Get-Command $m.Function -ErrorAction SilentlyContinue)){continue};try{foreach($x in @(& $m.Function -InventoryRecords $m.Records)){if($null-ne$x){$out.Add($x)}}}catch{$Errors.Add([PSCustomObject]@{Section="AnalyzerState/$($m.Section)";ErrorMessage=$_.Exception.Message;ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')})}}
 return $out.ToArray()
}
function Invoke-TetraSystemScan{
 [CmdletBinding()][OutputType([PSCustomObject])]param([AllowEmptyCollection()][string[]]$RootPaths=@(),[switch]$IncludeFileInventory,[switch]$IncludeCleanup,[switch]$IncludeDuplicates,[long]$MinimumFileSizeBytes=0,[long]$LargeFileThresholdBytes=1073741824,[long]$DuplicateMinimumSizeBytes=1,[int]$MaxFiles=5000,[ValidateSet('SHA256','SHA384','SHA512')][string]$DuplicateHashAlgorithm='SHA256',[hashtable]$CollectorOverrides=@{})
 if($MaxFiles-lt1){throw 'Invoke-TetraSystemScan: MaxFiles must be at least 1.'};if($MinimumFileSizeBytes-lt0){throw 'Invoke-TetraSystemScan: MinimumFileSizeBytes cannot be negative.'};if($DuplicateMinimumSizeBytes-lt1){throw 'Invoke-TetraSystemScan: DuplicateMinimumSizeBytes must be at least 1.'}
 $fileWork=($IncludeFileInventory.IsPresent-or$IncludeCleanup.IsPresent-or$IncludeDuplicates.IsPresent);if($fileWork-and@($RootPaths).Count-eq0){throw 'Invoke-TetraSystemScan: Explicit RootPaths are required when file inventory, cleanup, or duplicate detection is requested.'}
 Import-TetraSystemScanDependencies;$id=[guid]::NewGuid().ToString();$started=(Get-Date).ToUniversalTime();$errors=[System.Collections.Generic.List[PSCustomObject]]::new()
 $processes=Invoke-TetraSystemScanCollector 'Processes' {Get-TetraProcessInventory} $CollectorOverrides $errors;$services=Invoke-TetraSystemScanCollector 'Services' {Get-TetraServiceInventory} $CollectorOverrides $errors;$startup=Invoke-TetraSystemScanCollector 'Startup' {Get-TetraStartupInventory} $CollectorOverrides $errors;$apps=Invoke-TetraSystemScanCollector 'Applications' {Get-TetraInstalledApplicationInventory} $CollectorOverrides $errors;$tasks=Invoke-TetraSystemScanCollector 'ScheduledTasks' {Get-TetraScheduledTaskInventory} $CollectorOverrides $errors;$drivers=Invoke-TetraSystemScanCollector 'Drivers' {Get-TetraDriverInventory} $CollectorOverrides $errors;$volumes=Invoke-TetraSystemScanCollector 'StorageVolumes' {Get-TetraStorageVolumeInventory} $CollectorOverrides $errors
 $working=@();$files=@();$cleanup=@();$dupes=@()
 if($fileWork){$fc={Get-TetraFileInventory -RootPaths $RootPaths -MinimumSizeBytes $MinimumFileSizeBytes -MinimumLargeFileBytes $LargeFileThresholdBytes -MaxFiles $MaxFiles}.GetNewClosure();$working=Invoke-TetraSystemScanCollector 'FileMetadata' $fc $CollectorOverrides $errors;if($IncludeFileInventory){$files=@($working)}
  if($IncludeCleanup){try{$cleanup=@(Get-TetraCleanupInventory -FileData @($working) -MinimumSizeBytes $MinimumFileSizeBytes -MaxFiles $MaxFiles)}catch{$errors.Add([PSCustomObject]@{Section='Cleanup';ErrorMessage=$_.Exception.Message;ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')})}}
  if($IncludeDuplicates){if($CollectorOverrides.ContainsKey('Duplicates')){$dupes=Invoke-TetraSystemScanCollector 'Duplicates' {@()} $CollectorOverrides $errors}else{try{$dupes=@(Get-TetraDuplicateInventory -FileData @($working) -MinimumSizeBytes $DuplicateMinimumSizeBytes -MaxFiles ([math]::Max(2,$MaxFiles)) -Algorithm $DuplicateHashAlgorithm)}catch{$errors.Add([PSCustomObject]@{Section='Duplicates';ErrorMessage=$_.Exception.Message;ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')})}}}
 }
 $state=ConvertTo-TetraSystemScanAnalyzerState -Processes $processes -Services $services -Startup $startup -Drivers $drivers -Errors $errors;$done=(Get-Date).ToUniversalTime();$status=if($errors.Count){'Partial'}else{'Complete'};$counts=[PSCustomObject]@{Processes=@($processes).Count;Services=@($services).Count;Startup=@($startup).Count;Applications=@($apps).Count;ScheduledTasks=@($tasks).Count;Drivers=@($drivers).Count;StorageVolumes=@($volumes).Count;Files=@($files).Count;CleanupCandidates=@($cleanup|Where-Object{$_.IsCleanupCandidate-eq$true}).Count;CleanupRecords=@($cleanup).Count;DuplicateGroups=@($dupes).Count;AnalyzerObservations=@($state).Count;Errors=$errors.Count};$reclaim=0L;foreach($g in @($dupes)){try{$reclaim+=[long]$g.PotentialReclaimBytes}catch{}}
 return [PSCustomObject]@{RecordType='SystemScanSnapshot';ScanId=$id;Status=$status;IsReadOnly=$true;StartedUtc=$started.ToString('o');CompletedUtc=$done.ToString('o');DurationMs=[math]::Round(($done-$started).TotalMilliseconds,2);FileWorkRequested=$fileWork;RootPaths=@($RootPaths);Counts=$counts;PotentialDuplicateReclaimBytes=$reclaim;Processes=@($processes);Services=@($services);Startup=@($startup);Applications=@($apps);ScheduledTasks=@($tasks);Drivers=@($drivers);StorageVolumes=@($volumes);Files=@($files);Cleanup=@($cleanup);Duplicates=@($dupes);AnalyzerState=@($state);Errors=$errors.ToArray()}
}
