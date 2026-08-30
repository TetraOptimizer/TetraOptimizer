#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - End-to-End Pipeline Engine V1
.DESCRIPTION
    Orchestrates the validated flow:
      Scan -> Analysis -> Recommendations -> Approval/Action Plan -> Execution

    The pipeline is preview-first. It never invents user approval and never
    requests mutation unless -Execute is explicitly supplied. Because
    RecommendationIds are generated during the run, optional interactive/UI
    approval is represented by an ApprovalProvider callback that receives the
    completed RecommendationSnapshot and returns explicit approval data.

    SAFETY CONTRACT:
      - No implicit approval.
      - No implicit execution.
      - -Execute alone is insufficient; ActionPlan items must also be explicitly
        approved and ReadyForExecution.
      - Stage failures are reported honestly and stop dependent later stages.
      - Earlier successful stage outputs are retained for diagnosis/reporting.
      - Execution safety remains owned by ExecutionEngine preflight/backup/
        verification/rollback logic; this orchestrator does not bypass it.
#>
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$Script:TetraPipelineDependencies=@(
    [PSCustomObject]@{Function='Invoke-TetraSystemScan';File='SystemScanEngine.ps1'},
    [PSCustomObject]@{Function='Invoke-TetraAnalysis';File='AnalyzerEngine.ps1'},
    [PSCustomObject]@{Function='Invoke-TetraSystemAnalysis';File='SystemAnalysisEngine.ps1'},
    [PSCustomObject]@{Function='Invoke-TetraRecommendations';File='RecommendationEngine.ps1'},
    [PSCustomObject]@{Function='Invoke-TetraActionPlan';File='ActionPlanEngine.ps1'},
    [PSCustomObject]@{Function='Invoke-TetraExecution';File='ExecutionEngine.ps1'}
)
foreach($d in $Script:TetraPipelineDependencies){
    if(Get-Command $d.Function -ErrorAction SilentlyContinue){continue}
    $p=Join-Path $PSScriptRoot $d.File
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "PipelineEngine: Required engine '$($d.File)' was not found."}
    . $p
}

function Get-TetraPipelinePropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function New-TetraPipelineStageResult {
    param([string]$Stage,[string]$State,[object]$Output=$null,[string]$ErrorMessage='')
    return [PSCustomObject]@{
        Stage=$Stage
        State=$State
        Success=($State -eq 'Completed')
        ErrorMessage=$ErrorMessage
        Output=$Output
        ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-TetraPipelineApprovalDecision {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$RecommendationSnapshot,
        [scriptblock]$ApprovalProvider
    )
    if($null -eq $ApprovalProvider){
        return [PSCustomObject]@{ApprovedRecommendationIds=@();DuplicateSelections=@{};ApprovalProvided=$false}
    }
    $raw=& $ApprovalProvider $RecommendationSnapshot
    if($null -eq $raw){throw 'ApprovalProvider returned null.'}
    $approved=@(@(Get-TetraPipelinePropertyValue $raw 'ApprovedRecommendationIds' @()) | ForEach-Object {[string]$_} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    $selections=Get-TetraPipelinePropertyValue $raw 'DuplicateSelections' @{}
    if($selections -isnot [hashtable]){throw 'ApprovalProvider DuplicateSelections must be a hashtable.'}
    $known=@{}
    foreach($r in @(Get-TetraPipelinePropertyValue $RecommendationSnapshot 'Recommendations' @())){
        $id=[string](Get-TetraPipelinePropertyValue $r 'RecommendationId' '')
        if(-not [string]::IsNullOrWhiteSpace($id)){$known[$id]=$true}
    }
    foreach($id in @($approved)){if(-not $known.ContainsKey($id)){throw "ApprovalProvider returned unknown RecommendationId '$id'."}}
    foreach($key in @($selections.Keys)){if(-not $known.ContainsKey([string]$key)){throw "ApprovalProvider returned duplicate selection for unknown RecommendationId '$key'."}}
    return [PSCustomObject]@{ApprovedRecommendationIds=@($approved);DuplicateSelections=$selections;ApprovalProvided=$true}
}

function Invoke-TetraPipeline {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('Gaming','Office','Balanced','Custom')][string]$Profile='Balanced',
        [AllowEmptyCollection()][string[]]$RootPaths=@(),
        [switch]$IncludeFileInventory,
        [switch]$IncludeCleanup,
        [switch]$IncludeDuplicates,
        [long]$MinimumFileSizeBytes=0,
        [long]$LargeFileThresholdBytes=1073741824,
        [long]$DuplicateMinimumSizeBytes=1,
        [int]$MaxFiles=5000,
        [ValidateSet('SHA256','SHA384','SHA512')][string]$DuplicateHashAlgorithm='SHA256',
        [hashtable]$CollectorOverrides=@{},
        [scriptblock]$ApprovalProvider,
        [switch]$Execute,
        [scriptblock]$BackupProvider,
        [scriptblock]$DeleteProvider,
        [scriptblock]$RollbackProvider,
        [scriptblock]$PathExistsProvider,
        [scriptblock]$ScanProvider,
        [scriptblock]$AnalysisProvider,
        [scriptblock]$RecommendationProvider,
        [scriptblock]$ActionPlanProvider,
        [scriptblock]$ExecutionProvider
    )
    $runId=[guid]::NewGuid().ToString();$started=(Get-Date).ToUniversalTime()
    $stages=[System.Collections.Generic.List[PSCustomObject]]::new()
    $scan=$null;$analysis=$null;$recommendations=$null;$approval=$null;$plan=$null;$execution=$null
    $failedStage='';$failure=''

    try{
        if($null -ne $ScanProvider){$scan=& $ScanProvider}
        else{$scan=Invoke-TetraSystemScan -RootPaths $RootPaths -IncludeFileInventory:$IncludeFileInventory -IncludeCleanup:$IncludeCleanup -IncludeDuplicates:$IncludeDuplicates -MinimumFileSizeBytes $MinimumFileSizeBytes -LargeFileThresholdBytes $LargeFileThresholdBytes -DuplicateMinimumSizeBytes $DuplicateMinimumSizeBytes -MaxFiles $MaxFiles -DuplicateHashAlgorithm $DuplicateHashAlgorithm -CollectorOverrides $CollectorOverrides}
        if($null -eq $scan -or [string](Get-TetraPipelinePropertyValue $scan 'RecordType' '') -ne 'SystemScanSnapshot'){throw 'Scan stage did not return a SystemScanSnapshot.'}
        $stages.Add((New-TetraPipelineStageResult 'Scan' 'Completed' $scan))
    }catch{$failedStage='Scan';$failure=$_.Exception.Message;$stages.Add((New-TetraPipelineStageResult 'Scan' 'Failed' $null $failure))}

    if([string]::IsNullOrWhiteSpace($failedStage)){
        try{
            if($null -ne $AnalysisProvider){$analysis=& $AnalysisProvider $scan $Profile}else{$analysis=Invoke-TetraSystemAnalysis -Snapshot $scan -Profile $Profile}
            if($null -eq $analysis -or [string](Get-TetraPipelinePropertyValue $analysis 'RecordType' '') -ne 'SystemAnalysisSnapshot'){throw 'Analysis stage did not return a SystemAnalysisSnapshot.'}
            $stages.Add((New-TetraPipelineStageResult 'Analysis' 'Completed' $analysis))
        }catch{$failedStage='Analysis';$failure=$_.Exception.Message;$stages.Add((New-TetraPipelineStageResult 'Analysis' 'Failed' $null $failure))}
    }else{$stages.Add((New-TetraPipelineStageResult 'Analysis' 'Skipped' $null 'Skipped because Scan failed.'))}

    if([string]::IsNullOrWhiteSpace($failedStage)){
        try{
            if($null -ne $RecommendationProvider){$recommendations=& $RecommendationProvider $analysis}else{$recommendations=Invoke-TetraRecommendations -Analysis $analysis}
            if($null -eq $recommendations -or [string](Get-TetraPipelinePropertyValue $recommendations 'RecordType' '') -ne 'RecommendationSnapshot'){throw 'Recommendation stage did not return a RecommendationSnapshot.'}
            $stages.Add((New-TetraPipelineStageResult 'Recommendations' 'Completed' $recommendations))
        }catch{$failedStage='Recommendations';$failure=$_.Exception.Message;$stages.Add((New-TetraPipelineStageResult 'Recommendations' 'Failed' $null $failure))}
    }else{$stages.Add((New-TetraPipelineStageResult 'Recommendations' 'Skipped' $null "Skipped because $failedStage failed."))}

    if([string]::IsNullOrWhiteSpace($failedStage)){
        try{
            $approval=Get-TetraPipelineApprovalDecision -RecommendationSnapshot $recommendations -ApprovalProvider $ApprovalProvider
            $stages.Add((New-TetraPipelineStageResult 'Approval' 'Completed' $approval))
        }catch{$failedStage='Approval';$failure=$_.Exception.Message;$stages.Add((New-TetraPipelineStageResult 'Approval' 'Failed' $null $failure))}
    }else{$stages.Add((New-TetraPipelineStageResult 'Approval' 'Skipped' $null "Skipped because $failedStage failed."))}

    if([string]::IsNullOrWhiteSpace($failedStage)){
        try{
            if($null -ne $ActionPlanProvider){$plan=& $ActionPlanProvider $recommendations $approval}
            else{$plan=Invoke-TetraActionPlan -RecommendationSnapshot $recommendations -ApprovedRecommendationIds @($approval.ApprovedRecommendationIds) -DuplicateSelections $approval.DuplicateSelections}
            if($null -eq $plan -or [string](Get-TetraPipelinePropertyValue $plan 'RecordType' '') -ne 'ActionPlanSnapshot'){throw 'ActionPlan stage did not return an ActionPlanSnapshot.'}
            $stages.Add((New-TetraPipelineStageResult 'ActionPlan' 'Completed' $plan))
        }catch{$failedStage='ActionPlan';$failure=$_.Exception.Message;$stages.Add((New-TetraPipelineStageResult 'ActionPlan' 'Failed' $null $failure))}
    }else{$stages.Add((New-TetraPipelineStageResult 'ActionPlan' 'Skipped' $null "Skipped because $failedStage failed."))}

    if([string]::IsNullOrWhiteSpace($failedStage)){
        try{
            if($null -ne $ExecutionProvider){$execution=& $ExecutionProvider $plan ([bool]$Execute.IsPresent)}
            else{
                $execArgs=@{ActionPlan=$plan;Execute=$Execute.IsPresent;Confirm=$false}
                if($null -ne $BackupProvider){$execArgs.BackupProvider=$BackupProvider};if($null -ne $DeleteProvider){$execArgs.DeleteProvider=$DeleteProvider};if($null -ne $RollbackProvider){$execArgs.RollbackProvider=$RollbackProvider};if($null -ne $PathExistsProvider){$execArgs.PathExistsProvider=$PathExistsProvider}
                $execution=Invoke-TetraExecution @execArgs
            }
            if($null -eq $execution -or [string](Get-TetraPipelinePropertyValue $execution 'RecordType' '') -ne 'ExecutionSnapshot'){throw 'Execution stage did not return an ExecutionSnapshot.'}
            $stages.Add((New-TetraPipelineStageResult 'Execution' 'Completed' $execution))
        }catch{$failedStage='Execution';$failure=$_.Exception.Message;$stages.Add((New-TetraPipelineStageResult 'Execution' 'Failed' $null $failure))}
    }else{$stages.Add((New-TetraPipelineStageResult 'Execution' 'Skipped' $null "Skipped because $failedStage failed."))}

    $completed=(Get-Date).ToUniversalTime();$status=if([string]::IsNullOrWhiteSpace($failedStage)){'Complete'}else{'Failed'}
    $stageArray=@($stages.ToArray())
    return [PSCustomObject]@{
        RecordType='PipelineSnapshot';PipelineRunId=$runId;Status=$status;FailedStage=$failedStage;ErrorMessage=$failure;Profile=$Profile
        ExecuteRequested=$Execute.IsPresent;ApprovalProvided=($null -ne $approval -and [bool](Get-TetraPipelinePropertyValue $approval 'ApprovalProvided' $false))
        StartedUtc=$started.ToString('o');CompletedUtc=$completed.ToString('o');DurationMs=[math]::Round(($completed-$started).TotalMilliseconds,2)
        StageCount=$stageArray.Count;Stages=$stageArray;Scan=$scan;Analysis=$analysis;Recommendations=$recommendations;Approval=$approval;ActionPlan=$plan;Execution=$execution
        MutationAttempted=($null -ne $execution -and [bool](Get-TetraPipelinePropertyValue $execution 'MutationAttempted' $false))
    }
}

# Public: Get-TetraPipelineApprovalDecision, Invoke-TetraPipeline
