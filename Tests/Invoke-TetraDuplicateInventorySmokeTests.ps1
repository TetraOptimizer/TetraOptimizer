#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'Engine\DuplicateInventoryEngine.ps1')
$pass=0;$fail=0
function Invoke-Test([string]$Name,[scriptblock]$Body){try{& $Body;Write-Host "[PASS] $Name" -ForegroundColor Green;$script:pass++}catch{Write-Host "[FAIL] $Name" -ForegroundColor Red;Write-Host "       -> $($_.Exception.Message)" -ForegroundColor Yellow;$script:fail++}}
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Assert-Equal($Expected,$Actual,[string]$Message){if($Expected -ne $Actual){throw "$Message Expected '$Expected', got '$Actual'."}}
function New-SyntheticFile([string]$Name,[long]$Length,[string]$Path){[pscustomobject]@{Name=$Name;Length=$Length;FullName=$Path}}
$hashes=@{'C:\A\one.bin'='AAA';'C:\B\two.bin'='AAA';'C:\C\three.bin'='BBB';'C:\D\four.bin'='CCC'}
$resolver={param($candidate) $hashes[$candidate.FullPath]}
Write-Host "`n===== Tetra Optimizer - Duplicate Inventory Smoke Tests =====" -ForegroundColor Cyan
Invoke-Test 'Same size and same hash produce one duplicate group' {$files=@((New-SyntheticFile 'one.bin' 100 'C:\A\one.bin'),(New-SyntheticFile 'two.bin' 100 'C:\B\two.bin'));$r=@(Get-TetraDuplicateInventory -FileData $files -HashResolver $resolver);Assert-Equal 1 $r.Count 'Expected one group.';Assert-Equal 2 $r[0].FileCount 'Wrong file count.'}
Invoke-Test 'Same size but different hash does not produce duplicate group' {$files=@((New-SyntheticFile 'three.bin' 100 'C:\C\three.bin'),(New-SyntheticFile 'four.bin' 100 'C:\D\four.bin'));$r=@(Get-TetraDuplicateInventory -FileData $files -HashResolver $resolver);Assert-Equal 0 $r.Count 'Hash mismatch must not be duplicate.'}
Invoke-Test 'Different sizes are never hashed together as duplicates' {$files=@((New-SyntheticFile 'one.bin' 100 'C:\A\one.bin'),(New-SyntheticFile 'two.bin' 200 'C:\B\two.bin'));$r=@(Get-TetraDuplicateInventory -FileData $files -HashResolver $resolver);Assert-Equal 0 $r.Count 'Different sizes must not form a group.'}
Invoke-Test 'Potential reclaim bytes equals all but one copy' {$files=@((New-SyntheticFile 'one.bin' 100 'C:\A\one.bin'),(New-SyntheticFile 'two.bin' 100 'C:\B\two.bin'));$r=@(Get-TetraDuplicateInventory -FileData $files -HashResolver $resolver)[0];Assert-Equal 100 $r.PotentialReclaimBytes 'Wrong reclaim estimate.'}
Invoke-Test 'Duplicate result preserves exact paths' {$files=@((New-SyntheticFile 'one.bin' 100 'C:\A\one.bin'),(New-SyntheticFile 'two.bin' 100 'C:\B\two.bin'));$r=@(Get-TetraDuplicateInventory -FileData $files -HashResolver $resolver)[0];Assert-True ($r.Paths -contains 'C:\A\one.bin') 'First path missing.';Assert-True ($r.Paths -contains 'C:\B\two.bin') 'Second path missing.'}
Invoke-Test 'No automatic keep decision is made' {$files=@((New-SyntheticFile 'one.bin' 100 'C:\A\one.bin'),(New-SyntheticFile 'two.bin' 100 'C:\B\two.bin'));$r=@(Get-TetraDuplicateInventory -FileData $files -HashResolver $resolver)[0];Assert-True (-not $r.KeepDecisionMade) 'Keep decision must remain false.';Assert-Equal '' $r.KeepPath 'KeepPath must remain empty.';Assert-Equal 0 @($r.DeletePaths).Count 'DeletePaths must remain empty.'}
Invoke-Test 'Deletion is never approved automatically' {$files=@((New-SyntheticFile 'one.bin' 100 'C:\A\one.bin'),(New-SyntheticFile 'two.bin' 100 'C:\B\two.bin'));$r=@(Get-TetraDuplicateInventory -FileData $files -HashResolver $resolver)[0];Assert-True (-not $r.DeletionApproved) 'DeletionApproved must remain false.'}
Invoke-Test 'Minimum size filter excludes small candidates' {$files=@((New-SyntheticFile 'one.bin' 100 'C:\A\one.bin'),(New-SyntheticFile 'two.bin' 100 'C:\B\two.bin'));$r=@(Get-TetraDuplicateInventory -FileData $files -HashResolver $resolver -MinimumSizeBytes 101);Assert-Equal 0 $r.Count 'Small files should be filtered.'}
Invoke-Test 'Empty supplied snapshot is valid' {$r=@(Get-TetraDuplicateInventory -FileData @() -HashResolver $resolver);Assert-Equal 0 $r.Count 'Expected zero groups.'}
Invoke-Test 'Live duplicate discovery requires explicit roots' {$threw=$false;try{Get-TetraDuplicateInventory|Out-Null}catch{$threw=$true};Assert-True $threw 'Expected explicit-root failure.'}
Invoke-Test 'Hash resolver only runs for size-collision candidates' {$script:calls=0;$counting={param($candidate)$script:calls++;'SAME'};$files=@((New-SyntheticFile 'a.bin' 10 'C:\a.bin'),(New-SyntheticFile 'b.bin' 20 'C:\b.bin'),(New-SyntheticFile 'c.bin' 20 'C:\c.bin'));Get-TetraDuplicateInventory -FileData $files -HashResolver $counting|Out-Null;Assert-Equal 2 $script:calls 'Only the two size-matched files should be hashed.'}
Invoke-Test 'Duplicate inventory source contains no mutation commands' {$source=Get-Content -LiteralPath (Join-Path $repoRoot 'Engine\DuplicateInventoryEngine.ps1') -Raw;$patterns=@('(?im)^\s*Remove-Item\b','(?im)^\s*Move-Item\b','(?im)^\s*Rename-Item\b','(?im)^\s*Clear-Content\b','(?im)^\s*Set-Content\b','(?im)^\s*Remove-ItemProperty\b');foreach($pattern in $patterns){if($source -match $pattern){throw "Found forbidden mutation command matching '$pattern'."}}}
Write-Host "`nPASS: $pass/12" -ForegroundColor $(if($pass -eq 12){'Green'}else{'Yellow'})
Write-Host "FAIL: $fail/12" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
if($fail -gt 0){exit 1}
