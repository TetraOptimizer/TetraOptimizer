#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\SystemScanEngine.ps1')
. (Join-Path $projectRoot 'Engine\SystemAnalysisEngine.ps1')
. (Join-Path $projectRoot 'Engine\RecommendationEngine.ps1')

$results=[System.Collections.Generic.List[PSCustomObject]]::new()
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Invoke-Test{param([string]$Name,[scriptblock]$Body)try{& $Body|Out-Null;$results.Add([PSCustomObject]@{TestName=$Name;Passed=$true;ErrorMessage=''})}catch{$results.Add([PSCustomObject]@{TestName=$Name;Passed=$false;ErrorMessage=$_.Exception.Message})}}
function New-RecAnalysis{
 param([object[]]$Findings=@(),[object[]]$PolicyDecisions=@(),[string]$Profile='Balanced')
 return [PSCustomObject]@{RecordType='SystemAnalysisSnapshot';AnalysisId='analysis-1';SourceScanId='scan-1';Profile=$Profile;Findings=@($Findings);PolicyDecisions=@($PolicyDecisions)}
}
function New-Finding{
 param([string]$Subject='X',[string]$Classification='Unknown',[string]$Confidence='Low',[string]$Reason='Evidence is insufficient.',[string]$KnowledgeBaseId='',[string]$SourceSection='Test',[string]$Path='',[long]$PotentialReclaimBytes=0)
 return [PSCustomObject]@{Subject=$Subject;Classification=$Classification;Confidence=$Confidence;Reason=$Reason;KnowledgeBaseId=$KnowledgeBaseId;SourceSection=$SourceSection;Path=$Path;PotentialReclaimBytes=$PotentialReclaimBytes}
}

Invoke-Test 'Recommendation snapshot is correctly shaped and read-only' {
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis)
 Assert-True ($r.RecordType -eq 'RecommendationSnapshot') 'RecordType mismatch.'
 Assert-True ($r.IsReadOnly -eq $true) 'Recommendation snapshot must be read-only.'
 Assert-True ($r.Status -eq 'Complete') 'Empty recommendation run should complete.'
 Assert-True ($r.SourceAnalysisId -eq 'analysis-1') 'Source analysis id not preserved.'
}

Invoke-Test 'Recommendation state contract is complete' {
 $states=@(Get-TetraRecommendationStates)
 foreach($s in @('Keep','Review','CleanupCandidate','DuplicateReview','DoNotTouch','ProfileRecommendation')){Assert-True ($states -contains $s) "Missing recommendation '$s'."}
}

Invoke-Test 'SystemCritical becomes DoNotTouch with high confidence' {
 $f=New-Finding -Subject 'GPU' -Classification 'SystemCritical' -Confidence 'High' -KnowledgeBaseId 'driver-gpu'
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f))
 Assert-True ($r.Recommendations[0].Recommendation -eq 'DoNotTouch') 'SystemCritical must be DoNotTouch.'
 Assert-True ($r.Recommendations[0].Confidence -eq 'High') 'SystemCritical confidence must be High.'
 Assert-True ($r.Recommendations[0].RequiresUserApproval -eq $false) 'DoNotTouch must not request action approval.'
}

Invoke-Test 'CriticalProtected policy overrides weaker classification' {
 $f=New-Finding -Subject 'Protected' -Classification 'Used' -Confidence 'Medium' -KnowledgeBaseId 'x'
 $p=[PSCustomObject]@{KnowledgeBaseId='x';Decision='CriticalProtected';Reason='Protected.'}
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f) -PolicyDecisions @($p))
 Assert-True ($r.Recommendations[0].Recommendation -eq 'DoNotTouch') 'CriticalProtected policy must win.'
}

Invoke-Test 'Confirmed duplicate becomes DuplicateReview without delete choices' {
 $f=New-Finding -Subject 'C:\A.bin' -Classification 'Duplicate' -Confidence 'High' -Path 'C:\A.bin' -PotentialReclaimBytes 4096
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f))
 $x=$r.Recommendations[0]
 Assert-True ($x.Recommendation -eq 'DuplicateReview') 'Duplicate must become DuplicateReview.'
 Assert-True ($x.PotentialReclaimBytes -eq 4096) 'Reclaim bytes not preserved.'
 Assert-True ([string]::IsNullOrWhiteSpace($x.KeepPath)) 'Recommendation layer must not choose keep path.'
 Assert-True (@($x.DeletePaths).Count -eq 0) 'Recommendation layer must not choose delete paths.'
 Assert-True ($x.ActionApproved -eq $false) 'Duplicate action must not be approved automatically.'
}

Invoke-Test 'Cleanup evidence becomes CleanupCandidate but never deletion approval' {
 $f=New-Finding -Subject 'cache.tmp' -Classification 'PotentiallyUnnecessary' -Confidence 'High' -Path 'C:\Temp\cache.tmp'
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f))
 $x=$r.Recommendations[0]
 Assert-True ($x.Recommendation -eq 'CleanupCandidate') 'Cleanup finding mapping mismatch.'
 Assert-True ($x.RequiresUserApproval -eq $true) 'Cleanup candidate should require explicit approval before future action.'
 Assert-True ($x.ActionApproved -eq $false) 'Cleanup candidate must not be auto-approved.'
 Assert-True ($x.ExecutionRequested -eq $false) 'Cleanup candidate must not request execution.'
}

Invoke-Test 'Unknown remains Review and does not become removal recommendation' {
 $f=New-Finding -Subject 'Mystery App' -Classification 'Unknown' -Confidence 'Low'
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f))
 Assert-True ($r.Recommendations[0].Recommendation -eq 'Review') 'Unknown must become Review.'
 Assert-True ($r.Recommendations[0].RequiresUserApproval -eq $false) 'Review is not an execution request.'
}

Invoke-Test 'Used classification defaults to Keep without stronger policy' {
 $f=New-Finding -Subject 'Active Component' -Classification 'Used' -Confidence 'Medium'
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f))
 Assert-True ($r.Recommendations[0].Recommendation -eq 'Keep') 'Used should default to Keep.'
}

Invoke-Test 'Analyzer Recommended becomes ProfileRecommendation and requires approval' {
 $f=New-Finding -Subject 'Profile Component' -Classification 'Used' -Confidence 'Medium' -KnowledgeBaseId 'kb-a'
 $p=[PSCustomObject]@{KnowledgeBaseId='kb-a';Decision='Recommended';Reason='Recommended for selected profile.'}
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f) -PolicyDecisions @($p))
 $x=$r.Recommendations[0]
 Assert-True ($x.Recommendation -eq 'ProfileRecommendation') 'Recommended policy mapping mismatch.'
 Assert-True ($x.RequiresUserApproval -eq $true) 'Profile recommendation should require approval.'
 Assert-True ($x.ActionApproved -eq $false) 'Profile recommendation must not auto-approve.'
}

Invoke-Test 'Analyzer Optional becomes Review' {
 $f=New-Finding -Subject 'Optional Component' -Classification 'Unknown' -Confidence 'Low' -KnowledgeBaseId 'kb-b'
 $p=[PSCustomObject]@{KnowledgeBaseId='kb-b';Decision='Optional';Reason='Needs review.'}
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f) -PolicyDecisions @($p))
 Assert-True ($r.Recommendations[0].Recommendation -eq 'Review') 'Optional policy must remain Review.'
}

Invoke-Test 'Analyzer Keep becomes Keep' {
 $f=New-Finding -Subject 'Preserved Component' -Classification 'Unknown' -Confidence 'Low' -KnowledgeBaseId 'kb-c'
 $p=[PSCustomObject]@{KnowledgeBaseId='kb-c';Decision='Keep';Reason='Preserve for profile.'}
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f) -PolicyDecisions @($p))
 Assert-True ($r.Recommendations[0].Recommendation -eq 'Keep') 'Keep policy mapping mismatch.'
}

Invoke-Test 'Analyzer DoNotChange becomes DoNotTouch' {
 $f=New-Finding -Subject 'Absent Component' -Classification 'Unknown' -Confidence 'Low' -KnowledgeBaseId 'kb-d'
 $p=[PSCustomObject]@{KnowledgeBaseId='kb-d';Decision='DoNotChange';Reason='No applicable change.'}
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f) -PolicyDecisions @($p))
 Assert-True ($r.Recommendations[0].Recommendation -eq 'DoNotTouch') 'DoNotChange mapping mismatch.'
}

Invoke-Test 'Recommendation counts agree with returned records' {
 $f1=New-Finding -Subject 'A' -Classification 'Unknown'
 $f2=New-Finding -Subject 'B' -Classification 'Duplicate' -Confidence 'High' -PotentialReclaimBytes 100
 $f3=New-Finding -Subject 'C' -Classification 'PotentiallyUnnecessary' -Confidence 'Medium'
 $r=Invoke-TetraRecommendations -Analysis (New-RecAnalysis -Findings @($f1,$f2,$f3))
 Assert-True ($r.Counts.Recommendations -eq 3) 'Recommendation count mismatch.'
 Assert-True ($r.Counts.Review -eq 1) 'Review count mismatch.'
 Assert-True ($r.Counts.DuplicateReview -eq 1) 'DuplicateReview count mismatch.'
 Assert-True ($r.Counts.CleanupCandidate -eq 1) 'CleanupCandidate count mismatch.'
 Assert-True ($r.PotentialReclaimBytes -eq 100) 'Aggregate reclaim mismatch.'
}

Invoke-Test 'Invalid input is rejected clearly' {
 $bad=[PSCustomObject]@{RecordType='NotAnalysis'}
 $threw=$false
 try{Invoke-TetraRecommendations -Analysis $bad|Out-Null}catch{$threw=$true}
 Assert-True $threw 'Invalid input should throw.'
}

Invoke-Test 'Recommendation source contains no mutation command invocations' {
 $path=Join-Path $projectRoot 'Engine\RecommendationEngine.ps1';$tokens=$null;$parseErrors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
 Assert-True (@($parseErrors).Count -eq 0) 'RecommendationEngine has parse errors.'
 $commands=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
 foreach($name in @('Remove-Item','Move-Item','Rename-Item','Set-Content','Clear-Content','Disable-Service','Stop-Service','Set-Service','Unregister-ScheduledTask','Disable-ScheduledTask','pnputil.exe')){Assert-True ($commands -notcontains $name) "Mutation command '$name' is invoked."}
}

Invoke-Test 'Live scan analysis can produce recommendations read-only' {
 $scan=Invoke-TetraSystemScan
 $analysis=Invoke-TetraSystemAnalysis -Snapshot $scan -Profile Balanced
 $r=Invoke-TetraRecommendations -Analysis $analysis
 Assert-True ($r.RecordType -eq 'RecommendationSnapshot') 'Live recommendation shape mismatch.'
 Assert-True ($r.IsReadOnly -eq $true) 'Live recommendations must remain read-only.'
 Assert-True ($r.SourceAnalysisId -eq $analysis.AnalysisId) 'Source analysis id mismatch.'
 foreach($x in @($r.Recommendations)){Assert-True ($x.ActionApproved -eq $false) 'No live recommendation may be auto-approved.'}
}

$pass=@($results|Where-Object{$_.Passed}).Count;$fail=@($results|Where-Object{-not $_.Passed}).Count
Write-Host '';Write-Host '===== Tetra Optimizer - Recommendation Layer Smoke Tests =====' -ForegroundColor Cyan
foreach($r in $results){$s=if($r.Passed){'PASS'}else{'FAIL'};$c=if($r.Passed){'Green'}else{'Red'};Write-Host "[$s] $($r.TestName)" -ForegroundColor $c;if(-not $r.Passed){Write-Host "        -> $($r.ErrorMessage)" -ForegroundColor DarkYellow}}
Write-Host '';Write-Host "PASS: $pass/$($results.Count)";Write-Host "FAIL: $fail/$($results.Count)";Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})";Write-Host '';if($fail -gt 0){exit 1}
