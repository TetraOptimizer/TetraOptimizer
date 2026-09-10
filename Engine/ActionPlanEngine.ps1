#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Approval / Action Plan Engine
.DESCRIPTION
    Converts a RecommendationSnapshot into an explicit execution plan without
    executing any action. The layer separates recommendation, user approval,
    action resolution, backup requirements, and execution readiness.

    SAFETY CONTRACT:
      - No system mutation is performed.
      - DoNotTouch recommendations are permanently blocked.
      - Review recommendations cannot become executable from approval alone.
      - Cleanup candidates require an exact path and explicit approval.
      - Duplicate groups require an explicit KeepPath plus explicit DeletePaths;
        all selected paths must belong to the evidence set and KeepPath may not
        appear in DeletePaths.
      - Profile recommendations are not executable until an exact action is
        resolved by a future action resolver; policy preference alone is not a
        command.
      - ReadyForExecution means only that a future execution layer MAY process
        the item after its own preflight checks. Nothing executes here.
#>
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-TetraActionPlanStates {
    [CmdletBinding()][OutputType([string[]])]param()
    return @('NoAction','Blocked','NeedsReview','NeedsSelection','NeedsActionResolution','AwaitingApproval','ReadyForExecution')
}

function Get-TetraActionPlanPropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function New-TetraActionPlanItem {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][string]$RecommendationId,
        [Parameter(Mandatory=$true)][string]$Subject,
        [Parameter(Mandatory=$true)][ValidateSet('NoAction','Blocked','NeedsReview','NeedsSelection','NeedsActionResolution','AwaitingApproval','ReadyForExecution')][string]$PlanState,
        [Parameter(Mandatory=$true)][string]$Reason,
        [string]$Recommendation='',
        [string]$ProposedAction='None',
        [string]$Target='',
        [string]$KnowledgeBaseId='',
        [string]$Confidence='Low',
        [bool]$RequiresUserApproval=$false,
        [bool]$UserApproved=$false,
        [bool]$BackupRequired=$false,
        [string]$RollbackStrategy='None',
        [string]$KeepPath='',
        [AllowEmptyCollection()][string[]]$DeletePaths=@(),
        [object]$Evidence=$null,
        [long]$PotentialReclaimBytes=0
    )
    return [PSCustomObject]@{
        RecordType='ActionPlanItem'
        PlanItemId=[guid]::NewGuid().ToString()
        RecommendationId=$RecommendationId
        Subject=$Subject
        Recommendation=$Recommendation
        PlanState=$PlanState
        ProposedAction=$ProposedAction
        Target=$Target
        KnowledgeBaseId=$KnowledgeBaseId
        Confidence=$Confidence
        Reason=$Reason
        RequiresUserApproval=$RequiresUserApproval
        UserApproved=$UserApproved
        BackupRequired=$BackupRequired
        RollbackStrategy=$RollbackStrategy
        KeepPath=$KeepPath
        DeletePaths=@($DeletePaths)
        PotentialReclaimBytes=$PotentialReclaimBytes
        ExecutionReady=($PlanState -eq 'ReadyForExecution')
        ExecutionRequested=$false
        Executed=$false
        Evidence=$Evidence
        ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-TetraDuplicateSelection {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][object]$Recommendation,
        [Parameter(Mandatory=$true)][object]$Selection
    )
    $evidence=Get-TetraActionPlanPropertyValue $Recommendation 'Evidence' $null
    $findingEvidence=Get-TetraActionPlanPropertyValue $evidence 'Evidence' $null
    $paths=@(Get-TetraActionPlanPropertyValue $findingEvidence 'Paths' @())
    if(@($paths).Count -lt 2){
        return [PSCustomObject]@{IsValid=$false;Reason='Duplicate evidence does not contain at least two exact paths.';KeepPath='';DeletePaths=@()}
    }
    $keep=[string](Get-TetraActionPlanPropertyValue $Selection 'KeepPath' '')
    # PowerShell 5.1 may unwrap a one-item pipeline to a scalar. Force array
    # semantics after string conversion so Count/iteration stay deterministic.
    $delete=@(@(Get-TetraActionPlanPropertyValue $Selection 'DeletePaths' @()) | ForEach-Object {[string]$_})
    if([string]::IsNullOrWhiteSpace($keep)){
        return [PSCustomObject]@{IsValid=$false;Reason='Duplicate selection requires an explicit KeepPath.';KeepPath='';DeletePaths=@()}
    }
    if(@($paths) -notcontains $keep){
        return [PSCustomObject]@{IsValid=$false;Reason='KeepPath is not present in the confirmed duplicate evidence paths.';KeepPath=$keep;DeletePaths=@($delete)}
    }
    if(@($delete).Count -lt 1){
        return [PSCustomObject]@{IsValid=$false;Reason='Duplicate selection requires at least one explicit DeletePath.';KeepPath=$keep;DeletePaths=@()}
    }
    foreach($p in @($delete)){
        if(@($paths) -notcontains $p){return [PSCustomObject]@{IsValid=$false;Reason="DeletePath '$p' is not present in the confirmed duplicate evidence paths.";KeepPath=$keep;DeletePaths=@($delete)}}
        if($p -eq $keep){return [PSCustomObject]@{IsValid=$false;Reason='KeepPath may not also appear in DeletePaths.';KeepPath=$keep;DeletePaths=@($delete)}}
    }
    $uniqueDelete=@($delete | Sort-Object -Unique)
    return [PSCustomObject]@{IsValid=$true;Reason='Duplicate keep/delete selection is explicit and constrained to confirmed evidence paths.';KeepPath=$keep;DeletePaths=@($uniqueDelete)}
}

function ConvertTo-TetraActionPlanItems {
    [CmdletBinding()][OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$RecommendationSnapshot,
        [AllowEmptyCollection()][string[]]$ApprovedRecommendationIds=@(),
        [hashtable]$DuplicateSelections=@{}
    )
    if([string](Get-TetraActionPlanPropertyValue $RecommendationSnapshot 'RecordType' '') -ne 'RecommendationSnapshot'){
        throw 'ConvertTo-TetraActionPlanItems: Input must be a RecommendationSnapshot.'
    }

    $approved=@{}
    foreach($id in @($ApprovedRecommendationIds)){if(-not [string]::IsNullOrWhiteSpace([string]$id)){$approved[[string]$id]=$true}}
    $items=[System.Collections.Generic.List[PSCustomObject]]::new()

    foreach($r in @(Get-TetraActionPlanPropertyValue $RecommendationSnapshot 'Recommendations' @())){
        if($null -eq $r){continue}
        $id=[string](Get-TetraActionPlanPropertyValue $r 'RecommendationId' '')
        if([string]::IsNullOrWhiteSpace($id)){throw 'ConvertTo-TetraActionPlanItems: Every recommendation requires a RecommendationId.'}
        $subject=[string](Get-TetraActionPlanPropertyValue $r 'Subject' 'Unknown subject')
        $kind=[string](Get-TetraActionPlanPropertyValue $r 'Recommendation' 'Review')
        $path=[string](Get-TetraActionPlanPropertyValue $r 'Path' '')
        $kbId=[string](Get-TetraActionPlanPropertyValue $r 'KnowledgeBaseId' '')
        $confidence=[string](Get-TetraActionPlanPropertyValue $r 'Confidence' 'Low')
        if(@('Low','Medium','High') -notcontains $confidence){$confidence='Low'}
        $reclaim=0L;try{$reclaim=[long](Get-TetraActionPlanPropertyValue $r 'PotentialReclaimBytes' 0)}catch{}
        $userApproved=$approved.ContainsKey($id)

        $state='NeedsReview';$action='None';$target=$path;$reason='Recommendation requires human review before any action can be resolved.';$needsApproval=$false;$backup=$false;$rollback='None';$keep='';$delete=@()

        switch($kind){
            'Keep' {$state='NoAction';$reason='Recommendation is Keep; no system change is planned.'}
            'DoNotTouch' {$state='Blocked';$reason='Recommendation is DoNotTouch. This item is blocked from execution regardless of approval input.';$userApproved=$false}
            'Review' {$state='NeedsReview';$reason='Evidence is insufficient for an execution action. Approval alone cannot convert Review into an executable change.';$userApproved=$false}
            'ProfileRecommendation' {$state='NeedsActionResolution';$needsApproval=$true;$reason='Profile policy recommends a change, but no exact executable action is resolved yet. A future action resolver must define the precise change before approval can make it executable.'}
            'CleanupCandidate' {
                $needsApproval=$true;$action='CleanupFile';$backup=$true;$rollback='BackupBeforeChange'
                if([string]::IsNullOrWhiteSpace($path)){$state='NeedsActionResolution';$reason='Cleanup candidate has no exact target path, so an executable action cannot be prepared.';$userApproved=$false}
                elseif($userApproved){$state='ReadyForExecution';$reason='User explicitly approved this exact cleanup candidate. A future execution layer must still perform backup and preflight validation before changing the system.'}
                else{$state='AwaitingApproval';$reason='Exact cleanup target is known, but explicit user approval is required before the item can become execution-ready.'}
            }
            'DuplicateReview' {
                $needsApproval=$true;$action='RemoveDuplicateCopies';$backup=$true;$rollback='BackupBeforeChange'
                if(-not $DuplicateSelections.ContainsKey($id)){$state='NeedsSelection';$reason='Confirmed duplicates require an explicit KeepPath and explicit DeletePaths before approval can produce an execution-ready plan.';$userApproved=$false}
                else{
                    $selection=Test-TetraDuplicateSelection -Recommendation $r -Selection $DuplicateSelections[$id]
                    $keep=[string]$selection.KeepPath;$delete=@($selection.DeletePaths)
                    if(-not $selection.IsValid){$state='NeedsSelection';$reason=[string]$selection.Reason;$userApproved=$false}
                    elseif($userApproved){$state='ReadyForExecution';$reason='User explicitly selected the retained copy, selected duplicate copies for removal, and approved the recommendation. A future execution layer must still back up and verify each exact path.'}
                    else{$state='AwaitingApproval';$reason='Duplicate keep/delete paths are explicitly resolved, but user approval is still required.'}
                }
            }
            default {$state='NeedsReview';$reason="Unknown recommendation state '$kind' is not executable.";$userApproved=$false}
        }

        $items.Add((New-TetraActionPlanItem -RecommendationId $id -Subject $subject -PlanState $state -Reason $reason -Recommendation $kind -ProposedAction $action -Target $target -KnowledgeBaseId $kbId -Confidence $confidence -RequiresUserApproval $needsApproval -UserApproved $userApproved -BackupRequired $backup -RollbackStrategy $rollback -KeepPath $keep -DeletePaths @($delete) -Evidence $r -PotentialReclaimBytes $reclaim))
    }
    return $items.ToArray()
}

function Invoke-TetraActionPlan {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$RecommendationSnapshot,
        [AllowEmptyCollection()][string[]]$ApprovedRecommendationIds=@(),
        [hashtable]$DuplicateSelections=@{}
    )
    if([string](Get-TetraActionPlanPropertyValue $RecommendationSnapshot 'RecordType' '') -ne 'RecommendationSnapshot'){
        throw 'Invoke-TetraActionPlan: Input must be a RecommendationSnapshot.'
    }
    $started=(Get-Date).ToUniversalTime()
    $items=@(ConvertTo-TetraActionPlanItems -RecommendationSnapshot $RecommendationSnapshot -ApprovedRecommendationIds $ApprovedRecommendationIds -DuplicateSelections $DuplicateSelections)
    $completed=(Get-Date).ToUniversalTime()
    $counts=[PSCustomObject]@{
        Items=@($items).Count
        NoAction=@($items|Where-Object{$_.PlanState -eq 'NoAction'}).Count
        Blocked=@($items|Where-Object{$_.PlanState -eq 'Blocked'}).Count
        NeedsReview=@($items|Where-Object{$_.PlanState -eq 'NeedsReview'}).Count
        NeedsSelection=@($items|Where-Object{$_.PlanState -eq 'NeedsSelection'}).Count
        NeedsActionResolution=@($items|Where-Object{$_.PlanState -eq 'NeedsActionResolution'}).Count
        AwaitingApproval=@($items|Where-Object{$_.PlanState -eq 'AwaitingApproval'}).Count
        ReadyForExecution=@($items|Where-Object{$_.PlanState -eq 'ReadyForExecution'}).Count
        BackupRequired=@($items|Where-Object{$_.BackupRequired -eq $true}).Count
    }
    return [PSCustomObject]@{
        RecordType='ActionPlanSnapshot'
        ActionPlanId=[guid]::NewGuid().ToString()
        SourceRecommendationRunId=[string](Get-TetraActionPlanPropertyValue $RecommendationSnapshot 'RecommendationRunId' '')
        SourceAnalysisId=[string](Get-TetraActionPlanPropertyValue $RecommendationSnapshot 'SourceAnalysisId' '')
        SourceScanId=[string](Get-TetraActionPlanPropertyValue $RecommendationSnapshot 'SourceScanId' '')
        Status='Complete'
        IsReadOnly=$true
        StartedUtc=$started.ToString('o')
        CompletedUtc=$completed.ToString('o')
        DurationMs=[math]::Round(($completed-$started).TotalMilliseconds,2)
        Counts=$counts
        Items=@($items)
        ExecutionPerformed=$false
    }
}

# Public: Get-TetraActionPlanStates, Test-TetraDuplicateSelection, ConvertTo-TetraActionPlanItems, Invoke-TetraActionPlan
