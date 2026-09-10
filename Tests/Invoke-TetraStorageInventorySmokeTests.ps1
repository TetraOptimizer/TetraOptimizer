#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'Bootstrap\Initialize-Tetra.ps1')
. (Join-Path $projectRoot 'Engine\StorageInventoryEngine.ps1')
$results=[System.Collections.Generic.List[PSCustomObject]]::new()
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Invoke-Test{param([string]$Name,[scriptblock]$Body)try{&$Body|Out-Null;$results.Add([PSCustomObject]@{TestName=$Name;Passed=$true;ErrorMessage=''})}catch{$results.Add([PSCustomObject]@{TestName=$Name;Passed=$false;ErrorMessage=$_.Exception.Message})}}
function New-SyntheticVolume{param([string]$DeviceID='C:',[long]$Size=1000,[long]$FreeSpace=250,[int]$DriveType=3);[PSCustomObject]@{DeviceID=$DeviceID;VolumeName='System';FileSystem='NTFS';Size=$Size;FreeSpace=$FreeSpace;DriveType=$DriveType}}
function New-SyntheticFile{param([string]$Name='example.bin',[long]$Length=2048,[string]$FullName='C:\Data\example.bin',[datetime]$LastWriteTimeUtc=[datetime]'2026-08-01');[PSCustomObject]@{Name=$Name;Extension=[System.IO.Path]::GetExtension($Name);FullName=$FullName;DirectoryName=[System.IO.Path]::GetDirectoryName($FullName);Length=$Length;CreationTimeUtc=[datetime]'2026-07-01';LastWriteTimeUtc=$LastWriteTimeUtc;LastAccessTimeUtc=[datetime]'2026-08-02'}}
Invoke-Test 'Synthetic fixed volume becomes correctly shaped inventory record' {$r=@(Get-TetraStorageVolumeInventory -VolumeData @((New-SyntheticVolume)))[0];Assert-True($r.RecordType-eq'StorageVolume')'RecordType mismatch.';Assert-True($r.EvidenceSource-eq'Win32_LogicalDisk')'Evidence source mismatch.'}
Invoke-Test 'Volume used bytes and free percentage are calculated correctly' {$r=@(Get-TetraStorageVolumeInventory -VolumeData @((New-SyntheticVolume -Size 1000 -FreeSpace 250)))[0];Assert-True($r.UsedBytes-eq750)'Used bytes mismatch.';Assert-True($r.FreePercent-eq25)'Free percent mismatch.'}
Invoke-Test 'Non-fixed volumes are excluded' {$r=@(Get-TetraStorageVolumeInventory -VolumeData @((New-SyntheticVolume -DriveType 2)));Assert-True($r.Count-eq0)'Non-fixed volume should be excluded.'}
Invoke-Test 'Synthetic file metadata is preserved without content access' {$r=@(Get-TetraFileInventory -FileData @((New-SyntheticFile)))[0];Assert-True($r.RecordType-eq'FileMetadata')'RecordType mismatch.';Assert-True($r.SizeBytes-eq2048)'Size mismatch.';Assert-True($r.ContentRead-eq$false)'ContentRead should be false.';Assert-True($r.HashComputed-eq$false)'HashComputed should be false.'}
Invoke-Test 'Large file flag is threshold based only' {$r=@(Get-TetraFileInventory -FileData @((New-SyntheticFile -Length 5000)) -MinimumLargeFileBytes 4096)[0];Assert-True($r.IsLarge-eq$true)'Large flag mismatch.'}
Invoke-Test 'Minimum file size filter excludes smaller metadata records' {$r=@(Get-TetraFileInventory -FileData @((New-SyntheticFile -Length 100)) -MinimumSizeBytes 101);Assert-True($r.Count-eq0)'Small file should be filtered.'}
Invoke-Test 'File timestamps are normalized' {$r=@(Get-TetraFileInventory -FileData @((New-SyntheticFile)))[0];Assert-True($r.LastWriteUtc-match'^2026-08-01')"Unexpected timestamp $($r.LastWriteUtc)."}
Invoke-Test 'Empty supplied file snapshot is valid' {$r=@(Get-TetraFileInventory -FileData @());Assert-True($r.Count-eq0)'Expected empty file snapshot.'}
Invoke-Test 'Live file discovery requires explicit roots' {try{Get-TetraFileInventory|Out-Null;throw 'Expected explicit-root failure.'}catch{Assert-True($_.Exception.Message-like'*RootPaths must be explicitly supplied*')'Unexpected error.'}}
Invoke-Test 'MaxFiles bounds returned file metadata' {$files=1..5|ForEach-Object{New-SyntheticFile -Name "f$_.bin" -FullName "C:\Data\f$_.bin"};$r=@(Get-TetraFileInventory -FileData $files -MaxFiles 3);Assert-True($r.Count-eq3)"Expected 3, got $($r.Count)."}
Invoke-Test 'Storage inventory source contains no mutation commands' {$s=Get-Content -LiteralPath(Join-Path $projectRoot 'Engine\StorageInventoryEngine.ps1')-Raw -Encoding UTF8;$f=@('Remove-Item','Move-Item','Rename-Item','Set-Content','Clear-Content','Compress-Archive','Format-Volume','Remove-Partition');foreach($c in $f){Assert-True($s-notmatch[regex]::Escape($c))"Mutation reference '$c' found."}}
Invoke-Test 'Live Windows fixed-volume inventory returns readable records' {$r=@(Get-TetraStorageVolumeInventory);foreach($x in $r){Assert-True($x.RecordType-eq'StorageVolume')'Live shape mismatch.';Assert-True($x.DriveType-eq3)'Live non-fixed drive returned.'};Assert-True($r.Count-ge1)'Expected at least one fixed volume.'}
$pass=@($results|Where-Object{$_.Passed}).Count;$fail=@($results|Where-Object{-not$_.Passed}).Count
Write-Host '';Write-Host '===== Tetra Optimizer - Storage Inventory Smoke Tests =====' -ForegroundColor Cyan
foreach($r in $results){$s=if($r.Passed){'PASS'}else{'FAIL'};$c=if($r.Passed){'Green'}else{'Red'};Write-Host "[$s] $($r.TestName)" -ForegroundColor $c;if(-not$r.Passed){Write-Host "        -> $($r.ErrorMessage)" -ForegroundColor DarkYellow}}
Write-Host '';Write-Host "PASS: $pass/$($results.Count)";Write-Host "FAIL: $fail/$($results.Count)";Write-Host "Overall: $(if($fail-eq0){'PASS'}else{'FAIL'})";Write-Host '';if($fail-gt0){exit 1}
