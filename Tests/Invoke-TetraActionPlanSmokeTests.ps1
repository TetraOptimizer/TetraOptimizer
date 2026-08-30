#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Engine\ActionPlanEngine.ps1')

$results=[System.Collections.Generic.List[PSCustomObject]]::new()
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Invoke-Test{param([string]$Name,[scriptblock]$Body)try{& $Body|Out-Null;$results.Add([PSCustomObject]@{TestName=$Name;Passed=$true;ErrorMessage=''})}catch{$results.Add([PSCustomObject]@{TestName=$Name;Passed=$false;ErrorMessage=$_.Exception.Message})}}
function New-TestRecommendationSnapshot{
 param([object[]]$Recommendations=@())
 return [PSCustomObject]@{RecordType='RecommendationSnapshot';RecommendationRunId='rec-run';SourceAnalysisId='analysis-1';SourceScanId='scan-1';Recommendations=@($Recommendations)}
}
function New-TestRecommendation{
 param([string]$Id,[string]$Kind,[string]$Path='',[string]$Subject='Test item',[object]$Evidence=$null,[long]$Reclaim=0)
 return [PSCustomObject]@{RecommendationId=$Id;Recommendation=$Kind;Path=$Path;Subject=$Subject;KnowledgeBaseId='';Confidence='High';PotentialReclaimBytes=$Reclaim;Evidence=$Evidence}
}

Invoke-Test 'Action plan snapshot is correctly shaped and never executes' {
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot)
 Assert-True ($p.RecordType -eq 'ActionPlanSnapshot') 'RecordType mismatch.'
 Assert-True ($p.IsReadOnly -eq $true) 'Action plan must remain read-only.'
 Assert-True ($p.ExecutionPerformed -eq $false) 'Action plan must never execute.'
 Assert-True ($p.Counts.Items -eq 0) 'Empty input should produce zero items.'
}

Invoke-Test 'Action plan state contract is complete' {
 $s=@(Get-TetraActionPlanStates)
 foreach($x in @('NoAction','Blocked','NeedsReview','NeedsSelection','NeedsActionResolution','AwaitingApproval','ReadyForExecution')){Assert-True ($s -contains $x) "Missing state '$x'."}
}

Invoke-Test 'Keep recommendation becomes NoAction' {
 $r=New-TestRecommendation 'keep-1' 'Keep'
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r))
 Assert-True ($p.Items[0].PlanState -eq 'NoAction') 'Keep must become NoAction.'
 Assert-True ($p.Items[0].ExecutionReady -eq $false) 'Keep must not be execution-ready.'
}

Invoke-Test 'DoNotTouch remains blocked even if approval id is supplied' {
 $r=New-TestRecommendation 'block-1' 'DoNotTouch'
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r)) -ApprovedRecommendationIds @('block-1')
 Assert-True ($p.Items[0].PlanState -eq 'Blocked') 'DoNotTouch must be blocked.'
 Assert-True ($p.Items[0].UserApproved -eq $false) 'Blocked item must ignore approval input.'
 Assert-True ($p.Items[0].ExecutionReady -eq $false) 'Blocked item must never be ready.'
}

Invoke-Test 'Review cannot become executable from approval alone' {
 $r=New-TestRecommendation 'review-1' 'Review'
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r)) -ApprovedRecommendationIds @('review-1')
 Assert-True ($p.Items[0].PlanState -eq 'NeedsReview') 'Review must remain NeedsReview.'
 Assert-True ($p.Items[0].UserApproved -eq $false) 'Review must not accept execution approval.'
}

Invoke-Test 'Profile recommendation requires exact action resolution' {
 $r=New-TestRecommendation 'profile-1' 'ProfileRecommendation'
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r)) -ApprovedRecommendationIds @('profile-1')
 Assert-True ($p.Items[0].PlanState -eq 'NeedsActionResolution') 'Profile recommendation must require action resolution.'
 Assert-True ($p.Items[0].ExecutionReady -eq $false) 'Unresolved profile action must not be ready.'
}

Invoke-Test 'Cleanup candidate with exact path awaits approval' {
 $r=New-TestRecommendation 'clean-1' 'CleanupCandidate' 'C:\Temp\cache.tmp'
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r))
 $i=$p.Items[0]
 Assert-True ($i.PlanState -eq 'AwaitingApproval') 'Cleanup target should await approval.'
 Assert-True ($i.ProposedAction -eq 'CleanupFile') 'Cleanup action mismatch.'
 Assert-True ($i.BackupRequired -eq $true) 'Cleanup should require backup.'
 Assert-True ($i.RollbackStrategy -eq 'BackupBeforeChange') 'Cleanup rollback strategy mismatch.'
}

Invoke-Test 'Explicitly approved cleanup candidate becomes ready but not executed' {
 $r=New-TestRecommendation 'clean-2' 'CleanupCandidate' 'C:\Temp\cache.tmp'
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r)) -ApprovedRecommendationIds @('clean-2')
 $i=$p.Items[0]
 Assert-True ($i.PlanState -eq 'ReadyForExecution') 'Approved exact cleanup candidate should become ready.'
 Assert-True ($i.UserApproved -eq $true) 'Approval should be preserved.'
 Assert-True ($i.ExecutionRequested -eq $false -and $i.Executed -eq $false) 'Planning must not request or perform execution.'
}

Invoke-Test 'Cleanup candidate without exact path cannot become ready' {
 $r=New-TestRecommendation 'clean-3' 'CleanupCandidate' ''
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r)) -ApprovedRecommendationIds @('clean-3')
 Assert-True ($p.Items[0].PlanState -eq 'NeedsActionResolution') 'Missing exact path must block readiness.'
 Assert-True ($p.Items[0].UserApproved -eq $false) 'Invalid unresolved cleanup must not retain approval.'
}

Invoke-Test 'Duplicate review requires explicit keep and delete selection' {
 $group=[PSCustomObject]@{Paths=@('C:\A.bin','D:\B.bin');PotentialReclaimBytes=100}
 $finding=[PSCustomObject]@{Evidence=$group}
 $r=New-TestRecommendation 'dup-1' 'DuplicateReview' 'C:\A.bin' 'Duplicate group' $finding 100
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r))
 Assert-True ($p.Items[0].PlanState -eq 'NeedsSelection') 'Duplicate without selection must need selection.'
}

Invoke-Test 'Valid duplicate selection awaits approval' {
 $group=[PSCustomObject]@{Paths=@('C:\A.bin','D:\B.bin');PotentialReclaimBytes=100}
 $finding=[PSCustomObject]@{Evidence=$group}
 $r=New-TestRecommendation 'dup-2' 'DuplicateReview' 'C:\A.bin' 'Duplicate group' $finding 100
 $sel=@{'dup-2'=[PSCustomObject]@{KeepPath='C:\A.bin';DeletePaths=@('D:\B.bin')}}
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r)) -DuplicateSelections $sel
 $i=$p.Items[0]
 Assert-True ($i.PlanState -eq 'AwaitingApproval') 'Resolved duplicate paths should await approval.'
 Assert-True ($i.KeepPath -eq 'C:\A.bin') 'KeepPath mismatch.'
 Assert-True (@($i.DeletePaths).Count -eq 1 -and $i.DeletePaths[0] -eq 'D:\B.bin') 'DeletePaths mismatch.'
}

Invoke-Test 'Approved valid duplicate selection becomes ready without execution' {
 $group=[PSCustomObject]@{Paths=@('C:\A.bin','D:\B.bin');PotentialReclaimBytes=100}
 $finding=[PSCustomObject]@{Evidence=$group}
 $r=New-TestRecommendation 'dup-3' 'DuplicateReview' 'C:\A.bin' 'Duplicate group' $finding 100
 $sel=@{'dup-3'=[PSCustomObject]@{KeepPath='C:\A.bin';DeletePaths=@('D:\B.bin')}}
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r)) -DuplicateSelections $sel -ApprovedRecommendationIds @('dup-3')
 Assert-True ($p.Items[0].PlanState -eq 'ReadyForExecution') 'Approved resolved duplicate should be ready.'
 Assert-True ($p.Items[0].Executed -eq $false) 'Action plan must not execute duplicate removal.'
}

Invoke-Test 'Duplicate selection rejects path outside evidence' {
 $group=[PSCustomObject]@{Paths=@('C:\A.bin','D:\B.bin')};$finding=[PSCustomObject]@{Evidence=$group};$r=New-TestRecommendation 'dup-4' 'DuplicateReview' 'C:\A.bin' 'Duplicate group' $finding
 $sel=@{'dup-4'=[PSCustomObject]@{KeepPath='C:\A.bin';DeletePaths=@('E:\Other.bin')}}
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r)) -DuplicateSelections $sel -ApprovedRecommendationIds @('dup-4')
 Assert-True ($p.Items[0].PlanState -eq 'NeedsSelection') 'Foreign duplicate path must be rejected.'
 Assert-True ($p.Items[0].UserApproved -eq $false) 'Invalid selection must clear approval.'
}

Invoke-Test 'Duplicate selection never allows KeepPath in DeletePaths' {
 $group=[PSCustomObject]@{Paths=@('C:\A.bin','D:\B.bin')};$finding=[PSCustomObject]@{Evidence=$group};$r=New-TestRecommendation 'dup-5' 'DuplicateReview' 'C:\A.bin' 'Duplicate group' $finding
 $sel=@{'dup-5'=[PSCustomObject]@{KeepPath='C:\A.bin';DeletePaths=@('C:\A.bin')}}
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($r)) -DuplicateSelections $sel -ApprovedRecommendationIds @('dup-5')
 Assert-True ($p.Items[0].PlanState -eq 'NeedsSelection') 'KeepPath in DeletePaths must be rejected.'
}

Invoke-Test 'Counts agree with action plan items' {
 $a=New-TestRecommendation 'a' 'Keep';$b=New-TestRecommendation 'b' 'DoNotTouch';$c=New-TestRecommendation 'c' 'CleanupCandidate' 'C:\Temp\c.tmp'
 $p=Invoke-TetraActionPlan -RecommendationSnapshot (New-TestRecommendationSnapshot @($a,$b,$c))
 Assert-True ($p.Counts.Items -eq 3) 'Item count mismatch.'
 Assert-True ($p.Counts.NoAction -eq 1 -and $p.Counts.Blocked -eq 1 -and $p.Counts.AwaitingApproval -eq 1) 'State counts mismatch.'
}

Invoke-Test 'Invalid input is rejected clearly' {
 $bad=[PSCustomObject]@{RecordType='SystemAnalysisSnapshot'}
 $threw=$false;try{Invoke-TetraActionPlan -RecommendationSnapshot $bad|Out-Null}catch{$threw=$true}
 Assert-True $threw 'Invalid input should throw.'
}

Invoke-Test 'Action plan source contains no mutation command invocations' {
 $path=Join-Path $projectRoot 'Engine\ActionPlanEngine.ps1';$tokens=$null;$parseErrors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
 Assert-True (@($parseErrors).Count -eq 0) 'ActionPlanEngine has parse errors.'
 $commands=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
 foreach($name in @('Remove-Item','Move-Item','Rename-Item','Set-Content','Clear-Content','Disable-Service','Stop-Service','Set-Service','Unregister-ScheduledTask','Disable-ScheduledTask','Remove-ItemProperty','Set-ItemProperty','pnputil.exe')){Assert-True ($commands -notcontains $name) "Mutation command '$name' is invoked."}
}

$pass=@($results|Where-Object{$_.Passed}).Count;$fail=@($results|Where-Object{-not $_.Passed}).Count
Write-Host '';Write-Host '===== Tetra Optimizer - Approval / Action Plan Smoke Tests =====' -ForegroundColor Cyan
foreach($r in $results){$s=if($r.Passed){'PASS'}else{'FAIL'};$c=if($r.Passed){'Green'}else{'Red'};Write-Host "[$s] $($r.TestName)" -ForegroundColor $c;if(-not $r.Passed){Write-Host "        -> $($r.ErrorMessage)" -ForegroundColor DarkYellow}}
Write-Host '';Write-Host "PASS: $pass/$($results.Count)";Write-Host "FAIL: $fail/$($results.Count)";Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})";Write-Host '';if($fail -gt 0){exit 1}
