#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$entry=Join-Path $root 'Invoke-Tetra.ps1'
$pass=0;$fail=0
function T([string]$n,[scriptblock]$b){try{& $b;Write-Host "[PASS] $n" -ForegroundColor Green;$script:pass++}catch{Write-Host "[FAIL] $n" -ForegroundColor Red;Write-Host "  -> $($_.Exception.Message)" -ForegroundColor Yellow;$script:fail++}}
function Assert([bool]$c,[string]$m){if(-not $c){throw $m}}
function Scan(){return [PSCustomObject]@{RecordType='SystemScanSnapshot';ScanId='runtime-scan';Status='Complete';FileWorkRequested=$false;RootPaths=@();Processes=@();Services=@();Startup=@();Applications=@();ScheduledTasks=@();Drivers=@();StorageVolumes=@();Files=@();Cleanup=@();Duplicates=@();AnalyzerState=@();Errors=@()}}
$scanFixture=Scan
$analysisFixture=[PSCustomObject]@{RecordType='SystemAnalysisSnapshot';Findings=@()}
$recommendationFixture=[PSCustomObject]@{RecordType='RecommendationSnapshot';Recommendations=@()}
$planFixture=[PSCustomObject]@{RecordType='ActionPlanSnapshot';ActionPlanId='p';ExecutionPerformed=$false;Items=@()}
$executionPreview=[PSCustomObject]@{RecordType='ExecutionSnapshot';ExecutionRunId='e';MutationAttempted=$false;Results=@()}
$scanProvider={ $scanFixture }.GetNewClosure()
$analysisProvider={param($s,$p)$analysisFixture}.GetNewClosure()
$recommendationProvider={param($a)$recommendationFixture}.GetNewClosure()
$actionPlanProvider={param($r,$a)$planFixture}.GetNewClosure()
$executionProvider={param($p,$e)$executionPreview}.GetNewClosure()
$providers=@{
 ScanProvider=$scanProvider
 AnalysisProvider=$analysisProvider
 RecommendationProvider=$recommendationProvider
 ActionPlanProvider=$actionPlanProvider
 ExecutionProvider=$executionProvider
}
Write-Host '===== Tetra Optimizer - Production Runtime Smoke Tests =====' -ForegroundColor Cyan
T 'Runtime entry point exists' {Assert (Test-Path -LiteralPath $entry -PathType Leaf) 'Invoke-Tetra.ps1 missing.'}
T 'Default runtime mode is preview and read-only' {$x=& $entry @providers -PassThru;Assert ($x.RecordType -eq 'TetraRuntimeResult') 'Runtime result missing.';Assert ($x.Mode -eq 'Preview') "Mode $($x.Mode).";Assert (-not $x.MutationAttempted) 'Preview attempted mutation.'}
T 'Preview produces pipeline and report without approval provider' {$x=& $entry @providers -PassThru;Assert ($x.Pipeline.RecordType -eq 'PipelineSnapshot') 'Pipeline missing.';Assert ($x.Report.RecordType -eq 'ClientReportSnapshot') 'Report missing.'}
T 'Execute cannot run without explicit approval provider' {$thrown=$false;try{& $entry @providers -Execute -Confirm:$false -PassThru | Out-Null}catch{$thrown=$true};Assert $thrown 'Execute without ApprovalProvider was accepted.'}
T 'PassThru exposes lifecycle metadata' {$x=& $entry @providers -PassThru;Assert (-not [string]::IsNullOrWhiteSpace($x.PipelineRunId)) 'PipelineRunId missing.';Assert ($x.Status -eq 'Complete') "Status $($x.Status).";Assert ($x.LifecycleStatus -eq 'Complete') "Lifecycle $($x.LifecycleStatus)."}
T 'Without PassThru runtime returns client report only' {$x=& $entry @providers;Assert ($x.RecordType -eq 'ClientReportSnapshot') 'Expected client report.'}
T 'Profile flows through production entry point' {$x=& $entry @providers -Profile Gaming -PassThru;Assert ($x.Pipeline.Profile -eq 'Gaming') "Profile $($x.Pipeline.Profile)."}
T 'File-heavy switches flow into scan provider contract safely' {$seen=[ref]$false;$p=$providers.Clone();$scanFixtureForFlag=$scanFixture;$p.ScanProvider={ $seen.Value=$true; $scanFixtureForFlag }.GetNewClosure();& $entry @p -IncludeFileInventory -IncludeCleanup -IncludeDuplicates -RootPaths @('C:\Synthetic') -PassThru | Out-Null;Assert $seen.Value 'Scan provider was not invoked.'}
T 'Invalid MaxFiles is rejected before pipeline execution' {$thrown=$false;try{& $entry @providers -MaxFiles 0 -PassThru | Out-Null}catch{$thrown=$true};Assert $thrown 'Invalid MaxFiles accepted.'}
T 'Execution path can be exercised with explicit approval and injected provider without mutation' {$approval={param($r)[PSCustomObject]@{ApprovedRecommendationIds=@();DuplicateSelections=@{}}};$x=& $entry @providers -ApprovalProvider $approval -Execute -Confirm:$false -PassThru;Assert ($x.Mode -eq 'Execute') 'Execute mode missing.';Assert (-not $x.MutationAttempted) 'Injected non-mutating execution claimed mutation.'}
T 'Runtime source contains no direct mutation commands' {$s=Get-Content -LiteralPath $entry -Raw;foreach($token in @('Remove-Item','Set-ItemProperty','Stop-Service','Disable-ScheduledTask','Remove-ItemProperty')){Assert (-not ($s -match [regex]::Escape($token))) "Found direct mutation token $token."}}
T 'Runtime delegates execution to PipelineEngine' {$s=Get-Content -LiteralPath $entry -Raw;Assert ($s -match 'Invoke-TetraPipeline') 'Pipeline delegation missing.';Assert (-not ($s -match 'Invoke-TetraExecution\s')) 'Runtime directly invokes execution engine.'}
Write-Host ''
Write-Host "PASS: $pass/12" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Yellow'})
Write-Host "FAIL: $fail/12" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
if($fail -gt 0){exit 1}
