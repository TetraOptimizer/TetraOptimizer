#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Evidence-Based System Analysis / Classification Engine
.DESCRIPTION
    Converts a read-only SystemScanSnapshot into explainable findings and
    profile-aware policy decisions without performing any system mutation.

    Classification is deliberately conservative. Usage labels such as Unused
    and RarelyUsed are never inferred from mere installation, age, disabled
    state, or absence of runtime evidence. Unknown remains an explicit outcome.
#>
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-TetraClassificationStates {
    [CmdletBinding()][OutputType([string[]])]param()
    return @('Used','RarelyUsed','Unused','Duplicate','Leftover','PotentiallyUnnecessary','SystemCritical','Unknown')
}

function Get-TetraAnalysisPropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function New-TetraClassificationFinding {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][string]$SourceSection,
        [Parameter(Mandatory=$true)][string]$Subject,
        [Parameter(Mandatory=$true)][ValidateSet('Used','RarelyUsed','Unused','Duplicate','Leftover','PotentiallyUnnecessary','SystemCritical','Unknown')][string]$Classification,
        [Parameter(Mandatory=$true)][ValidateSet('Low','Medium','High')][string]$Confidence,
        [Parameter(Mandatory=$true)][string]$Reason,
        [string]$Path='',
        [string]$KnowledgeBaseId='',
        [string]$EvidenceSource='',
        [object]$Evidence=$null,
        [long]$PotentialReclaimBytes=0
    )
    return [PSCustomObject]@{
        RecordType='AnalysisFinding'
        FindingId=[guid]::NewGuid().ToString()
        SourceSection=$SourceSection
        Subject=$Subject
        Path=$Path
        KnowledgeBaseId=$KnowledgeBaseId
        Classification=$Classification
        Confidence=$Confidence
        Reason=$Reason
        EvidenceSource=$EvidenceSource
        Evidence=$Evidence
        PotentialReclaimBytes=$PotentialReclaimBytes
        ActionApproved=$false
        ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
}

function ConvertTo-TetraSnapshotFindings {
    [CmdletBinding()][OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Snapshot,
        [AllowEmptyCollection()][PSCustomObject[]]$PolicyDecisions=@()
    )

    $findings=[System.Collections.Generic.List[PSCustomObject]]::new()
    $decisionById=@{}
    foreach($decision in @($PolicyDecisions)){
        if($null -eq $decision -or [string]::IsNullOrWhiteSpace([string]$decision.KnowledgeBaseId)){continue}
        $decisionById[[string]$decision.KnowledgeBaseId]=$decision
    }

    foreach($group in @(Get-TetraAnalysisPropertyValue $Snapshot 'Duplicates' @())){
        if($null -eq $group){continue}
        $paths=@(Get-TetraAnalysisPropertyValue $group 'Paths' @())
        $subject=if($paths.Count -gt 0){[string]$paths[0]}else{'Duplicate file group'}
        $reclaim=0L;try{$reclaim=[long](Get-TetraAnalysisPropertyValue $group 'PotentialReclaimBytes' 0)}catch{}
        $findings.Add((New-TetraClassificationFinding -SourceSection 'Duplicates' -Subject $subject -Classification 'Duplicate' -Confidence 'High' -Reason 'Files are confirmed duplicates by matching size and cryptographic hash; no delete or keep decision is made by analysis.' -Path $subject -EvidenceSource 'DuplicateInventory' -Evidence $group -PotentialReclaimBytes $reclaim))
    }

    foreach($item in @(Get-TetraAnalysisPropertyValue $Snapshot 'Cleanup' @())){
        if($null -eq $item){continue}
        $path=[string](Get-TetraAnalysisPropertyValue $item 'FullPath' '')
        $name=[string](Get-TetraAnalysisPropertyValue $item 'Name' $path)
        $isCandidate=[bool](Get-TetraAnalysisPropertyValue $item 'IsCleanupCandidate' $false)
        $classification=if($isCandidate){'PotentiallyUnnecessary'}else{'Unknown'}
        $confidence=[string](Get-TetraAnalysisPropertyValue $item 'Confidence' 'Low')
        if(@('Low','Medium','High') -notcontains $confidence){$confidence='Low'}
        $reason=[string](Get-TetraAnalysisPropertyValue $item 'Reason' 'Insufficient evidence for cleanup classification.')
        if(-not $isCandidate){$confidence='Low'}
        $findings.Add((New-TetraClassificationFinding -SourceSection 'Cleanup' -Subject $name -Classification $classification -Confidence $confidence -Reason $reason -Path $path -EvidenceSource ([string](Get-TetraAnalysisPropertyValue $item 'EvidenceSource' 'FileSystemMetadata')) -Evidence $item))
    }

    foreach($app in @(Get-TetraAnalysisPropertyValue $Snapshot 'Applications' @())){
        if($null -eq $app){continue}
        $name=[string](Get-TetraAnalysisPropertyValue $app 'DisplayName' (Get-TetraAnalysisPropertyValue $app 'Name' 'Installed application'))
        $findings.Add((New-TetraClassificationFinding -SourceSection 'Applications' -Subject $name -Classification 'Unknown' -Confidence 'Low' -Reason 'Installation evidence alone does not prove whether an application is used, rarely used, unused, or safe to remove.' -Path ([string](Get-TetraAnalysisPropertyValue $app 'InstallLocation' '')) -EvidenceSource ([string](Get-TetraAnalysisPropertyValue $app 'EvidenceSource' 'RegistryUninstall')) -Evidence $app))
    }

    foreach($task in @(Get-TetraAnalysisPropertyValue $Snapshot 'ScheduledTasks' @())){
        if($null -eq $task){continue}
        $name=[string](Get-TetraAnalysisPropertyValue $task 'FullTaskName' (Get-TetraAnalysisPropertyValue $task 'TaskName' 'Scheduled task'))
        $findings.Add((New-TetraClassificationFinding -SourceSection 'ScheduledTasks' -Subject $name -Classification 'Unknown' -Confidence 'Low' -Reason 'Task presence, ownership, or disabled state alone does not prove that the task is unnecessary or safe to change.' -EvidenceSource ([string](Get-TetraAnalysisPropertyValue $task 'EvidenceSource' 'ScheduledTasks')) -Evidence $task))
    }

    foreach($state in @(Get-TetraAnalysisPropertyValue $Snapshot 'AnalyzerState' @())){
        if($null -eq $state){continue}
        $kbId=[string](Get-TetraAnalysisPropertyValue $state 'KnowledgeBaseId' '')
        $category=[string](Get-TetraAnalysisPropertyValue $state 'Category' 'Runtime')
        $isInstalled=[bool](Get-TetraAnalysisPropertyValue $state 'IsInstalled' $false)
        $isActive=[bool](Get-TetraAnalysisPropertyValue $state 'IsActive' $false)
        $classification='Unknown';$confidence='Low';$reason='Runtime evidence is insufficient for a stronger classification.'
        if($decisionById.ContainsKey($kbId) -and $decisionById[$kbId].Decision -eq 'CriticalProtected'){
            $classification='SystemCritical';$confidence='High';$reason='The Knowledge Base marks this component as protected; Analyzer policy resolved it to CriticalProtected.'
        } elseif($isInstalled -and $isActive){
            $classification='Used';$confidence='Medium';$reason='The component is directly observed as installed and currently active. This is current-activity evidence, not historical usage frequency.'
        } elseif($isInstalled){
            $classification='Unknown';$confidence='Low';$reason='The component is installed but not currently active; inactivity at one snapshot does not prove it is unused.'
        }
        $findings.Add((New-TetraClassificationFinding -SourceSection $category -Subject $kbId -Classification $classification -Confidence $confidence -Reason $reason -KnowledgeBaseId $kbId -EvidenceSource 'AnalyzerState' -Evidence $state))
    }

    return $findings.ToArray()
}

function Invoke-TetraSystemAnalysis {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Snapshot,
        [ValidateSet('Gaming','Office','Balanced','Custom')][string]$Profile='Balanced'
    )

    if([string](Get-TetraAnalysisPropertyValue $Snapshot 'RecordType' '') -ne 'SystemScanSnapshot'){
        throw 'Invoke-TetraSystemAnalysis: Snapshot must be a SystemScanSnapshot.'
    }
    if(-not (Get-Command Invoke-TetraAnalysis -ErrorAction SilentlyContinue)){
        throw 'Invoke-TetraSystemAnalysis: AnalyzerEngine is not loaded; Invoke-TetraAnalysis is unavailable.'
    }

    $started=(Get-Date).ToUniversalTime()
    $errors=[System.Collections.Generic.List[PSCustomObject]]::new()
    $state=@(Get-TetraAnalysisPropertyValue $Snapshot 'AnalyzerState' @())
    $policy=@()
    if($state.Count -gt 0){
        $categories=@($state | ForEach-Object {[string]$_.Category} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Sort-Object -Unique)
        if($categories.Count -gt 0){
            try{$policy=@(Invoke-TetraAnalysis -Profile $Profile -SystemState $state -Categories $categories)}
            catch{$errors.Add([PSCustomObject]@{Section='Policy';ErrorMessage=$_.Exception.Message;ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')})}
        }
    }

    $findings=@(ConvertTo-TetraSnapshotFindings -Snapshot $Snapshot -PolicyDecisions $policy)
    $completed=(Get-Date).ToUniversalTime()
    $counts=[PSCustomObject]@{
        Findings=$findings.Count
        PolicyDecisions=$policy.Count
        Used=@($findings|Where-Object{$_.Classification -eq 'Used'}).Count
        RarelyUsed=@($findings|Where-Object{$_.Classification -eq 'RarelyUsed'}).Count
        Unused=@($findings|Where-Object{$_.Classification -eq 'Unused'}).Count
        Duplicate=@($findings|Where-Object{$_.Classification -eq 'Duplicate'}).Count
        Leftover=@($findings|Where-Object{$_.Classification -eq 'Leftover'}).Count
        PotentiallyUnnecessary=@($findings|Where-Object{$_.Classification -eq 'PotentiallyUnnecessary'}).Count
        SystemCritical=@($findings|Where-Object{$_.Classification -eq 'SystemCritical'}).Count
        Unknown=@($findings|Where-Object{$_.Classification -eq 'Unknown'}).Count
        Errors=$errors.Count
    }
    $status=if($errors.Count -gt 0){'Partial'}else{'Complete'}
    return [PSCustomObject]@{
        RecordType='SystemAnalysisSnapshot'
        AnalysisId=[guid]::NewGuid().ToString()
        SourceScanId=[string](Get-TetraAnalysisPropertyValue $Snapshot 'ScanId' '')
        SourceScanStatus=[string](Get-TetraAnalysisPropertyValue $Snapshot 'Status' '')
        Profile=$Profile
        Status=$status
        IsReadOnly=$true
        StartedUtc=$started.ToString('o')
        CompletedUtc=$completed.ToString('o')
        DurationMs=[math]::Round(($completed-$started).TotalMilliseconds,2)
        Counts=$counts
        Findings=$findings
        PolicyDecisions=$policy
        Errors=$errors.ToArray()
    }
}

# Public: Get-TetraClassificationStates, ConvertTo-TetraSnapshotFindings, Invoke-TetraSystemAnalysis
