#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\SystemScanEngine.ps1')

$results=[System.Collections.Generic.List[PSCustomObject]]::new()
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Invoke-Test{param([string]$Name,[scriptblock]$Body)try{& $Body|Out-Null;$results.Add([PSCustomObject]@{TestName=$Name;Passed=$true;ErrorMessage=''})}catch{$results.Add([PSCustomObject]@{TestName=$Name;Passed=$false;ErrorMessage=$_.Exception.Message})}}
function New-EmptyOverrides{
    return @{
        Processes={@()};Services={@()};Startup={@()};Applications={@()};ScheduledTasks={@()};Drivers={@()};StorageVolumes={@()}
    }
}

Invoke-Test 'Unified scan returns a correctly shaped read-only snapshot' {
    $s=Invoke-TetraSystemScan -CollectorOverrides (New-EmptyOverrides)
    Assert-True ($s.RecordType -eq 'SystemScanSnapshot') 'RecordType mismatch.'
    Assert-True ($s.IsReadOnly -eq $true) 'Scan must declare read-only behavior.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($s.ScanId)) 'ScanId missing.'
    Assert-True ($s.Status -eq 'Complete') 'Empty deterministic scan should complete.'
}

Invoke-Test 'Core inventory sections are consolidated into one snapshot' {
    $o=New-EmptyOverrides
    $o.Processes={ [PSCustomObject]@{RecordType='Process';Name='x.exe'} }
    $o.Services={ [PSCustomObject]@{RecordType='Service';Name='Example'} }
    $o.Applications={ [PSCustomObject]@{RecordType='InstalledApplication';DisplayName='Example App'} }
    $o.ScheduledTasks={ [PSCustomObject]@{RecordType='ScheduledTask';TaskName='Example Task'} }
    $o.Drivers={ [PSCustomObject]@{RecordType='Driver';DeviceName='Example Driver';DeviceClass='Unknown'} }
    $o.StorageVolumes={ [PSCustomObject]@{RecordType='StorageVolume';DeviceId='C:'} }
    $s=Invoke-TetraSystemScan -CollectorOverrides $o
    Assert-True ($s.Counts.Processes -eq 1) 'Process count mismatch.'
    Assert-True ($s.Counts.Services -eq 1) 'Service count mismatch.'
    Assert-True ($s.Counts.Applications -eq 1) 'Application count mismatch.'
    Assert-True ($s.Counts.ScheduledTasks -eq 1) 'Task count mismatch.'
    Assert-True ($s.Counts.Drivers -eq 1) 'Driver count mismatch.'
    Assert-True ($s.Counts.StorageVolumes -eq 1) 'Volume count mismatch.'
}

Invoke-Test 'One collector failure produces an honest Partial snapshot' {
    $o=New-EmptyOverrides;$o.Services={throw 'synthetic service failure'}
    $s=Invoke-TetraSystemScan -CollectorOverrides $o
    Assert-True ($s.Status -eq 'Partial') 'Expected Partial status.'
    Assert-True ($s.Counts.Errors -ge 1) 'Expected visible error evidence.'
    Assert-True (@($s.Errors|Where-Object{$_.Section -eq 'Services'}).Count -eq 1) 'Service error not preserved.'
}

Invoke-Test 'Collector failure does not discard successful sections' {
    $o=New-EmptyOverrides
    $o.Processes={ [PSCustomObject]@{RecordType='Process';Name='survivor.exe'} }
    $o.Services={throw 'synthetic failure'}
    $s=Invoke-TetraSystemScan -CollectorOverrides $o
    Assert-True ($s.Processes.Count -eq 1) 'Successful process section was lost.'
    Assert-True ($s.Processes[0].Name -eq 'survivor.exe') 'Successful evidence changed.'
}

Invoke-Test 'File-heavy work is disabled by default' {
    $o=New-EmptyOverrides
    $o.FileMetadata={throw 'File metadata collector should not run.'}
    $s=Invoke-TetraSystemScan -CollectorOverrides $o
    Assert-True ($s.FileWorkRequested -eq $false) 'File work should be off by default.'
    Assert-True ($s.Files.Count -eq 0) 'Files should be empty by default.'
}

Invoke-Test 'File-heavy work requires explicit roots' {
    $threw=$false
    try{Invoke-TetraSystemScan -IncludeFileInventory -CollectorOverrides (New-EmptyOverrides)|Out-Null}catch{$threw=($_.Exception.Message -like '*Explicit RootPaths*')}
    Assert-True $threw 'Expected explicit RootPaths requirement.'
}

Invoke-Test 'File metadata is collected once and reused for cleanup' {
    $o=New-EmptyOverrides
    $script:fileCalls=0
    $o.FileMetadata={
        $script:fileCalls++
        [PSCustomObject]@{Name='cache.tmp';Extension='.tmp';FullPath='C:\Synthetic\Temp\cache.tmp';SizeBytes=2048;LastWriteUtc='2026-08-01T00:00:00.0000000Z'}
    }
    $s=Invoke-TetraSystemScan -RootPaths @('C:\Synthetic') -IncludeFileInventory -IncludeCleanup -CollectorOverrides $o
    Assert-True ($script:fileCalls -eq 1) "Expected one file metadata collection, got $script:fileCalls."
    Assert-True ($s.Files.Count -eq 1) 'Expected one file record.'
    Assert-True ($s.Cleanup.Count -eq 1) 'Expected cleanup to reuse metadata.'
    Assert-True ($s.Cleanup[0].IsCleanupCandidate -eq $true) 'Expected temp-path cleanup candidate.'
}

Invoke-Test 'Duplicate reclaim totals are summarized without delete decisions' {
    $o=New-EmptyOverrides
    $o.FileMetadata={ [PSCustomObject]@{Name='a.bin';FullPath='C:\Synthetic\a.bin';SizeBytes=100;LastWriteUtc=''} }
    $o.Duplicates={ [PSCustomObject]@{RecordType='DuplicateGroup';PotentialReclaimBytes=100;KeepDecisionMade=$false;DeletionApproved=$false;Paths=@('A','B')} }
    $s=Invoke-TetraSystemScan -RootPaths @('C:\Synthetic') -IncludeDuplicates -CollectorOverrides $o
    Assert-True ($s.Counts.DuplicateGroups -eq 1) 'Expected duplicate group.'
    Assert-True ($s.PotentialDuplicateReclaimBytes -eq 100) 'Reclaim total mismatch.'
    Assert-True ($s.Duplicates[0].DeletionApproved -eq $false) 'Deletion must not be approved.'
}

Invoke-Test 'Known service evidence is prepared for Analyzer handoff' {
    $o=New-EmptyOverrides
    $o.Services={ [PSCustomObject]@{RecordType='Service';Category='Services';Name='WSearch';DisplayName='Windows Search';State='Running';Status='OK';StartMode='Auto';ProcessId=123;BinaryPath='';PathAvailable=$false;ServiceType='Own Process';Description='';EvidenceSource='Win32_Service';EvidenceKey='WSearch';ObservedUtc='2026-08-30T00:00:00Z'} }
    $s=Invoke-TetraSystemScan -CollectorOverrides $o
    $matches=@($s.AnalyzerState|Where-Object{$_.KnowledgeBaseId -eq 'svc-wsearch'})
    Assert-True ($matches.Count -eq 1) 'Expected WSearch Analyzer observation.'
    Assert-True ($matches[0].IsInstalled -eq $true) 'Observation should report installed.'
}

Invoke-Test 'Empty or unknown runtime evidence does not manufacture Analyzer negatives' {
    $s=Invoke-TetraSystemScan -CollectorOverrides (New-EmptyOverrides)
    Assert-True (@($s.AnalyzerState).Count -eq 0) 'Empty snapshot must not manufacture negative observations.'
}

Invoke-Test 'Snapshot counts agree with returned section arrays' {
    $o=New-EmptyOverrides;$o.Startup={@([PSCustomObject]@{RecordType='Startup'},[PSCustomObject]@{RecordType='Startup'})}
    $s=Invoke-TetraSystemScan -CollectorOverrides $o
    Assert-True ($s.Counts.Startup -eq $s.Startup.Count) 'Startup count mismatch.'
    Assert-True ($s.Counts.Errors -eq $s.Errors.Count) 'Error count mismatch.'
}

Invoke-Test 'Invalid collector override is reported rather than crashing whole scan' {
    $o=New-EmptyOverrides;$o.Drivers='not-a-scriptblock'
    $s=Invoke-TetraSystemScan -CollectorOverrides $o
    Assert-True ($s.Status -eq 'Partial') 'Invalid override should make scan Partial.'
    Assert-True (@($s.Errors|Where-Object{$_.Section -eq 'Drivers'}).Count -eq 1) 'Driver override error missing.'
}

Invoke-Test 'System scan source contains no mutation command invocations' {
    $path=Join-Path $projectRoot 'Engine\SystemScanEngine.ps1'
    $tokens=$null;$parseErrors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) 'SystemScanEngine has parse errors.'
    $commands=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
    $forbidden=@('Remove-Item','Move-Item','Rename-Item','Set-Content','Clear-Content','Disable-Service','Stop-Service','Set-Service','Unregister-ScheduledTask','Disable-ScheduledTask','pnputil.exe')
    foreach($name in $forbidden){Assert-True ($commands -notcontains $name) "Mutation command '$name' is invoked."}
}

Invoke-Test 'Live Windows unified scan returns core inventory without file recursion' {
    $s=Invoke-TetraSystemScan
    Assert-True ($s.RecordType -eq 'SystemScanSnapshot') 'Live snapshot shape mismatch.'
    Assert-True ($s.IsReadOnly -eq $true) 'Live scan must be read-only.'
    Assert-True ($s.FileWorkRequested -eq $false) 'Live default scan must not recurse files.'
    Assert-True ($s.Counts.Processes -ge 1) 'Expected at least one live process.'
    Assert-True ($s.Counts.StorageVolumes -ge 1) 'Expected at least one fixed volume.'
}

$pass=@($results|Where-Object{$_.Passed}).Count;$fail=@($results|Where-Object{-not $_.Passed}).Count
Write-Host '';Write-Host '===== Tetra Optimizer - Unified System Scan Smoke Tests =====' -ForegroundColor Cyan
foreach($r in $results){$s=if($r.Passed){'PASS'}else{'FAIL'};$c=if($r.Passed){'Green'}else{'Red'};Write-Host "[$s] $($r.TestName)" -ForegroundColor $c;if(-not $r.Passed){Write-Host "        -> $($r.ErrorMessage)" -ForegroundColor DarkYellow}}
Write-Host '';Write-Host "PASS: $pass/$($results.Count)";Write-Host "FAIL: $fail/$($results.Count)";Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})";Write-Host '';if($fail -gt 0){exit 1}
