#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Engine/PipelineEngine.ps1')

$pass=0;$fail=0
function Test-Case([string]$Name,[scriptblock]$Body){
    try{& $Body;Write-Host "[PASS] $Name" -ForegroundColor Green;$script:pass++}
    catch{Write-Host "[FAIL] $Name" -ForegroundColor Red;Write-Host "       -> $($_.Exception.Message)" -ForegroundColor Yellow;$script:fail++}
}
function Assert-True([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Assert-Equal($Expected,$Actual,[string]$Message){if($Expected -ne $Actual){throw "$Message Expected='$Expected' Actual='$Actual'."}}

function New-SyntheticScan {
    param([switch]$WithCleanup)
    $cleanup=@()
    if($WithCleanup){
        $cleanup=@([PSCustomObject]@{RecordType='CleanupCandidate';Name='cache.tmp';FullPath='C:\Synthetic\Temp\cache.tmp';SizeBytes=2048;IsCleanupCandidate=$true;Confidence='High';Reason='Synthetic cleanup evidence.';EvidenceSource='FileSystemMetadata'})
    }
    return [PSCustomObject]@{
        RecordType='SystemScanSnapshot';ScanId='scan-synthetic';Status='Complete';IsReadOnly=$true
        Processes=@();Services=@();Startup=@();Applications=@();ScheduledTasks=@();Drivers=@();StorageVolumes=@();Files=@();Cleanup=$cleanup;Duplicates=@();AnalyzerState=@();Errors=@()
    }
}

function New-EmptyAnalysis {
    param([object]$Scan,[string]$Profile)
    return [PSCustomObject]@{RecordType='SystemAnalysisSnapshot';AnalysisId='analysis-synthetic';SourceScanId=$Scan.ScanId;Profile=$Profile;Status='Complete';IsReadOnly=$true;Findings=@();PolicyDecisions=@();Errors=@();Counts=[PSCustomObject]@{Findings=0}}
}
function New-EmptyRecommendations {
    param([object]$Analysis)
    return [PSCustomObject]@{RecordType='RecommendationSnapshot';RecommendationRunId='rec-synthetic';SourceAnalysisId=$Analysis.AnalysisId;SourceScanId=$Analysis.SourceScanId;Profile=$Analysis.Profile;Status='Complete';IsReadOnly=$true;Recommendations=@();Counts=[PSCustomObject]@{Recommendations=0}}
}
function New-EmptyPlan {
    param([object]$Recommendations,[object]$Approval)
    return [PSCustomObject]@{RecordType='ActionPlanSnapshot';ActionPlanId='plan-synthetic';SourceRecommendationRunId=$Recommendations.RecommendationRunId;Status='Complete';IsReadOnly=$true;Items=@();ExecutionPerformed=$false;Counts=[PSCustomObject]@{Items=0}}
}
function New-EmptyExecution {
    param([object]$Plan,[bool]$Execute)
    return [PSCustomObject]@{RecordType='ExecutionSnapshot';ExecutionRunId='exec-synthetic';SourceActionPlanId=$Plan.ActionPlanId;ExecuteRequested=$Execute;Results=@();MutationAttempted=$false;Counts=[PSCustomObject]@{Results=0}}
}

Write-Host '===== Tetra Optimizer - End-to-End Pipeline Smoke Tests =====' -ForegroundColor Cyan

Test-Case 'Pipeline snapshot contract is complete and preview-first' {
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan} -AnalysisProvider ${function:New-EmptyAnalysis} -RecommendationProvider ${function:New-EmptyRecommendations} -ActionPlanProvider ${function:New-EmptyPlan} -ExecutionProvider ${function:New-EmptyExecution}
    Assert-Equal 'PipelineSnapshot' $p.RecordType 'Unexpected record type.';Assert-Equal 'Complete' $p.Status 'Pipeline should complete.';Assert-True (-not $p.ExecuteRequested) 'Execute must default false.';Assert-True (-not $p.MutationAttempted) 'Preview pipeline must not report mutation.'
}

Test-Case 'Pipeline reports all six ordered stages' {
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan} -AnalysisProvider ${function:New-EmptyAnalysis} -RecommendationProvider ${function:New-EmptyRecommendations} -ActionPlanProvider ${function:New-EmptyPlan} -ExecutionProvider ${function:New-EmptyExecution}
    Assert-Equal 6 @($p.Stages).Count 'Expected six stages.'
    Assert-Equal 'Scan' $p.Stages[0].Stage 'Stage 1 mismatch.';Assert-Equal 'Analysis' $p.Stages[1].Stage 'Stage 2 mismatch.';Assert-Equal 'Recommendations' $p.Stages[2].Stage 'Stage 3 mismatch.';Assert-Equal 'Approval' $p.Stages[3].Stage 'Stage 4 mismatch.';Assert-Equal 'ActionPlan' $p.Stages[4].Stage 'Stage 5 mismatch.';Assert-Equal 'Execution' $p.Stages[5].Stage 'Stage 6 mismatch.'
}

Test-Case 'No ApprovalProvider means no invented approval' {
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan} -AnalysisProvider ${function:New-EmptyAnalysis} -RecommendationProvider ${function:New-EmptyRecommendations} -ActionPlanProvider ${function:New-EmptyPlan} -ExecutionProvider ${function:New-EmptyExecution}
    Assert-True (-not $p.ApprovalProvided) 'Approval must remain absent.';Assert-Equal 0 @($p.Approval.ApprovedRecommendationIds).Count 'No IDs should be approved.'
}

Test-Case 'Real analysis and recommendation layers consume one synthetic scan' {
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan -WithCleanup} -ActionPlanProvider ${function:New-EmptyPlan} -ExecutionProvider ${function:New-EmptyExecution}
    Assert-Equal 'scan-synthetic' $p.Analysis.SourceScanId 'Analysis source scan mismatch.';Assert-Equal $p.Analysis.AnalysisId $p.Recommendations.SourceAnalysisId 'Recommendation source analysis mismatch.';Assert-Equal 1 @($p.Recommendations.Recommendations).Count 'Expected one cleanup recommendation.'
}

Test-Case 'Cleanup recommendation remains awaiting approval by default' {
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan -WithCleanup} -ExecutionProvider ${function:New-EmptyExecution}
    Assert-Equal 1 @($p.ActionPlan.Items).Count 'Expected one plan item.';Assert-Equal 'AwaitingApproval' $p.ActionPlan.Items[0].PlanState 'Cleanup must await approval.';Assert-True (-not $p.ActionPlan.Items[0].UserApproved) 'Approval must not be invented.'
}

Test-Case 'ApprovalProvider can approve generated recommendation id after recommendation stage' {
    $approval={param($r);$id=[string]$r.Recommendations[0].RecommendationId;[PSCustomObject]@{ApprovedRecommendationIds=@($id);DuplicateSelections=@{}}}
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan -WithCleanup} -ApprovalProvider $approval -ExecutionProvider ${function:New-EmptyExecution}
    Assert-True $p.ApprovalProvided 'Approval should be recorded.';Assert-Equal 'ReadyForExecution' $p.ActionPlan.Items[0].PlanState 'Approved cleanup should become ready.'
}

Test-Case 'Approved ready item is still preview-only without Execute' {
    $approval={param($r);[PSCustomObject]@{ApprovedRecommendationIds=@([string]$r.Recommendations[0].RecommendationId);DuplicateSelections=@{}}}
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan -WithCleanup} -ApprovalProvider $approval -PathExistsProvider {param($path)$true}
    Assert-Equal 'Preview' $p.Execution.Results[0].State 'Execution should remain preview.';Assert-True (-not $p.MutationAttempted) 'Preview must not mutate.'
}

Test-Case 'Execute alone cannot bypass missing approval' {
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan -WithCleanup} -Execute -PathExistsProvider {param($path)$true}
    Assert-Equal 'AwaitingApproval' $p.ActionPlan.Items[0].PlanState 'Item should still await approval.';Assert-Equal 'Blocked' $p.Execution.Results[0].State 'Non-ready item must be blocked.';Assert-True (-not $p.MutationAttempted) 'Execute without approval must not mutate.'
}

Test-Case 'Approved Execute path reaches backup delete and verification' {
    $approval={param($r);[PSCustomObject]@{ApprovedRecommendationIds=@([string]$r.Recommendations[0].RecommendationId);DuplicateSelections=@{}}}
    $state=[PSCustomObject]@{BackupCalls=0;DeleteCalls=0;Exists=@{'C:\Synthetic\Temp\cache.tmp'=$true}}
    $backup={param($paths,$item);$state.BackupCalls++;[PSCustomObject]@{Success=$true;BackupId='backup-1'}}.GetNewClosure()
    $delete={param($path,$item);$state.DeleteCalls++;$state.Exists[$path]=$false}.GetNewClosure()
    $pathExists={param($path);return [bool]$state.Exists[$path]}.GetNewClosure()
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan -WithCleanup} -ApprovalProvider $approval -Execute -BackupProvider $backup -DeleteProvider $delete -PathExistsProvider $pathExists
    Assert-Equal 'ExecutedVerified' $p.Execution.Results[0].State 'Approved execution should verify.';Assert-Equal 1 $state.BackupCalls 'Backup should run once.';Assert-Equal 1 $state.DeleteCalls 'Delete should run once.';Assert-True $p.MutationAttempted 'Mutation should be reported.'
}

Test-Case 'Unknown approval id fails at Approval stage' {
    $approval={param($r);[PSCustomObject]@{ApprovedRecommendationIds=@('not-real');DuplicateSelections=@{}}}
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan -WithCleanup} -ApprovalProvider $approval -ExecutionProvider ${function:New-EmptyExecution}
    Assert-Equal 'Failed' $p.Status 'Pipeline should fail honestly.';Assert-Equal 'Approval' $p.FailedStage 'Failure should be Approval.'
}

Test-Case 'Approval failure skips dependent ActionPlan and Execution stages' {
    $approval={param($r);[PSCustomObject]@{ApprovedRecommendationIds=@('not-real');DuplicateSelections=@{}}}
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan -WithCleanup} -ApprovalProvider $approval -ExecutionProvider ${function:New-EmptyExecution}
    Assert-Equal 'Skipped' $p.Stages[4].State 'ActionPlan must skip.';Assert-Equal 'Skipped' $p.Stages[5].State 'Execution must skip.'
}

Test-Case 'Scan failure is reported without invoking later stages' {
    $p=Invoke-TetraPipeline -ScanProvider {throw 'synthetic scan failure'} -AnalysisProvider {throw 'must not run'} -RecommendationProvider {throw 'must not run'} -ActionPlanProvider {throw 'must not run'} -ExecutionProvider {throw 'must not run'}
    Assert-Equal 'Failed' $p.Status 'Pipeline should fail.';Assert-Equal 'Scan' $p.FailedStage 'Failed stage mismatch.';Assert-Equal 'Failed' $p.Stages[0].State 'Scan should fail.';Assert-Equal 'Skipped' $p.Stages[1].State 'Analysis should skip.'
}

Test-Case 'Analysis failure preserves successful scan output' {
    $p=Invoke-TetraPipeline -ScanProvider {New-SyntheticScan} -AnalysisProvider {param($s,$profile);throw 'synthetic analysis failure'} -RecommendationProvider {throw 'must not run'} -ActionPlanProvider {throw 'must not run'} -ExecutionProvider {throw 'must not run'}
    Assert-Equal 'Analysis' $p.FailedStage 'Failed stage mismatch.';Assert-True ($null -ne $p.Scan) 'Successful scan output should survive.';Assert-Equal 'scan-synthetic' $p.Scan.ScanId 'Scan output changed.'
}

Test-Case 'Invalid stage output is rejected clearly' {
    $p=Invoke-TetraPipeline -ScanProvider {[PSCustomObject]@{RecordType='Wrong'}} -AnalysisProvider ${function:New-EmptyAnalysis} -RecommendationProvider ${function:New-EmptyRecommendations} -ActionPlanProvider ${function:New-EmptyPlan} -ExecutionProvider ${function:New-EmptyExecution}
    Assert-Equal 'Scan' $p.FailedStage 'Invalid scan shape should fail Scan.';Assert-True ($p.ErrorMessage -match 'SystemScanSnapshot') 'Failure should explain expected type.'
}

Test-Case 'Profile flows into real analysis layer' {
    $p=Invoke-TetraPipeline -Profile Gaming -ScanProvider {New-SyntheticScan} -RecommendationProvider ${function:New-EmptyRecommendations} -ActionPlanProvider ${function:New-EmptyPlan} -ExecutionProvider ${function:New-EmptyExecution}
    Assert-Equal 'Gaming' $p.Analysis.Profile 'Profile was not propagated.';Assert-Equal 'Gaming' $p.Profile 'Pipeline profile mismatch.'
}

Test-Case 'Pipeline source contains no direct mutation commands' {
    $source=Get-Content -LiteralPath (Join-Path $root 'Engine/PipelineEngine.ps1') -Raw
    foreach($token in @('Remove-Item','Set-ItemProperty','Stop-Service','Start-Service','Disable-ScheduledTask','Enable-ScheduledTask','pnputil','reg.exe delete')){Assert-True (-not $source.Contains($token)) "Found direct mutation token '$token'."}
}

Test-Case 'Execution responsibility remains delegated to ExecutionEngine' {
    $source=Get-Content -LiteralPath (Join-Path $root 'Engine/PipelineEngine.ps1') -Raw
    Assert-True ($source.Contains('Invoke-TetraExecution')) 'Pipeline must delegate execution.';Assert-True (-not $source.Contains('Backup-TetraItem')) 'Pipeline must not implement backup itself.';Assert-True (-not $source.Contains('Restore-TetraBackup')) 'Pipeline must not implement rollback itself.'
}

Write-Host ''
Write-Host "PASS: $pass/17" -ForegroundColor $(if($pass -eq 17){'Green'}else{'Yellow'})
Write-Host "FAIL: $fail/17" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
if($fail -gt 0){exit 1}
