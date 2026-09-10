#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Engine/PostExecutionVerificationEngine.ps1')
$pass=0;$fail=0
function Test-Case([string]$Name,[scriptblock]$Body){try{&$Body;Write-Host "[PASS] $Name" -ForegroundColor Green;$script:pass++}catch{Write-Host "[FAIL] $Name" -ForegroundColor Red;Write-Host "       -> $($_.Exception.Message)" -ForegroundColor Yellow;$script:fail++}}
function Assert-True([bool]$v,[string]$m){if(-not$v){throw$m}}
function Assert-Equal($e,$a,[string]$m){if($e-ne$a){throw "$m Expected='$e' Actual='$a'."}}

function New-Scan([string]$Id,[object[]]$Files,[long]$FreeBytes,[string]$Status='Complete',[bool]$FileWork=$true){
    $used=100000-$FreeBytes
    return [PSCustomObject]@{RecordType='SystemScanSnapshot';ScanId=$Id;Status=$Status;FileWorkRequested=$FileWork;RootPaths=if($FileWork){@('C:\Synthetic')}else{@()};Processes=@();Services=@();Startup=@();Applications=@();ScheduledTasks=@();Drivers=@();StorageVolumes=@([PSCustomObject]@{DeviceId='C:';FreeBytes=$FreeBytes;UsedBytes=$used});Files=@($Files);Cleanup=@();Duplicates=@()}
}
function New-File([string]$Path,[long]$Size=2048){[PSCustomObject]@{RecordType='FileMetadata';FullPath=$Path;SizeBytes=$Size}}
function New-Execution([string]$Action='CleanupFile',[string[]]$Targets=@('C:\Synthetic\cache.tmp'),[string]$KeepPath='',[string]$State='ExecutedVerified'){
    [PSCustomObject]@{RecordType='ExecutionSnapshot';ExecutionRunId='exec-1';Results=@([PSCustomObject]@{PlanItemId='plan-1';RecommendationId='rec-1';Subject='synthetic';ProposedAction=$Action;State=$State;Preflight=[PSCustomObject]@{Targets=$Targets;KeepPath=$KeepPath}})}
}

Write-Host '===== Tetra Optimizer - Post-Execution Rescan Verification Smoke Tests =====' -ForegroundColor Cyan
Test-Case 'Verification snapshot contract is complete and read-only' {$b=New-Scan 'before' @((New-File 'C:\Synthetic\cache.tmp')) 50000;$a=New-Scan 'after' @() 52048;$r=Compare-TetraPostExecutionRescan $b $a (New-Execution);Assert-Equal 'PostExecutionVerificationSnapshot' $r.RecordType 'Record type mismatch.';Assert-True $r.IsReadOnly 'Must be read-only.';Assert-Equal 'before' $r.BeforeScanId 'Before id mismatch.';Assert-Equal 'after' $r.AfterScanId 'After id mismatch.'}
Test-Case 'Deleted cleanup target is verified absent by rescan' {$b=New-Scan 'b' @((New-File 'C:\Synthetic\cache.tmp')) 50000;$a=New-Scan 'a' @() 52048;$r=Compare-TetraPostExecutionRescan $b $a (New-Execution);Assert-Equal 'Verified' $r.TargetVerifications[0].VerificationState 'Expected verified target.';Assert-Equal 'C:\Synthetic\cache.tmp' $r.TargetVerifications[0].ConfirmedMissingPaths[0] 'Missing path mismatch.'}
Test-Case 'Target still present after execution becomes verification failure' {$b=New-Scan 'b' @((New-File 'C:\Synthetic\cache.tmp')) 50000;$a=New-Scan 'a' @((New-File 'C:\Synthetic\cache.tmp')) 50000;$r=Compare-TetraPostExecutionRescan $b $a (New-Execution);Assert-Equal 'Failed' $r.TargetVerifications[0].VerificationState 'Expected failed verification.';Assert-Equal 'VerificationFailed' $r.Status 'Snapshot status mismatch.'}
Test-Case 'Duplicate verification confirms deleted copy and retained keep path' {$keep=New-File 'C:\Synthetic\keep.bin';$copy=New-File 'C:\Synthetic\copy.bin';$b=New-Scan 'b' @($keep,$copy) 40000;$a=New-Scan 'a' @($keep) 42048;$e=New-Execution -Action 'RemoveDuplicateCopies' -Targets @('C:\Synthetic\copy.bin') -KeepPath 'C:\Synthetic\keep.bin';$r=Compare-TetraPostExecutionRescan $b $a $e;Assert-Equal 'Verified' $r.TargetVerifications[0].VerificationState 'Duplicate should verify.';Assert-True ($r.TargetVerifications[0].KeepPathObserved -eq $true) 'Keep path must remain.'}
Test-Case 'Missing duplicate keep path fails verification' {$keep=New-File 'C:\Synthetic\keep.bin';$copy=New-File 'C:\Synthetic\copy.bin';$b=New-Scan 'b' @($keep,$copy) 40000;$a=New-Scan 'a' @() 44096;$e=New-Execution -Action 'RemoveDuplicateCopies' -Targets @('C:\Synthetic\copy.bin') -KeepPath 'C:\Synthetic\keep.bin';$r=Compare-TetraPostExecutionRescan $b $a $e;Assert-Equal 'Failed' $r.TargetVerifications[0].VerificationState 'Missing keep path must fail.'}
Test-Case 'No file evidence produces honest Unknown instead of success' {$b=New-Scan 'b' @() 50000 -FileWork:$false;$a=New-Scan 'a' @() 52048 -FileWork:$false;$r=Compare-TetraPostExecutionRescan $b $a (New-Execution);Assert-Equal 'Unknown' $r.TargetVerifications[0].VerificationState 'Expected Unknown.';Assert-Equal 'VerificationIncomplete' $r.Status 'Expected incomplete status.'}
Test-Case 'Non-executed result is NotApplicable' {$b=New-Scan 'b' @() 50000;$a=New-Scan 'a' @() 50000;$r=Compare-TetraPostExecutionRescan $b $a (New-Execution -State 'Preview');Assert-Equal 'NotApplicable' $r.TargetVerifications[0].VerificationState 'Preview must not be post-verified.'}
Test-Case 'Observed free-space delta is calculated but not attributed' {$b=New-Scan 'b' @() 50000;$a=New-Scan 'a' @() 53000;$r=Compare-TetraPostExecutionRescan $b $a $null;Assert-Equal 3000 $r.VolumeDeltas[0].FreeBytesDelta 'Free delta mismatch.';Assert-Equal 'ObservedOnly' $r.VolumeDeltas[0].Attribution 'Attribution must remain observational.'}
Test-Case 'Inventory count deltas are reported from before and after snapshots' {$b=New-Scan 'b' @((New-File 'C:\Synthetic\a.tmp'),(New-File 'C:\Synthetic\b.tmp')) 50000;$a=New-Scan 'a' @((New-File 'C:\Synthetic\a.tmp')) 51000;$r=Compare-TetraPostExecutionRescan $b $a $null;$files=@($r.CountDeltas|Where-Object{$_.Section-eq'Files'})[0];Assert-Equal 2 $files.Before 'Before count mismatch.';Assert-Equal 1 $files.After 'After count mismatch.';Assert-Equal -1 $files.Delta 'Delta mismatch.'}
Test-Case 'Partial after-scan remains honestly Partial' {$b=New-Scan 'b' @() 50000;$a=New-Scan 'a' @() 50000 -Status 'Partial';$r=Compare-TetraPostExecutionRescan $b $a $null;Assert-Equal 'Partial' $r.Status 'Partial status must be preserved.'}
Test-Case 'Invalid before snapshot is rejected clearly' {try{Compare-TetraPostExecutionRescan ([PSCustomObject]@{RecordType='Wrong'}) (New-Scan 'a' @() 1) $null|Out-Null;throw 'Expected rejection.'}catch{Assert-True ($_.Exception.Message -match 'BeforeSnapshot') 'Wrong rejection message.'}}
Test-Case 'Invalid after snapshot is rejected clearly' {try{Compare-TetraPostExecutionRescan (New-Scan 'b' @() 1) ([PSCustomObject]@{RecordType='Wrong'}) $null|Out-Null;throw 'Expected rejection.'}catch{Assert-True ($_.Exception.Message -match 'AfterSnapshot') 'Wrong rejection message.'}}
Test-Case 'Invalid execution snapshot is rejected clearly' {try{Compare-TetraPostExecutionRescan (New-Scan 'b' @() 1) (New-Scan 'a' @() 1) ([PSCustomObject]@{RecordType='Wrong'})|Out-Null;throw 'Expected rejection.'}catch{Assert-True ($_.Exception.Message -match 'ExecutionSnapshot') 'Wrong rejection message.'}}
Test-Case 'Verification source contains no mutation command invocations' {$source=Get-Content -LiteralPath (Join-Path $root 'Engine/PostExecutionVerificationEngine.ps1') -Raw;foreach($token in @('Remove-Item','Set-ItemProperty','Stop-Service','Start-Service','Disable-ScheduledTask','Enable-ScheduledTask','pnputil','reg.exe delete')){Assert-True (-not $source.Contains($token)) "Found mutation token '$token'."}}

Write-Host ''
Write-Host "PASS: $pass/14" -ForegroundColor $(if($pass-eq14){'Green'}else{'Yellow'})
Write-Host "FAIL: $fail/14" -ForegroundColor $(if($fail-eq0){'Green'}else{'Red'})
Write-Host "Overall: $(if($fail-eq0){'PASS'}else{'FAIL'})" -ForegroundColor $(if($fail-eq0){'Green'}else{'Red'})
if($fail-gt0){exit 1}
