#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\ActionPlanEngine.ps1')
. (Join-Path $projectRoot 'Engine\ExecutionEngine.ps1')

$results=[System.Collections.Generic.List[PSCustomObject]]::new()
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Invoke-Test{param([string]$Name,[scriptblock]$Body)try{& $Body|Out-Null;$results.Add([PSCustomObject]@{TestName=$Name;Passed=$true;ErrorMessage=''})}catch{$results.Add([PSCustomObject]@{TestName=$Name;Passed=$false;ErrorMessage=$_.Exception.Message})}}

function New-ExecutionTestItem{
 param([string]$Id='rec-1',[string]$State='ReadyForExecution',[string]$Action='CleanupFile',[string]$Target='C:\Synthetic\temp.tmp',[bool]$Approved=$true,[bool]$BackupRequired=$true,[string]$KeepPath='',[string[]]$DeletePaths=@(),[string[]]$EvidencePaths=@())
 $dup=[PSCustomObject]@{Paths=@($EvidencePaths)};$finding=[PSCustomObject]@{Evidence=$dup};$recommendation=[PSCustomObject]@{Evidence=$finding}
 return [PSCustomObject]@{RecordType='ActionPlanItem';PlanItemId="plan-$Id";RecommendationId=$Id;Subject=$Id;PlanState=$State;ProposedAction=$Action;Target=$Target;KnowledgeBaseId='';Confidence='High';RequiresUserApproval=$true;UserApproved=$Approved;BackupRequired=$BackupRequired;RollbackStrategy='BackupBeforeChange';KeepPath=$KeepPath;DeletePaths=@($DeletePaths);PotentialReclaimBytes=1234;ExecutionReady=($State -eq 'ReadyForExecution');ExecutionRequested=$false;Executed=$false;Evidence=$recommendation}
}
function New-ExecutionTestPlan{param([object[]]$Items=@())return [PSCustomObject]@{RecordType='ActionPlanSnapshot';ActionPlanId='plan-run';ExecutionPerformed=$false;Items=@($Items)}}
function New-FakeBackup{param([string]$Id='backup-test')return [PSCustomObject]@{Success=$true;BackupId=$Id}}

Invoke-Test 'Execution state contract is complete' {
 $s=@(Get-TetraExecutionStates);foreach($x in @('Preview','Blocked','PreflightFailed','WhatIf','ExecutedVerified','ExecutionFailed','RolledBack','RollbackFailed')){Assert-True ($s -contains $x) "Missing state $x."}
}
Invoke-Test 'Invalid input is rejected clearly' {
 $threw=$false;try{Invoke-TetraExecution -ActionPlan ([PSCustomObject]@{RecordType='Nope'})|Out-Null}catch{$threw=$true};Assert-True $threw 'Invalid action plan should throw.'
}
Invoke-Test 'Non-ready item is blocked even when Execute is requested' {
 $i=New-ExecutionTestItem -State 'NeedsReview';$r=Invoke-TetraExecution -ActionPlan (New-ExecutionTestPlan @($i)) -Execute -Confirm:$false;Assert-True ($r.Results[0].State -eq 'Blocked') 'Non-ready item must be blocked.'
}
Invoke-Test 'Ready cleanup is preview-only without Execute' {
 $backupCalls=0;$deleteCalls=0;$i=New-ExecutionTestItem
 $r=Invoke-TetraExecution -ActionPlan (New-ExecutionTestPlan @($i)) -PathExistsProvider {param($p)$true} -BackupProvider {param($p,$x)$script:backupCalls++;New-FakeBackup} -DeleteProvider {param($p,$x)$script:deleteCalls++}
 Assert-True ($r.Results[0].State -eq 'Preview') 'Expected Preview.';Assert-True (-not $r.MutationAttempted) 'Preview must not mutate.'
}
Invoke-Test 'Preflight rejects missing cleanup target' {
 $i=New-ExecutionTestItem;$p=Test-TetraExecutionPreflight -PlanItem $i -PathExistsProvider {param($p)$false};Assert-True (-not $p.IsValid) 'Missing target must fail preflight.'
}
Invoke-Test 'Preflight rejects unsupported action types' {
 $i=New-ExecutionTestItem -Action 'DisableService';$p=Test-TetraExecutionPreflight -PlanItem $i -PathExistsProvider {param($p)$true};Assert-True (-not $p.IsValid) 'Unsupported action must fail.'
}
Invoke-Test 'Preflight requires explicit user approval' {
 $i=New-ExecutionTestItem -Approved $false;$p=Test-TetraExecutionPreflight -PlanItem $i -PathExistsProvider {param($p)$true};Assert-True (-not $p.IsValid) 'Unapproved item must fail.'
}
Invoke-Test 'Preflight requires mandatory backup contract' {
 $i=New-ExecutionTestItem -BackupRequired $false;$p=Test-TetraExecutionPreflight -PlanItem $i -PathExistsProvider {param($p)$true};Assert-True (-not $p.IsValid) 'BackupRequired false must fail.'
}
Invoke-Test 'Backup failure prevents every delete attempt' {
 $script:deleteCalls=0;$i=New-ExecutionTestItem
 $r=Invoke-TetraExecution -ActionPlan (New-ExecutionTestPlan @($i)) -Execute -Confirm:$false -PathExistsProvider {param($p)$true} -BackupProvider {param($p,$x)[PSCustomObject]@{Success=$false;BackupId=''}} -DeleteProvider {param($p,$x)$script:deleteCalls++}
 Assert-True ($r.Results[0].State -eq 'ExecutionFailed') 'Backup failure should be ExecutionFailed.';Assert-True ($script:deleteCalls -eq 0) 'Delete must not run after backup failure.'
}
Invoke-Test 'Successful cleanup executes only after backup and verifies absence' {
 $root=Join-Path ([IO.Path]::GetTempPath()) ("TetraExec_"+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root|Out-Null;$file=Join-Path $root 'cache.tmp';Set-Content -LiteralPath $file -Value 'x'
 try{$i=New-ExecutionTestItem -Target $file;$r=Invoke-TetraExecution -ActionPlan (New-ExecutionTestPlan @($i)) -Execute -Confirm:$false -BackupProvider {param($p,$x)New-FakeBackup};Assert-True ($r.Results[0].State -eq 'ExecutedVerified') 'Cleanup should verify.';Assert-True (-not(Test-Path -LiteralPath $file)) 'File should be deleted.';Assert-True $r.Results[0].BackupCreated 'Backup must be recorded.'}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
Invoke-Test 'Duplicate preflight accepts only exact confirmed evidence paths' {
 $i=New-ExecutionTestItem -Action 'RemoveDuplicateCopies' -Target '' -KeepPath 'C:\A.bin' -DeletePaths @('D:\B.bin') -EvidencePaths @('C:\A.bin','D:\B.bin')
 $p=Test-TetraExecutionPreflight -PlanItem $i -PathExistsProvider {param($x)$true};Assert-True $p.IsValid 'Exact duplicate selection should pass.'
}
Invoke-Test 'Duplicate preflight rejects path outside confirmed evidence' {
 $i=New-ExecutionTestItem -Action 'RemoveDuplicateCopies' -Target '' -KeepPath 'C:\A.bin' -DeletePaths @('E:\C.bin') -EvidencePaths @('C:\A.bin','D:\B.bin')
 $p=Test-TetraExecutionPreflight -PlanItem $i -PathExistsProvider {param($x)$true};Assert-True (-not $p.IsValid) 'Outside path must fail.'
}
Invoke-Test 'Duplicate preflight never allows KeepPath in DeletePaths' {
 $i=New-ExecutionTestItem -Action 'RemoveDuplicateCopies' -Target '' -KeepPath 'C:\A.bin' -DeletePaths @('C:\A.bin') -EvidencePaths @('C:\A.bin','D:\B.bin')
 $p=Test-TetraExecutionPreflight -PlanItem $i -PathExistsProvider {param($x)$true};Assert-True (-not $p.IsValid) 'KeepPath in DeletePaths must fail.'
}
Invoke-Test 'Successful duplicate cleanup preserves retained copy and verifies deletes' {
 $root=Join-Path ([IO.Path]::GetTempPath()) ("TetraDupExec_"+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root|Out-Null;$a=Join-Path $root 'A.bin';$b=Join-Path $root 'B.bin';Set-Content $a 'same';Set-Content $b 'same'
 try{$i=New-ExecutionTestItem -Action 'RemoveDuplicateCopies' -Target '' -KeepPath $a -DeletePaths @($b) -EvidencePaths @($a,$b);$r=Invoke-TetraExecution -ActionPlan (New-ExecutionTestPlan @($i)) -Execute -Confirm:$false -BackupProvider {param($p,$x)New-FakeBackup};Assert-True ($r.Results[0].State -eq 'ExecutedVerified') 'Duplicate cleanup should verify.';Assert-True (Test-Path $a) 'KeepPath must remain.';Assert-True (-not(Test-Path $b)) 'DeletePath must be removed.'}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
Invoke-Test 'Verification failure triggers rollback and reports RolledBack' {
 $script:existsCalls=0;$script:rollbackCalls=0;$i=New-ExecutionTestItem
 $r=Invoke-TetraExecution -ActionPlan (New-ExecutionTestPlan @($i)) -Execute -Confirm:$false -PathExistsProvider {param($p)$true} -BackupProvider {param($p,$x)New-FakeBackup} -DeleteProvider {param($p,$x)} -RollbackProvider {param($id,$x)$script:rollbackCalls++;[PSCustomObject]@{Success=$true}}
 Assert-True ($r.Results[0].State -eq 'RolledBack') 'Verification failure should roll back.';Assert-True ($script:rollbackCalls -eq 1) 'Rollback must be attempted once.'
}
Invoke-Test 'Rollback failure is never hidden' {
 $i=New-ExecutionTestItem;$r=Invoke-TetraExecution -ActionPlan (New-ExecutionTestPlan @($i)) -Execute -Confirm:$false -PathExistsProvider {param($p)$true} -BackupProvider {param($p,$x)New-FakeBackup} -DeleteProvider {param($p,$x)throw 'delete failed'} -RollbackProvider {param($id,$x)[PSCustomObject]@{Success=$false}}
 Assert-True ($r.Results[0].State -eq 'RollbackFailed') 'Rollback failure must be explicit.';Assert-True $r.Results[0].RollbackAttempted 'RollbackAttempted should be true.'
}
Invoke-Test 'WhatIf performs no backup and no mutation' {
 $script:b=0;$script:d=0;$i=New-ExecutionTestItem;$r=Invoke-TetraExecution -ActionPlan (New-ExecutionTestPlan @($i)) -Execute -WhatIf -PathExistsProvider {param($p)$true} -BackupProvider {param($p,$x)$script:b++;New-FakeBackup} -DeleteProvider {param($p,$x)$script:d++};Assert-True ($r.Results[0].State -eq 'WhatIf') 'Expected WhatIf state.';Assert-True ($script:b -eq 0 -and $script:d -eq 0) 'WhatIf must not backup or delete.'
}
Invoke-Test 'Execution counts agree with returned results' {
 $a=New-ExecutionTestItem -Id 'a';$b=New-ExecutionTestItem -Id 'b' -State 'Blocked';$r=Invoke-TetraExecution -ActionPlan (New-ExecutionTestPlan @($a,$b)) -PathExistsProvider {param($p)$true};Assert-True ($r.Counts.Results -eq @($r.Results).Count) 'Result count mismatch.';Assert-True ($r.Counts.Preview -eq 1 -and $r.Counts.Blocked -eq 1) 'State counts mismatch.'
}
Invoke-Test 'Execution engine only contains intended V1 mutation command family' {
 $path=Join-Path $projectRoot 'Engine\ExecutionEngine.ps1';$tokens=$null;$parseErrors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors);Assert-True (@($parseErrors).Count -eq 0) 'ExecutionEngine has parse errors.';$commands=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_});foreach($name in @('Set-ItemProperty','New-ItemProperty','Remove-ItemProperty','Disable-Service','Stop-Service','Set-Service','Unregister-ScheduledTask','Disable-ScheduledTask','pnputil.exe','sc.exe','reg.exe')){Assert-True ($commands -notcontains $name) "Unexpected V1 mutation command '$name'."};Assert-True ($commands -contains 'Remove-Item') 'V1 file execution should contain Remove-Item.'
}

$pass=@($results|Where-Object{$_.Passed}).Count;$fail=@($results|Where-Object{-not $_.Passed}).Count
Write-Host '';Write-Host '===== Tetra Optimizer - Execution / Preflight / Verification Smoke Tests =====' -ForegroundColor Cyan
foreach($r in $results){$s=if($r.Passed){'PASS'}else{'FAIL'};$c=if($r.Passed){'Green'}else{'Red'};Write-Host "[$s] $($r.TestName)" -ForegroundColor $c;if(-not $r.Passed){Write-Host "        -> $($r.ErrorMessage)" -ForegroundColor DarkYellow}}
Write-Host '';Write-Host "PASS: $pass/$($results.Count)";Write-Host "FAIL: $fail/$($results.Count)";Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})";Write-Host '';if($fail -gt 0){exit 1}
