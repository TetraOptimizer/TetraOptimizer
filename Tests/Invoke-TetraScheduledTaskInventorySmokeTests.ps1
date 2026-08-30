#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\ScheduledTaskInventoryEngine.ps1')
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
function Assert-True { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }
function Invoke-Test { param([string]$Name,[scriptblock]$Body) try{& $Body|Out-Null;$results.Add([PSCustomObject]@{TestName=$Name;Passed=$true;ErrorMessage=''})}catch{$results.Add([PSCustomObject]@{TestName=$Name;Passed=$false;ErrorMessage=$_.Exception.Message})} }
function New-SyntheticTask {
    param([string]$TaskName='Example Update',[string]$TaskPath='\Vendor\',[string]$State='Ready',[bool]$Enabled=$true,[string]$Execute='C:\Program Files\Vendor\updater.exe',[string]$Arguments='--private-token value')
    $action=[PSCustomObject]@{Execute=$Execute;Arguments=$Arguments}
    $trigger=[PSCustomObject]@{StartBoundary='2026-08-30T08:00:00'}
    return [PSCustomObject]@{TaskName=$TaskName;TaskPath=$TaskPath;State=$State;Settings=[PSCustomObject]@{Enabled=$Enabled};Actions=@($action);Triggers=@($trigger);Principal=[PSCustomObject]@{UserId='PRIVATE\User'}}
}
Invoke-Test 'Synthetic task becomes correctly shaped inventory record' { $r=@(Get-TetraScheduledTaskInventory -TaskData @((New-SyntheticTask)))[0]; Assert-True ($r.RecordType -eq 'ScheduledTask') 'RecordType mismatch.'; Assert-True ($r.TaskName -eq 'Example Update') 'TaskName mismatch.' }
Invoke-Test 'Task path and full task identity are preserved' { $r=@(Get-TetraScheduledTaskInventory -TaskData @((New-SyntheticTask -TaskName 'Agent' -TaskPath '\Vendor\')))[0]; Assert-True ($r.FullTaskName -eq '\Vendor\Agent') 'Full task identity mismatch.' }
Invoke-Test 'Action executable is reduced to executable name' { $r=@(Get-TetraScheduledTaskInventory -TaskData @((New-SyntheticTask)))[0]; Assert-True (@($r.ActionExecutables) -contains 'updater.exe') 'Executable name missing.'; Assert-True (@($r.ActionExecutables) -notcontains 'C:\Program Files\Vendor\updater.exe') 'Full action path retained.' }
Invoke-Test 'Action arguments are not retained' { $r=@(Get-TetraScheduledTaskInventory -TaskData @((New-SyntheticTask -Arguments '--secret 123')))[0]; Assert-True ($r.ActionArgumentsCaptured -eq $false) 'Arguments capture flag wrong.'; Assert-True (-not ($r.PSObject.Properties.Name -contains 'Arguments')) 'Arguments leaked.' }
Invoke-Test 'Principal identity is not retained' { $r=@(Get-TetraScheduledTaskInventory -TaskData @((New-SyntheticTask)))[0]; Assert-True ($r.PrincipalIdentityCaptured -eq $false) 'Principal flag wrong.'; Assert-True (-not ($r.PSObject.Properties.Name -contains 'Principal')) 'Principal leaked.' }
Invoke-Test 'Disabled task state is preserved' { $r=@(Get-TetraScheduledTaskInventory -TaskData @((New-SyntheticTask -Enabled $false)))[0]; Assert-True ($r.Enabled -eq $false) 'Disabled evidence lost.' }
Invoke-Test 'Microsoft Windows task path is identified as Windows-owned evidence' { $r=@(Get-TetraScheduledTaskInventory -TaskData @((New-SyntheticTask -TaskPath '\Microsoft\Windows\Defrag\')))[0]; Assert-True ($r.IsWindowsOwnedPath -eq $true) 'Windows task path not identified.' }
Invoke-Test 'Third-party task path is not marked Windows-owned' { $r=@(Get-TetraScheduledTaskInventory -TaskData @((New-SyntheticTask -TaskPath '\Vendor\')))[0]; Assert-True ($r.IsWindowsOwnedPath -eq $false) 'Third-party task incorrectly marked Windows-owned.' }
Invoke-Test 'Empty supplied snapshot is valid and produces zero records' { $r=@(Get-TetraScheduledTaskInventory -TaskData @()); Assert-True ($r.Count -eq 0) "Expected zero, got $($r.Count)." }
Invoke-Test 'Scheduled task inventory source contains no mutation commands' { $source=Get-Content -LiteralPath (Join-Path $projectRoot 'Engine\ScheduledTaskInventoryEngine.ps1') -Raw -Encoding UTF8; $forbidden=@('Disable-ScheduledTask','Enable-ScheduledTask','Unregister-ScheduledTask','Register-ScheduledTask','Start-ScheduledTask','Stop-ScheduledTask','schtasks.exe /delete','schtasks.exe /change'); foreach($c in $forbidden){Assert-True ($source -notmatch [regex]::Escape($c)) "Read-only task engine unexpectedly references '$c'."} }
Invoke-Test 'Live Windows scheduled task inventory returns readable records or valid empty snapshot' { $r=@(Get-TetraScheduledTaskInventory); foreach($x in $r){Assert-True (-not [string]::IsNullOrWhiteSpace($x.TaskName)) 'Blank live task name.';Assert-True ($x.ActionArgumentsCaptured -eq $false) 'Live arguments captured.';Assert-True ($x.PrincipalIdentityCaptured -eq $false) 'Live principal captured.'};Assert-True ($r.Count -ge 0) 'Invalid count.' }
$pass=@($results|Where-Object{$_.Passed}).Count;$fail=@($results|Where-Object{-not $_.Passed}).Count
Write-Host '';Write-Host '===== Tetra Optimizer - Scheduled Task Inventory Smoke Tests =====' -ForegroundColor Cyan
foreach($r in $results){$s=if($r.Passed){'PASS'}else{'FAIL'};$c=if($r.Passed){'Green'}else{'Red'};Write-Host "[$s] $($r.TestName)" -ForegroundColor $c;if(-not $r.Passed){Write-Host "        -> $($r.ErrorMessage)" -ForegroundColor DarkYellow}}
Write-Host '';Write-Host "PASS: $pass/$($results.Count)";Write-Host "FAIL: $fail/$($results.Count)";Write-Host "Overall: $(if($fail-eq 0){'PASS'}else{'FAIL'})";Write-Host '';if($fail-gt 0){exit 1}
