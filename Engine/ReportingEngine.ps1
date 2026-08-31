#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Client Reporting Engine V1
.DESCRIPTION
    Converts a PipelineSnapshot into a stable, read-only report model. The
    report summarizes observed system condition, analysis/recommendations,
    approval/execution outcomes, reclaimed bytes, exact duplicate paths, items
    intentionally left untouched, and unresolved/manual-review work.

    Reporting never performs system mutation and never invents before/after
    measurements that were not present in pipeline evidence.
#>
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-TetraReportPropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function ConvertTo-TetraReportArray {
    param([object]$Value)
    if($null -eq $Value){return ,@()}
    return ,@($Value)
}

function New-TetraReportExecutionEntry {
    param([object]$Result,[hashtable]$PlanById)
    $planId=[string](Get-TetraReportPropertyValue $Result 'PlanItemId' '')
    $plan=if($PlanById.ContainsKey($planId)){$PlanById[$planId]}else{$null}
    $preflight=Get-TetraReportPropertyValue $Result 'Preflight' $null
    [string[]]$targets=@(ConvertTo-TetraReportArray (Get-TetraReportPropertyValue $preflight 'Targets' @()) | ForEach-Object {[string]$_})
    $keep=[string](Get-TetraReportPropertyValue $preflight 'KeepPath' '')
    if($targets.Count -eq 0 -and $null -ne $plan){
        $action=[string](Get-TetraReportPropertyValue $plan 'ProposedAction' '')
        if($action -eq 'CleanupFile'){
            $target=[string](Get-TetraReportPropertyValue $plan 'Target' '')
            if($target){[string[]]$targets=@($target)}
        }
        elseif($action -eq 'RemoveDuplicateCopies'){
            [string[]]$targets=@(ConvertTo-TetraReportArray (Get-TetraReportPropertyValue $plan 'DeletePaths' @()) | ForEach-Object {[string]$_})
            $keep=[string](Get-TetraReportPropertyValue $plan 'KeepPath' '')
        }
    }
    [string[]]$deletedPaths=@()
    if([string](Get-TetraReportPropertyValue $Result 'State' '') -eq 'ExecutedVerified'){$deletedPaths=@($targets)}
    return [PSCustomObject]@{
        PlanItemId=$planId
        RecommendationId=[string](Get-TetraReportPropertyValue $Result 'RecommendationId' '')
        Subject=[string](Get-TetraReportPropertyValue $Result 'Subject' '')
        Action=[string](Get-TetraReportPropertyValue $Result 'ProposedAction' '')
        State=[string](Get-TetraReportPropertyValue $Result 'State' '')
        Verified=[bool](Get-TetraReportPropertyValue $Result 'Verified' $false)
        BytesReclaimed=[long](Get-TetraReportPropertyValue $Result 'BytesReclaimed' 0)
        DeletedPaths=$deletedPaths
        KeepPath=$keep
        BackupCreated=[bool](Get-TetraReportPropertyValue $Result 'BackupCreated' $false)
        BackupId=[string](Get-TetraReportPropertyValue $Result 'BackupId' '')
        RollbackAttempted=[bool](Get-TetraReportPropertyValue $Result 'RollbackAttempted' $false)
        RollbackSucceeded=[bool](Get-TetraReportPropertyValue $Result 'RollbackSucceeded' $false)
        Message=[string](Get-TetraReportPropertyValue $Result 'Message' '')
    }
}

function New-TetraReportRecommendationEntry {
    param([object]$Recommendation)
    return [PSCustomObject]@{
        RecommendationId=[string](Get-TetraReportPropertyValue $Recommendation 'RecommendationId' '')
        Subject=[string](Get-TetraReportPropertyValue $Recommendation 'Subject' '')
        Recommendation=[string](Get-TetraReportPropertyValue $Recommendation 'Recommendation' '')
        ProposedAction=[string](Get-TetraReportPropertyValue $Recommendation 'ProposedAction' '')
        RequiresUserApproval=[bool](Get-TetraReportPropertyValue $Recommendation 'RequiresUserApproval' $false)
        Confidence=[string](Get-TetraReportPropertyValue $Recommendation 'Confidence' '')
        Reason=[string](Get-TetraReportPropertyValue $Recommendation 'Reason' '')
    }
}

function New-TetraReportFindingEntry {
    param([object]$Finding)
    return [PSCustomObject]@{
        Subject=[string](Get-TetraReportPropertyValue $Finding 'Subject' '')
        Category=[string](Get-TetraReportPropertyValue $Finding 'Category' '')
        Classification=[string](Get-TetraReportPropertyValue $Finding 'Classification' '')
        Confidence=[string](Get-TetraReportPropertyValue $Finding 'Confidence' '')
        Reason=[string](Get-TetraReportPropertyValue $Finding 'Reason' '')
    }
}

function New-TetraClientReport {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param([Parameter(Mandatory=$true)][PSCustomObject]$PipelineSnapshot)

    if([string](Get-TetraReportPropertyValue $PipelineSnapshot 'RecordType' '') -ne 'PipelineSnapshot'){throw 'New-TetraClientReport: Input must be a PipelineSnapshot.'}

    $scan=Get-TetraReportPropertyValue $PipelineSnapshot 'Scan' $null
    $analysis=Get-TetraReportPropertyValue $PipelineSnapshot 'Analysis' $null
    $recommendations=Get-TetraReportPropertyValue $PipelineSnapshot 'Recommendations' $null
    $plan=Get-TetraReportPropertyValue $PipelineSnapshot 'ActionPlan' $null
    $execution=Get-TetraReportPropertyValue $PipelineSnapshot 'Execution' $null

    $findings=@(ConvertTo-TetraReportArray (Get-TetraReportPropertyValue $analysis 'Findings' @()) | ForEach-Object {New-TetraReportFindingEntry $_})
    $recs=@(ConvertTo-TetraReportArray (Get-TetraReportPropertyValue $recommendations 'Recommendations' @()) | ForEach-Object {New-TetraReportRecommendationEntry $_})
    $planItems=@(ConvertTo-TetraReportArray (Get-TetraReportPropertyValue $plan 'Items' @()))
    $planById=@{};foreach($item in $planItems){$id=[string](Get-TetraReportPropertyValue $item 'PlanItemId' '');if($id){$planById[$id]=$item}}
    $executionEntries=@(ConvertTo-TetraReportArray (Get-TetraReportPropertyValue $execution 'Results' @()) | ForEach-Object {New-TetraReportExecutionEntry $_ $planById})

    $reclaimed=0L;foreach($e in $executionEntries){if($e.State -eq 'ExecutedVerified'){$reclaimed+=[long]$e.BytesReclaimed}}
    $executed=@($executionEntries|Where-Object{$_.State -eq 'ExecutedVerified'})
    $duplicates=@($executed|Where-Object{$_.Action -eq 'RemoveDuplicateCopies'}|ForEach-Object {
        [string[]]$deleted=@($_.DeletedPaths)
        [PSCustomObject]@{Subject=$_.Subject;KeepPath=$_.KeepPath;DeletedPaths=$deleted;BytesReclaimed=$_.BytesReclaimed;Verified=$_.Verified}
    })
    $untouched=@($planItems|Where-Object{[string](Get-TetraReportPropertyValue $_ 'PlanState' '') -in @('NoAction','Blocked')}|ForEach-Object {[PSCustomObject]@{Subject=[string](Get-TetraReportPropertyValue $_ 'Subject' '');PlanState=[string](Get-TetraReportPropertyValue $_ 'PlanState' '');Reason=[string](Get-TetraReportPropertyValue $_ 'Reason' '');ProposedAction=[string](Get-TetraReportPropertyValue $_ 'ProposedAction' '')}})
    $unresolved=@($planItems|Where-Object{[string](Get-TetraReportPropertyValue $_ 'PlanState' '') -in @('Review','AwaitingApproval','NeedsResolution')}|ForEach-Object {[PSCustomObject]@{Subject=[string](Get-TetraReportPropertyValue $_ 'Subject' '');PlanState=[string](Get-TetraReportPropertyValue $_ 'PlanState' '');Reason=[string](Get-TetraReportPropertyValue $_ 'Reason' '');ProposedAction=[string](Get-TetraReportPropertyValue $_ 'ProposedAction' '')}})
    $failedExecution=@($executionEntries|Where-Object{$_.State -in @('PreflightFailed','ExecutionFailed','RolledBack','RollbackFailed','Blocked')})

    $inventoryCounts=[ordered]@{}
    foreach($name in @('Processes','Services','Startup','Applications','ScheduledTasks','Drivers','StorageVolumes','Files','Cleanup','Duplicates')){$inventoryCounts[$name]=@(ConvertTo-TetraReportArray (Get-TetraReportPropertyValue $scan $name @())).Count}

    $before=[PSCustomObject]@{
        SourceScanId=[string](Get-TetraReportPropertyValue $scan 'ScanId' '')
        ScanStatus=[string](Get-TetraReportPropertyValue $scan 'Status' 'Unavailable')
        InventoryCounts=[PSCustomObject]$inventoryCounts
        Findings=$findings
    }
    $after=[PSCustomObject]@{
        EvidenceScope='VerifiedExecutionResultsOnly'
        VerifiedActions=$executed.Count
        BytesReclaimed=$reclaimed
        DuplicateGroupsChanged=$duplicates.Count
        VerificationFailures=@($failedExecution).Count
        Note='No post-execution rescan metrics are invented; only verified execution evidence is reported.'
    }

    $status=[string](Get-TetraReportPropertyValue $PipelineSnapshot 'Status' 'Unknown')
    if($failedExecution.Count -gt 0 -and $status -eq 'Complete'){$status='CompletedWithExecutionIssues'}
    return [PSCustomObject]@{
        RecordType='ClientReportSnapshot'
        ReportId=[guid]::NewGuid().ToString()
        PipelineRunId=[string](Get-TetraReportPropertyValue $PipelineSnapshot 'PipelineRunId' '')
        Profile=[string](Get-TetraReportPropertyValue $PipelineSnapshot 'Profile' '')
        Status=$status
        GeneratedUtc=(Get-Date).ToUniversalTime().ToString('o')
        IsReadOnly=$true
        Before=$before
        Issues=$findings
        Recommendations=$recs
        Actions=$executionEntries
        DuplicateChanges=$duplicates
        IntentionallyUntouched=$untouched
        Unresolved=$unresolved
        After=$after
        Summary=[PSCustomObject]@{
            Findings=$findings.Count
            Recommendations=$recs.Count
            PlanItems=$planItems.Count
            VerifiedActions=$executed.Count
            BytesReclaimed=$reclaimed
            DuplicateGroupsChanged=$duplicates.Count
            IntentionallyUntouched=$untouched.Count
            Unresolved=$unresolved.Count
            ExecutionIssues=$failedExecution.Count
        }
        SourceFailure=[PSCustomObject]@{FailedStage=[string](Get-TetraReportPropertyValue $PipelineSnapshot 'FailedStage' '');ErrorMessage=[string](Get-TetraReportPropertyValue $PipelineSnapshot 'ErrorMessage' '')}
    }
}

# Public: New-TetraClientReport
