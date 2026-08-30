#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\SystemScanEngine.ps1')
. (Join-Path $projectRoot 'Engine\SystemAnalysisEngine.ps1')

$results=[System.Collections.Generic.List[PSCustomObject]]::new()
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Invoke-Test{param([string]$Name,[scriptblock]$Body)try{& $Body|Out-Null;$results.Add([PSCustomObject]@{TestName=$Name;Passed=$true;ErrorMessage=''})}catch{$results.Add([PSCustomObject]@{TestName=$Name;Passed=$false;ErrorMessage=$_.Exception.Message})}}
function New-AnalysisTestSnapshot{
 param([object[]]$Applications=@(),[object[]]$ScheduledTasks=@(),[object[]]$Cleanup=@(),[object[]]$Duplicates=@(),[object[]]$AnalyzerState=@(),[string]$Status='Complete')
 return [PSCustomObject]@{RecordType='SystemScanSnapshot';ScanId='synthetic-scan';Status=$Status;Applications=@($Applications);ScheduledTasks=@($ScheduledTasks);Cleanup=@($Cleanup);Duplicates=@($Duplicates);AnalyzerState=@($AnalyzerState)}
}

Invoke-Test 'Analysis returns a correctly shaped read-only snapshot' {
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot)
 Assert-True ($a.RecordType -eq 'SystemAnalysisSnapshot') 'RecordType mismatch.'
 Assert-True ($a.IsReadOnly -eq $true) 'Analysis must be read-only.'
 Assert-True ($a.Status -eq 'Complete') 'Empty analysis should complete.'
 Assert-True ($a.SourceScanId -eq 'synthetic-scan') 'Source scan id was not preserved.'
}

Invoke-Test 'Classification state contract includes honest Unknown outcome' {
 $states=@(Get-TetraClassificationStates)
 foreach($s in @('Used','RarelyUsed','Unused','Duplicate','Leftover','PotentiallyUnnecessary','SystemCritical','Unknown')){Assert-True ($states -contains $s) "Missing classification '$s'."}
}

Invoke-Test 'Confirmed duplicate group becomes Duplicate with exact reclaim evidence' {
 $d=[PSCustomObject]@{Paths=@('C:\A.bin','D:\B.bin');PotentialReclaimBytes=4096;Hash='abc';Algorithm='SHA256'}
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -Duplicates @($d))
 $f=@($a.Findings|Where-Object{$_.Classification -eq 'Duplicate'})
 Assert-True ($f.Count -eq 1) 'Expected one duplicate finding.'
 Assert-True ($f[0].PotentialReclaimBytes -eq 4096) 'Reclaim evidence mismatch.'
 Assert-True ($f[0].ActionApproved -eq $false) 'Duplicate analysis must not approve deletion.'
}

Invoke-Test 'Cleanup candidate becomes PotentiallyUnnecessary rather than Unused' {
 $c=[PSCustomObject]@{Name='cache.tmp';FullPath='C:\Temp\cache.tmp';IsCleanupCandidate=$true;Confidence='High';Reason='Recognized temp path.';EvidenceSource='FileSystemMetadata'}
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -Cleanup @($c))
 Assert-True ($a.Findings[0].Classification -eq 'PotentiallyUnnecessary') 'Cleanup candidate classification mismatch.'
 Assert-True ($a.Counts.Unused -eq 0) 'Cleanup evidence must not manufacture Unused.'
}

Invoke-Test 'Old-file evidence without cleanup candidate remains Unknown' {
 $c=[PSCustomObject]@{Name='old.log';FullPath='C:\Data\old.log';IsCleanupCandidate=$false;Confidence='Low';Reason='Age alone does not prove unused.';EvidenceSource='FileSystemMetadata'}
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -Cleanup @($c))
 Assert-True ($a.Findings[0].Classification -eq 'Unknown') 'Old-file evidence must remain Unknown.'
 Assert-True ($a.Findings[0].Confidence -eq 'Low') 'Unknown old file should stay low confidence.'
}

Invoke-Test 'Installed application remains Unknown without usage evidence' {
 $app=[PSCustomObject]@{DisplayName='Example App';InstallLocation='C:\Program Files\Example';EvidenceSource='RegistryUninstall'}
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -Applications @($app))
 Assert-True ($a.Findings[0].Classification -eq 'Unknown') 'Installed app must not be labeled unused.'
 Assert-True ($a.Counts.Unused -eq 0) 'No usage evidence exists for Unused.'
 Assert-True ($a.Counts.RarelyUsed -eq 0) 'No usage evidence exists for RarelyUsed.'
}

Invoke-Test 'Scheduled task presence does not imply unnecessary classification' {
 $task=[PSCustomObject]@{TaskName='Example';FullTaskName='\Vendor\Example';EvidenceSource='ScheduledTasks';IsWindowsOwned=$false;Enabled=$false}
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -ScheduledTasks @($task))
 Assert-True ($a.Findings[0].Classification -eq 'Unknown') 'Scheduled task should remain Unknown without stronger evidence.'
}

Invoke-Test 'Protected Knowledge Base component becomes SystemCritical' {
 $state=[PSCustomObject]@{Category='Drivers';KnowledgeBaseId='driver-gpu';IsInstalled=$true;IsActive=$true;CurrentState='Present';ObservedUtc='2026-08-30T00:00:00Z'}
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -AnalyzerState @($state)) -Profile Balanced
 $f=@($a.Findings|Where-Object{$_.KnowledgeBaseId -eq 'driver-gpu'})
 Assert-True ($f.Count -eq 1) 'Expected GPU finding.'
 Assert-True ($f[0].Classification -eq 'SystemCritical') 'Protected GPU should classify SystemCritical.'
 Assert-True (@($a.PolicyDecisions|Where-Object{$_.KnowledgeBaseId -eq 'driver-gpu' -and $_.Decision -eq 'CriticalProtected'}).Count -eq 1) 'CriticalProtected policy decision missing.'
}

Invoke-Test 'Currently active non-protected runtime evidence can only prove current Used state' {
 $state=[PSCustomObject]@{Category='Drivers';KnowledgeBaseId='driver-virtual-audio';IsInstalled=$true;IsActive=$true;CurrentState='Present';ObservedUtc='2026-08-30T00:00:00Z'}
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -AnalyzerState @($state)) -Profile Custom
 $f=@($a.Findings|Where-Object{$_.KnowledgeBaseId -eq 'driver-virtual-audio'})
 Assert-True ($f[0].Classification -eq 'Used') 'Active runtime evidence should classify Used.'
 Assert-True ($f[0].Confidence -eq 'Medium') 'Current activity is not historical high-confidence usage frequency.'
}

Invoke-Test 'Installed but inactive runtime component remains Unknown' {
 $state=[PSCustomObject]@{Category='Drivers';KnowledgeBaseId='driver-virtual-audio';IsInstalled=$true;IsActive=$false;CurrentState='Present';ObservedUtc='2026-08-30T00:00:00Z'}
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -AnalyzerState @($state)) -Profile Custom
 $f=@($a.Findings|Where-Object{$_.KnowledgeBaseId -eq 'driver-virtual-audio'})
 Assert-True ($f[0].Classification -eq 'Unknown') 'One inactive snapshot must not become Unused.'
}

Invoke-Test 'Empty Analyzer state does not manufacture policy decisions' {
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot)
 Assert-True ($a.PolicyDecisions.Count -eq 0) 'Empty evidence must not manufacture policy decisions.'
 Assert-True ($a.Counts.Findings -eq 0) 'Empty snapshot should have zero findings.'
}

Invoke-Test 'Source Partial status is preserved without inventing an analysis error' {
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -Status 'Partial')
 Assert-True ($a.SourceScanStatus -eq 'Partial') 'Source scan status must be preserved.'
 Assert-True ($a.Status -eq 'Complete') 'Analysis itself should complete when its own processing succeeds.'
}

Invoke-Test 'Finding counts agree with returned findings' {
 $app=[PSCustomObject]@{DisplayName='A'};$c=[PSCustomObject]@{Name='x.tmp';FullPath='C:\Temp\x.tmp';IsCleanupCandidate=$true;Confidence='High';Reason='Temp';EvidenceSource='FileSystemMetadata'}
 $a=Invoke-TetraSystemAnalysis -Snapshot (New-AnalysisTestSnapshot -Applications @($app) -Cleanup @($c))
 Assert-True ($a.Counts.Findings -eq $a.Findings.Count) 'Finding count mismatch.'
 Assert-True (($a.Counts.Unknown+$a.Counts.PotentiallyUnnecessary) -eq 2) 'Classification counts mismatch.'
}

Invoke-Test 'System analysis source contains no mutation command invocations' {
 $path=Join-Path $projectRoot 'Engine\SystemAnalysisEngine.ps1';$tokens=$null;$parseErrors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
 Assert-True (@($parseErrors).Count -eq 0) 'SystemAnalysisEngine has parse errors.'
 $commands=@($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
 foreach($name in @('Remove-Item','Move-Item','Rename-Item','Set-Content','Clear-Content','Disable-Service','Stop-Service','Set-Service','Unregister-ScheduledTask','Disable-ScheduledTask','pnputil.exe')){Assert-True ($commands -notcontains $name) "Mutation command '$name' is invoked."}
}

Invoke-Test 'Live unified scan can be analyzed read-only' {
 $scan=Invoke-TetraSystemScan
 $a=Invoke-TetraSystemAnalysis -Snapshot $scan -Profile Balanced
 Assert-True ($a.RecordType -eq 'SystemAnalysisSnapshot') 'Live analysis shape mismatch.'
 Assert-True ($a.IsReadOnly -eq $true) 'Live analysis must remain read-only.'
 Assert-True ($a.SourceScanId -eq $scan.ScanId) 'Live source scan identity mismatch.'
}

$pass=@($results|Where-Object{$_.Passed}).Count;$fail=@($results|Where-Object{-not $_.Passed}).Count
Write-Host '';Write-Host '===== Tetra Optimizer - System Analysis / Classification Smoke Tests =====' -ForegroundColor Cyan
foreach($r in $results){$s=if($r.Passed){'PASS'}else{'FAIL'};$c=if($r.Passed){'Green'}else{'Red'};Write-Host "[$s] $($r.TestName)" -ForegroundColor $c;if(-not $r.Passed){Write-Host "        -> $($r.ErrorMessage)" -ForegroundColor DarkYellow}}
Write-Host '';Write-Host "PASS: $pass/$($results.Count)";Write-Host "FAIL: $fail/$($results.Count)";Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})";Write-Host '';if($fail -gt 0){exit 1}
