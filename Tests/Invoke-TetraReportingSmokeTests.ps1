#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Engine/ReportingEngine.ps1')
$pass=0;$fail=0
function Test-Case([string]$Name,[scriptblock]$Body){try{&$Body;Write-Host "[PASS] $Name" -ForegroundColor Green;$script:pass++}catch{Write-Host "[FAIL] $Name" -ForegroundColor Red;Write-Host "       -> $($_.Exception.Message)" -ForegroundColor Yellow;$script:fail++}}
function Assert-True([bool]$v,[string]$m){if(-not$v){throw$m}}
function Assert-Equal($e,$a,[string]$m){if($e-ne$a){throw "$m Expected='$e' Actual='$a'."}}

function New-ReportPipeline {
    param([string]$ExecutionState='ExecutedVerified')
    $finding=[PSCustomObject]@{Subject='cache.tmp';Category='Cleanup';Classification='PotentiallyUnnecessary';Confidence='High';Reason='Synthetic evidence.'}
    $rec=[PSCustomObject]@{RecommendationId='rec-1';Subject='cache.tmp';Recommendation='CleanupCandidate';ProposedAction='CleanupFile';RequiresUserApproval=$true;Confidence='High';Reason='Synthetic evidence.'}
    $plan=[PSCustomObject]@{PlanItemId='plan-1';RecommendationId='rec-1';Subject='cache.tmp';ProposedAction='CleanupFile';PlanState='ReadyForExecution';Target='C:\Synthetic\cache.tmp';Reason='Approved cleanup.'}
    $result=[PSCustomObject]@{PlanItemId='plan-1';RecommendationId='rec-1';Subject='cache.tmp';ProposedAction='CleanupFile';State=$ExecutionState;Verified=($ExecutionState-eq'ExecutedVerified');BytesReclaimed=2048;BackupCreated=$true;BackupId='backup-1';RollbackAttempted=$false;RollbackSucceeded=$false;Message='Synthetic result.';Preflight=[PSCustomObject]@{Targets=@('C:\Synthetic\cache.tmp');KeepPath=''}}
    return [PSCustomObject]@{RecordType='PipelineSnapshot';PipelineRunId='pipe-1';Profile='Balanced';Status='Complete';FailedStage='';ErrorMessage='';Scan=[PSCustomObject]@{ScanId='scan-1';Status='Complete';Processes=@();Services=@();Startup=@();Applications=@();ScheduledTasks=@();Drivers=@();StorageVolumes=@();Files=@();Cleanup=@([PSCustomObject]@{Name='cache.tmp'});Duplicates=@()};Analysis=[PSCustomObject]@{Findings=@($finding)};Recommendations=[PSCustomObject]@{Recommendations=@($rec)};ActionPlan=[PSCustomObject]@{Items=@($plan)};Execution=[PSCustomObject]@{Results=@($result)}}
}

Write-Host '===== Tetra Optimizer - Client Reporting Smoke Tests =====' -ForegroundColor Cyan
Test-Case 'Report snapshot contract is complete and read-only' {$r=New-TetraClientReport (New-ReportPipeline);Assert-Equal 'ClientReportSnapshot' $r.RecordType 'Record type mismatch.';Assert-True $r.IsReadOnly 'Report must be read-only.';Assert-Equal 'pipe-1' $r.PipelineRunId 'Pipeline id mismatch.'}
Test-Case 'Before section preserves observed scan condition' {$r=New-TetraClientReport (New-ReportPipeline);Assert-Equal 'scan-1' $r.Before.SourceScanId 'Scan id missing.';Assert-Equal 1 $r.Before.InventoryCounts.Cleanup 'Cleanup count mismatch.';Assert-Equal 1 @($r.Before.Findings).Count 'Finding missing.'}
Test-Case 'Verified execution contributes reclaimed bytes' {$r=New-TetraClientReport (New-ReportPipeline);Assert-Equal 2048 $r.Summary.BytesReclaimed 'Reclaim mismatch.';Assert-Equal 1 $r.Summary.VerifiedActions 'Verified count mismatch.';Assert-Equal 'C:\Synthetic\cache.tmp' $r.Actions[0].DeletedPaths[0] 'Deleted path mismatch.'}
Test-Case 'Failed execution never claims reclaimed bytes or deletion' {$r=New-TetraClientReport (New-ReportPipeline -ExecutionState ExecutionFailed);Assert-Equal 0 $r.Summary.BytesReclaimed 'Failed execution must reclaim zero in report.';Assert-Equal 0 @($r.Actions[0].DeletedPaths).Count 'Failed execution must not claim deletion.';Assert-Equal 'CompletedWithExecutionIssues' $r.Status 'Issue status mismatch.'}
Test-Case 'Duplicate report states exact keep and deleted paths' {$p=New-ReportPipeline;$pi=[PSCustomObject]@{PlanItemId='plan-d';RecommendationId='rec-d';Subject='duplicate.bin';ProposedAction='RemoveDuplicateCopies';PlanState='ReadyForExecution';KeepPath='C:\A\keep.bin';DeletePaths=@('C:\B\copy.bin');Reason='Exact duplicate.'};$er=[PSCustomObject]@{PlanItemId='plan-d';RecommendationId='rec-d';Subject='duplicate.bin';ProposedAction='RemoveDuplicateCopies';State='ExecutedVerified';Verified=$true;BytesReclaimed=4096;BackupCreated=$true;BackupId='b2';RollbackAttempted=$false;RollbackSucceeded=$false;Message='ok';Preflight=[PSCustomObject]@{Targets=@('C:\B\copy.bin');KeepPath='C:\A\keep.bin'}};$p.ActionPlan.Items=@($pi);$p.Execution.Results=@($er);$r=New-TetraClientReport $p;Assert-Equal 'C:\A\keep.bin' $r.DuplicateChanges[0].KeepPath 'Keep path mismatch.';Assert-Equal 'C:\B\copy.bin' $r.DuplicateChanges[0].DeletedPaths[0] 'Deleted path mismatch.';Assert-Equal 4096 $r.DuplicateChanges[0].BytesReclaimed 'Duplicate reclaim mismatch.'}
Test-Case 'Awaiting approval remains unresolved rather than executed' {$p=New-ReportPipeline;$p.ActionPlan.Items[0].PlanState='AwaitingApproval';$p.Execution.Results=@();$r=New-TetraClientReport $p;Assert-Equal 1 $r.Summary.Unresolved 'Unresolved count mismatch.';Assert-Equal 0 $r.Summary.VerifiedActions 'Should not claim execution.'}
Test-Case 'NoAction item is reported as intentionally untouched' {$p=New-ReportPipeline;$p.ActionPlan.Items[0].PlanState='NoAction';$p.Execution.Results=@();$r=New-TetraClientReport $p;Assert-Equal 1 $r.Summary.IntentionallyUntouched 'Untouched count mismatch.'}
Test-Case 'Report does not invent post-execution rescan metrics' {$r=New-TetraClientReport (New-ReportPipeline);Assert-Equal 'VerifiedExecutionResultsOnly' $r.After.EvidenceScope 'After evidence scope mismatch.';Assert-True ($r.After.Note -match 'No post-execution rescan') 'Honesty note missing.'}
Test-Case 'Partial pipeline can still produce an honest report' {$p=New-ReportPipeline;$p.Status='Failed';$p.FailedStage='Execution';$p.ErrorMessage='synthetic failure';$p.Execution=$null;$r=New-TetraClientReport $p;Assert-Equal 'Failed' $r.Status 'Failure status lost.';Assert-Equal 'Execution' $r.SourceFailure.FailedStage 'Failed stage lost.';Assert-Equal 0 $r.Summary.VerifiedActions 'Partial report invented execution.'}
Test-Case 'Invalid input is rejected clearly' {try{New-TetraClientReport ([PSCustomObject]@{RecordType='Wrong'})|Out-Null;throw 'Expected rejection.'}catch{Assert-True ($_.Exception.Message -match 'PipelineSnapshot') 'Wrong rejection message.'}}
Test-Case 'Reporting source contains no mutation command invocations' {$source=Get-Content -LiteralPath (Join-Path $root 'Engine/ReportingEngine.ps1') -Raw;foreach($token in @('Remove-Item','Set-ItemProperty','Stop-Service','Start-Service','Disable-ScheduledTask','Enable-ScheduledTask','pnputil','reg.exe delete')){Assert-True (-not $source.Contains($token)) "Found mutation token '$token'."}}

Write-Host ''
Write-Host "PASS: $pass/11" -ForegroundColor $(if($pass-eq11){'Green'}else{'Yellow'})
Write-Host "FAIL: $fail/11" -ForegroundColor $(if($fail-eq0){'Green'}else{'Red'})
Write-Host "Overall: $(if($fail-eq0){'PASS'}else{'FAIL'})" -ForegroundColor $(if($fail-eq0){'Green'}else{'Red'})
if($fail-gt0){exit 1}
