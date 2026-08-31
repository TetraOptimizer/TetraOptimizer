#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Post-Execution Rescan / Before-After Verification Engine V1
.DESCRIPTION
    Compares a pre-execution SystemScanSnapshot with a post-execution
    SystemScanSnapshot and correlates verified execution results with observed
    after-state evidence.

    SAFETY / HONESTY CONTRACT:
      - Read-only. This engine never mutates the system.
      - Exact deleted-file verification is only claimed when post-scan file
        metadata is available for the relevant scope.
      - Storage free-space deltas are reported as observed deltas only; they are
        never attributed solely to Tetra because other system activity may occur
        between scans.
      - Missing evidence yields Unknown/Unverified rather than invented success.
#>
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-TetraPostVerifyPropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function ConvertTo-TetraPostVerifyArray {
    param([object]$Value)
    if($null -eq $Value){return @()}
    return @($Value)
}

function New-TetraPostVerifyPathIndex {
    param([object]$Snapshot)
    $index=@{}
    foreach($f in @(ConvertTo-TetraPostVerifyArray (Get-TetraPostVerifyPropertyValue $Snapshot 'Files' @()))){
        $path=[string](Get-TetraPostVerifyPropertyValue $f 'FullPath' '')
        if([string]::IsNullOrWhiteSpace($path)){continue}
        $index[$path.ToLowerInvariant()]=$f
    }
    return $index
}

function Test-TetraPostVerifyFileEvidenceAvailable {
    param([object]$Snapshot)
    if($null -eq $Snapshot){return $false}
    $fileWork=[bool](Get-TetraPostVerifyPropertyValue $Snapshot 'FileWorkRequested' $false)
    $roots=@(ConvertTo-TetraPostVerifyArray (Get-TetraPostVerifyPropertyValue $Snapshot 'RootPaths' @()))
    return ($fileWork -and $roots.Count -gt 0)
}

function Get-TetraPostVerifyExecutionTargets {
    param([object]$Result)
    $preflight=Get-TetraPostVerifyPropertyValue $Result 'Preflight' $null
    [string[]]$targets=@(ConvertTo-TetraPostVerifyArray (Get-TetraPostVerifyPropertyValue $preflight 'Targets' @()) | ForEach-Object {[string]$_} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    return $targets
}

function New-TetraPostVerifyExecutionCheck {
    param([object]$Result,[hashtable]$AfterPathIndex,[bool]$FileEvidenceAvailable)
    $state=[string](Get-TetraPostVerifyPropertyValue $Result 'State' '')
    $action=[string](Get-TetraPostVerifyPropertyValue $Result 'ProposedAction' '')
    [string[]]$targets=@(Get-TetraPostVerifyExecutionTargets $Result)
    $preflight=Get-TetraPostVerifyPropertyValue $Result 'Preflight' $null
    $keep=[string](Get-TetraPostVerifyPropertyValue $preflight 'KeepPath' '')

    [string[]]$missing=@()
    [string[]]$present=@()
    foreach($path in @($targets)){
        if($AfterPathIndex.ContainsKey($path.ToLowerInvariant())){$present+=@($path)}else{$missing+=@($path)}
    }

    $keepObserved=$null
    if(-not [string]::IsNullOrWhiteSpace($keep) -and $FileEvidenceAvailable){$keepObserved=$AfterPathIndex.ContainsKey($keep.ToLowerInvariant())}

    $verificationState='NotApplicable'
    $reason='Execution result was not ExecutedVerified.'
    if($state -eq 'ExecutedVerified'){
        if(-not $FileEvidenceAvailable){$verificationState='Unknown';$reason='Post-execution file inventory evidence is unavailable for exact path verification.'}
        elseif($targets.Count -eq 0){$verificationState='Unknown';$reason='Execution result contains no exact preflight target paths.'}
        elseif($present.Count -gt 0){$verificationState='Failed';$reason='One or more expected deleted paths are still present in the post-execution scan.'}
        elseif($action -eq 'RemoveDuplicateCopies' -and -not [string]::IsNullOrWhiteSpace($keep) -and $keepObserved -ne $true){$verificationState='Failed';$reason='Duplicate retained KeepPath is not present in the post-execution scan.'}
        else{$verificationState='Verified';$reason='Post-execution scan confirms expected deleted targets are absent and required retained path is present.'}
    }

    return [PSCustomObject]@{
        RecordType='PostExecutionTargetVerification'
        PlanItemId=[string](Get-TetraPostVerifyPropertyValue $Result 'PlanItemId' '')
        RecommendationId=[string](Get-TetraPostVerifyPropertyValue $Result 'RecommendationId' '')
        Subject=[string](Get-TetraPostVerifyPropertyValue $Result 'Subject' '')
        ProposedAction=$action
        ExecutionState=$state
        VerificationState=$verificationState
        ExpectedDeletedPaths=$targets
        ConfirmedMissingPaths=[string[]]$missing
        UnexpectedPresentPaths=[string[]]$present
        KeepPath=$keep
        KeepPathObserved=$keepObserved
        Reason=$reason
    }
}

function Get-TetraPostVerifyVolumeDeltas {
    param([object]$BeforeSnapshot,[object]$AfterSnapshot)
    $before=@{}
    foreach($v in @(ConvertTo-TetraPostVerifyArray (Get-TetraPostVerifyPropertyValue $BeforeSnapshot 'StorageVolumes' @()))){
        $id=[string](Get-TetraPostVerifyPropertyValue $v 'DeviceId' '')
        if(-not [string]::IsNullOrWhiteSpace($id)){$before[$id.ToLowerInvariant()]=$v}
    }
    $out=[System.Collections.Generic.List[PSCustomObject]]::new()
    foreach($v in @(ConvertTo-TetraPostVerifyArray (Get-TetraPostVerifyPropertyValue $AfterSnapshot 'StorageVolumes' @()))){
        $id=[string](Get-TetraPostVerifyPropertyValue $v 'DeviceId' '')
        if([string]::IsNullOrWhiteSpace($id)){continue}
        $key=$id.ToLowerInvariant();if(-not $before.ContainsKey($key)){continue}
        $b=$before[$key]
        $beforeFree=[long](Get-TetraPostVerifyPropertyValue $b 'FreeBytes' 0)
        $afterFree=[long](Get-TetraPostVerifyPropertyValue $v 'FreeBytes' 0)
        $beforeUsed=[long](Get-TetraPostVerifyPropertyValue $b 'UsedBytes' 0)
        $afterUsed=[long](Get-TetraPostVerifyPropertyValue $v 'UsedBytes' 0)
        $out.Add([PSCustomObject]@{
            DeviceId=$id
            BeforeFreeBytes=$beforeFree
            AfterFreeBytes=$afterFree
            FreeBytesDelta=($afterFree-$beforeFree)
            BeforeUsedBytes=$beforeUsed
            AfterUsedBytes=$afterUsed
            UsedBytesDelta=($afterUsed-$beforeUsed)
            Attribution='ObservedOnly'
        })
    }
    return $out.ToArray()
}

function Get-TetraPostVerifyCountDeltas {
    param([object]$BeforeSnapshot,[object]$AfterSnapshot)
    $names=@('Processes','Services','Startup','Applications','ScheduledTasks','Drivers','StorageVolumes','Files','Cleanup','Duplicates')
    $items=[System.Collections.Generic.List[PSCustomObject]]::new()
    foreach($name in $names){
        $beforeCount=@(ConvertTo-TetraPostVerifyArray (Get-TetraPostVerifyPropertyValue $BeforeSnapshot $name @())).Count
        $afterCount=@(ConvertTo-TetraPostVerifyArray (Get-TetraPostVerifyPropertyValue $AfterSnapshot $name @())).Count
        $items.Add([PSCustomObject]@{Section=$name;Before=$beforeCount;After=$afterCount;Delta=($afterCount-$beforeCount)})
    }
    return $items.ToArray()
}

function Compare-TetraPostExecutionRescan {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$BeforeSnapshot,
        [Parameter(Mandatory=$true)][PSCustomObject]$AfterSnapshot,
        [Parameter(Mandatory=$false)][PSCustomObject]$ExecutionSnapshot=$null
    )
    if([string](Get-TetraPostVerifyPropertyValue $BeforeSnapshot 'RecordType' '') -ne 'SystemScanSnapshot'){throw 'Compare-TetraPostExecutionRescan: BeforeSnapshot must be a SystemScanSnapshot.'}
    if([string](Get-TetraPostVerifyPropertyValue $AfterSnapshot 'RecordType' '') -ne 'SystemScanSnapshot'){throw 'Compare-TetraPostExecutionRescan: AfterSnapshot must be a SystemScanSnapshot.'}
    if($null -ne $ExecutionSnapshot -and [string](Get-TetraPostVerifyPropertyValue $ExecutionSnapshot 'RecordType' '') -ne 'ExecutionSnapshot'){throw 'Compare-TetraPostExecutionRescan: ExecutionSnapshot must be an ExecutionSnapshot when supplied.'}

    $fileEvidenceAvailable=Test-TetraPostVerifyFileEvidenceAvailable $AfterSnapshot
    $afterIndex=New-TetraPostVerifyPathIndex $AfterSnapshot
    $targetChecks=[System.Collections.Generic.List[PSCustomObject]]::new()
    if($null -ne $ExecutionSnapshot){
        foreach($r in @(ConvertTo-TetraPostVerifyArray (Get-TetraPostVerifyPropertyValue $ExecutionSnapshot 'Results' @()))){
            if($null-ne$r){$targetChecks.Add((New-TetraPostVerifyExecutionCheck -Result $r -AfterPathIndex $afterIndex -FileEvidenceAvailable $fileEvidenceAvailable))}
        }
    }

    $targetArray=@($targetChecks.ToArray())
    $verified=@($targetArray|Where-Object{$_.VerificationState-eq'Verified'}).Count
    $failed=@($targetArray|Where-Object{$_.VerificationState-eq'Failed'}).Count
    $unknown=@($targetArray|Where-Object{$_.VerificationState-eq'Unknown'}).Count
    $status=if([string](Get-TetraPostVerifyPropertyValue $AfterSnapshot 'Status' '') -eq 'Partial'){'Partial'}elseif($failed-gt0){'VerificationFailed'}elseif($unknown-gt0){'VerificationIncomplete'}else{'Complete'}

    return [PSCustomObject]@{
        RecordType='PostExecutionVerificationSnapshot'
        VerificationId=[guid]::NewGuid().ToString()
        BeforeScanId=[string](Get-TetraPostVerifyPropertyValue $BeforeSnapshot 'ScanId' '')
        AfterScanId=[string](Get-TetraPostVerifyPropertyValue $AfterSnapshot 'ScanId' '')
        SourceExecutionRunId=[string](Get-TetraPostVerifyPropertyValue $ExecutionSnapshot 'ExecutionRunId' '')
        Status=$status
        IsReadOnly=$true
        FileEvidenceAvailable=$fileEvidenceAvailable
        CountDeltas=@(Get-TetraPostVerifyCountDeltas $BeforeSnapshot $AfterSnapshot)
        VolumeDeltas=@(Get-TetraPostVerifyVolumeDeltas $BeforeSnapshot $AfterSnapshot)
        TargetVerifications=$targetArray
        Counts=[PSCustomObject]@{Targets=$targetArray.Count;Verified=$verified;Failed=$failed;Unknown=$unknown}
        Note='Volume deltas are observed before/after evidence only and are not attributed solely to Tetra.'
        ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
}

# Public: Compare-TetraPostExecutionRescan
