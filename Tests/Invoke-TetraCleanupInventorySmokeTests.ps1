#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'Engine\CleanupInventoryEngine.ps1')
$pass=0;$fail=0
function Invoke-Test([string]$Name,[scriptblock]$Body){try{& $Body;Write-Host "[PASS] $Name" -ForegroundColor Green;$script:pass++}catch{Write-Host "[FAIL] $Name" -ForegroundColor Red;Write-Host "       -> $($_.Exception.Message)" -ForegroundColor Yellow;$script:fail++}}
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Assert-Equal($Expected,$Actual,[string]$Message){if($Expected -ne $Actual){throw "$Message Expected '$Expected', got '$Actual'."}}
Write-Host "`n===== Tetra Optimizer - Cleanup Inventory Smoke Tests =====" -ForegroundColor Cyan
$reference=[datetime]::SpecifyKind([datetime]'2026-08-30T00:00:00',[System.DateTimeKind]::Utc)
$temp=[pscustomobject]@{Name='sample.tmp';Extension='.tmp';FullName='C:\Users\Test\AppData\Local\Temp\sample.tmp';Length=2048;LastWriteTimeUtc=[datetime]'2026-08-01'}
$oldDoc=[pscustomobject]@{Name='archive.txt';Extension='.txt';FullName='D:\Archive\archive.txt';Length=4096;LastWriteTimeUtc=[datetime]'2026-01-01'}
$normal=[pscustomobject]@{Name='notes.txt';Extension='.txt';FullName='D:\Work\notes.txt';Length=512;LastWriteTimeUtc=[datetime]'2026-08-29'}
Invoke-Test 'Synthetic temp file becomes correctly shaped cleanup record' {$r=@(Get-TetraCleanupInventory -FileData @($temp) -ReferenceUtc $reference)[0];Assert-Equal 'CleanupCandidate' $r.RecordType 'Wrong record type.';Assert-Equal 'Cleanup' $r.Category 'Wrong category.'}
Invoke-Test 'Recognized Temp path becomes cleanup candidate' {$r=@(Get-TetraCleanupInventory -FileData @($temp) -ReferenceUtc $reference)[0];Assert-True $r.PathEvidence 'Expected path evidence.';Assert-True $r.IsCleanupCandidate 'Expected candidate.';Assert-Equal 'TemporaryOrCacheCandidate' $r.Classification 'Wrong classification.'}
Invoke-Test 'Temporary extension can produce candidate evidence' {$f=[pscustomobject]@{Name='trace.tmp';Extension='.tmp';FullName='D:\Logs\trace.tmp';Length=1;LastWriteTimeUtc=[datetime]'2026-08-29'};$r=@(Get-TetraCleanupInventory -FileData @($f) -ReferenceUtc $reference)[0];Assert-True $r.ExtensionEvidence 'Expected extension evidence.';Assert-True $r.IsCleanupCandidate 'Expected candidate.'}
Invoke-Test 'Old age alone does not become cleanup candidate' {$r=@(Get-TetraCleanupInventory -FileData @($oldDoc) -ReferenceUtc $reference)[0];Assert-Equal 'OldFileEvidence' $r.Classification 'Expected age-only classification.';Assert-True (-not $r.IsCleanupCandidate) 'Age alone must not mark cleanup candidate.';Assert-Equal 'Low' $r.Confidence 'Age-only confidence must remain low.'}
Invoke-Test 'Recent ordinary file remains Unknown' {$r=@(Get-TetraCleanupInventory -FileData @($normal) -ReferenceUtc $reference)[0];Assert-Equal 'Unknown' $r.Classification 'Expected honest Unknown.';Assert-True (-not $r.IsCleanupCandidate) 'Ordinary file must not be candidate.'}
Invoke-Test 'Cleanup records never claim safe-to-delete automatically' {$r=@(Get-TetraCleanupInventory -FileData @($temp) -ReferenceUtc $reference)[0];Assert-True (-not $r.SafeToDelete) 'SafeToDelete must remain false.';Assert-True (-not $r.DeletionApproved) 'DeletionApproved must remain false.'}
Invoke-Test 'File content and hashes are not collected' {$r=@(Get-TetraCleanupInventory -FileData @($temp) -ReferenceUtc $reference)[0];Assert-True (-not $r.ContentRead) 'ContentRead must be false.';Assert-True (-not $r.HashComputed) 'HashComputed must be false.'}
Invoke-Test 'Minimum size filter excludes smaller records' {$r=@(Get-TetraCleanupInventory -FileData @($normal,$temp) -MinimumSizeBytes 1024 -ReferenceUtc $reference);Assert-Equal 1 $r.Count 'Expected only one record after size filter.';Assert-Equal 'sample.tmp' $r[0].Name 'Wrong retained file.'}
Invoke-Test 'Empty supplied snapshot is valid and produces zero records' {$r=@(Get-TetraCleanupInventory -FileData @() -ReferenceUtc $reference);Assert-Equal 0 $r.Count 'Expected zero records.'}
Invoke-Test 'Live cleanup discovery requires explicit roots' {$threw=$false;try{Get-TetraCleanupInventory|Out-Null}catch{$threw=$true};Assert-True $threw 'Expected explicit-root requirement.'}
Invoke-Test 'MaxFiles bounds returned metadata' {$r=@(Get-TetraCleanupInventory -FileData @($temp,$oldDoc,$normal) -MaxFiles 2 -ReferenceUtc $reference);Assert-Equal 2 $r.Count 'MaxFiles was not enforced.'}
Invoke-Test 'Cleanup inventory source contains no mutation commands' {$source=Get-Content -LiteralPath (Join-Path $repoRoot 'Engine\CleanupInventoryEngine.ps1') -Raw;$forbidden=@('Remove-Item','Move-Item','Rename-Item','Clear-Content','Set-Content','Add-Content','del ','erase ','rd ','rmdir ');foreach($token in $forbidden){if($source -match [regex]::Escape($token)){throw "Found forbidden mutation token '$token'."}}}
Write-Host "`nPASS: $pass/12" -ForegroundColor $(if($pass -eq 12){'Green'}else{'Yellow'})
Write-Host "FAIL: $fail/12" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
Write-Host "Overall: $(if($fail -eq 0){'PASS'}else{'FAIL'})" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
if($fail -gt 0){exit 1}
