#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Engine\PipelineEngine.ps1')
$pass=0;$fail=0
function T([string]$n,[scriptblock]$b){try{& $b;Write-Host "[PASS] $n" -ForegroundColor Green;$script:pass++}catch{Write-Host "[FAIL] $n" -ForegroundColor Red;Write-Host "  -> $($_.Exception.Message)" -ForegroundColor Yellow;$script:fail++}}
function Assert([bool]$c,[string]$m){if(-not $c){throw $m}}
function Scan([string]$id,[string[]]$paths,[long]$free=1000,[string]$status='Complete'){
 $files=@();foreach($p in @($paths)){$files+=[PSCustomObject]@{FullPath=$p;SizeBytes=100}}
 return [PSCustomObject]@{RecordType='SystemScanSnapshot';ScanId=$id;Status=$status;FileWorkRequested=$true;RootPaths=@('C:\Synthetic');Processes=@();Services=@();Startup=@();Applications=@();ScheduledTasks=@();Drivers=@();StorageVolumes=@([PSCustomObject]@{DeviceId='C:';FreeBytes=$free;UsedBytes=(10000-$free)});Files=@($files);Cleanup=@();Duplicates=@();AnalyzerState=@();Errors=@()}
}
$script:beforeFixture=Scan 'before' @('C:\Synthetic\temp.tmp') 1000
$script:afterFixture=Scan 'after' @() 1100
$script:analysisFixture=[PSCustomObject]@{RecordType='SystemAnalysisSnapshot';Findings=@()}
$script:recommendationFixture=[PSCustomObject]@{RecordType='RecommendationSnapshot';Recommendations=@([PSCustomObject]@{RecommendationId='r1';Subject='temp.tmp';Recommendation='Cleanup';ProposedAction='CleanupFile';RequiresUserApproval=$true;Confidence='High';Reason='Synthetic'})}
$script:planFixture=[PSCustomObject]@{RecordType='ActionPlanSnapshot';ActionPlanId='p1';ExecutionPerformed=$false;Items=@([PSCustomObject]@{RecordType='ActionPlanItem';PlanItemId='i1';RecommendationId='r1';Subject='temp.tmp';ProposedAction='CleanupFile';PlanState='ReadyForExecution';ExecutionReady=$true;UserApproved=$true;RequiresUserApproval=$true;BackupRequired=$true;RollbackStrategy='BackupBeforeChange';Executed=$false;Target='C:\Synthetic\temp.tmp';PotentialReclaimBytes=100;Reason='Synthetic'})}
$script:executionFixture=[PSCustomObject]@{RecordType='ExecutionSnapshot';ExecutionRunId='e1';MutationAttempted=$true;Results=@([PSCustomObject]@{RecordType='ExecutionResult';PlanItemId='i1';RecommendationId='r1';Subject='temp.tmp';ProposedAction='CleanupFile';State='ExecutedVerified';Verified=$true;BytesReclaimed=100;BackupCreated=$true;BackupId='b1';RollbackAttempted=$false;RollbackSucceeded=$false;Message='ok';Preflight=[PSCustomObject]@{Targets=@('C:\Synthetic\temp.tmp');KeepPath=''}})}
$baseArgs=@{Profile='Balanced';RootPaths=@('C:\Synthetic');IncludeFileInventory=$true;Execute=$true;ScanProvider={$script:beforeFixture};AnalysisProvider={param($s,$p)$script:analysisFixture};RecommendationProvider={param($a)$script:recommendationFixture};ApprovalProvider={param($r)[PSCustomObject]@{ApprovedRecommendationIds=@('r1');DuplicateSelections=@{}}};ActionPlanProvider={param($r,$a)$script:planFixture};ExecutionProvider={param($p,$e)$script:executionFixture};PostExecutionScanProvider={param($b,$e)$script:afterFixture}}
Write-Host '===== Tetra Optimizer - Pipeline Post-Execution Integration Smoke Tests =====' -ForegroundColor Cyan
$p=Invoke-TetraPipeline @baseArgs
T 'Core six-stage contract remains intact' {Assert ($p.StageCount -eq 6) "Expected 6 core stages; got $($p.StageCount)."}
T 'Mutation triggers post-execution rescan when provider is supplied' {Assert ($p.PostExecutionRescanState -eq 'Completed') "Rescan state $($p.PostExecutionRescanState).";Assert ($p.AfterScan.ScanId -eq 'after') 'After scan missing.'}
T 'Pipeline invokes real post-execution verification' {Assert ($p.PostExecutionVerificationState -eq 'Completed') "Verification state $($p.PostExecutionVerificationState).";Assert ($p.PostExecutionVerification.RecordType -eq 'PostExecutionVerificationSnapshot') 'Verification snapshot missing.'}
T 'Deleted target is verified absent by integrated rescan' {Assert ($p.PostExecutionVerification.Counts.Verified -eq 1) 'Expected one verified target.';Assert ($p.PostExecutionVerification.TargetVerifications[0].VerificationState -eq 'Verified') 'Target not verified.'}
T 'Pipeline automatically builds client report after verification' {Assert ($p.ReportState -eq 'Completed') "Report state $($p.ReportState).";Assert ($p.Report.RecordType -eq 'ClientReportSnapshot') 'Report missing.'}
T 'Report After section uses post-execution rescan evidence' {Assert ($p.Report.After.EvidenceScope -eq 'PostExecutionRescan') "EvidenceScope $($p.Report.After.EvidenceScope).";Assert ($p.Report.After.AfterScanId -eq 'after') 'AfterScanId mismatch.'}
T 'Observed storage delta flows into final report without attribution' {Assert ($p.Report.After.ObservedVolumeDeltas.Count -eq 1) 'Expected volume delta.';Assert ($p.Report.After.ObservedVolumeDeltas[0].FreeBytesDelta -eq 100) 'Free delta mismatch.';Assert ($p.Report.After.ObservedVolumeDeltas[0].Attribution -eq 'ObservedOnly') 'Delta was attributed.'}
T 'Custom execution without post-scan provider never causes hidden live rescan' {$a=$baseArgs.Clone();$a.Remove('PostExecutionScanProvider');$x=Invoke-TetraPipeline @a;Assert ($x.PostExecutionRescanState -eq 'NotApplicable') "Unexpected rescan state $($x.PostExecutionRescanState)."}
T 'Preview execution does not trigger post-execution lifecycle' {$a=$baseArgs.Clone();$a.Execute=$false;$x=Invoke-TetraPipeline @a;Assert ($x.PostExecutionRescanState -eq 'NotApplicable') 'Preview triggered rescan.'}
T 'Rescan failure is honest and does not erase successful core execution' {$a=$baseArgs.Clone();$a.PostExecutionScanProvider={throw 'synthetic rescan failure'};$x=Invoke-TetraPipeline @a;Assert ($x.Status -eq 'Complete') 'Core status was destroyed.';Assert ($x.LifecycleStatus -eq 'CompletedWithPostExecutionIssues') 'Lifecycle issue not reported.';Assert ($x.PostExecutionRescanState -eq 'Failed') 'Rescan failure not recorded.';Assert ($x.PostExecutionErrors.Count -ge 1) 'Post error missing.'}
T 'Partial after-scan is preserved honestly in verification and report' {$script:partialFixture=Scan 'partial-after' @() 1100 'Partial';$a=$baseArgs.Clone();$a.PostExecutionScanProvider={param($b,$e)$script:partialFixture};$x=Invoke-TetraPipeline @a;Assert ($x.PostExecutionVerification.Status -eq 'Partial') 'Partial verification not preserved.';Assert ($x.Report.After.AfterScanStatus -eq 'Partial') 'Partial report after-state not preserved.'}
T 'Pipeline and reporting integration do not contain mutation commands' {$s=(Get-Content -LiteralPath (Join-Path $root 'Engine\PipelineEngine.ps1') -Raw)+' '+(Get-Content -LiteralPath (Join-Path $root 'Engine\ReportingEngine.ps1') -Raw);foreach($token in @('Remove-Item','Set-ItemProperty','Stop-Service','Disable-ScheduledTask')){Assert (-not ($s -match [regex]::Escape($token))) "Found mutation token $token."}}
Write-Host ''
Write-Host "PASS: $pass/12" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Yellow'})
Write-Host "FAIL: $fail/12" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
if($fail -gt 0){exit 1}
