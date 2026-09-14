#Requires -Version 5.1
<#
Real ExecutionEngine + BackupEngine + Restore integration, using byte-identical
copies of the production modules in an owned temporary project. No personal
configuration or existing backup is copied. Backup/rollback providers are never
replaced; DeleteProvider is used only for deterministic fault injection.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path $PSScriptRoot -Parent
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$runName='TetraBackupIntegration_'+[guid]::NewGuid().ToString('N')
$runRoot=Join-Path $tempBase $runName
$isolatedProject=Join-Path $runRoot 'App'
$fixtureRoot=Join-Path $runRoot 'Files'
$integrationResults=[System.Collections.Generic.List[object]]::new()
function Assert-True {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Assert-OwnedPath {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($runRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path is outside this integration test run.'}
}
function New-Fixture {
    param([switch]$Duplicates)
    $folder=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $paths=@((Join-Path $folder 'keep.bin'),(Join-Path $folder 'copy1.bin'),(Join-Path $folder 'copy2.bin'))
    $hashes=@{}
    foreach($path in $paths){
        Assert-OwnedPath $path
        [IO.File]::WriteAllBytes($path,[byte[]](0,1,2,3,127,128,254,255))
        $hashes[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $item=[PSCustomObject]@{
        RecordType='ActionPlanItem';PlanItemId=[guid]::NewGuid().ToString('N');PlanState='ReadyForExecution'
        ExecutionReady=$true;UserApproved=$true;RequiresUserApproval=$true;BackupRequired=$true
        RollbackStrategy='BackupBeforeChange';Executed=$false;ProposedAction='CleanupFile'
        Target=$paths[0];KeepPath='';DeletePaths=@();Evidence=$null;PotentialReclaimBytes=8
    }
    if($Duplicates){
        $group=@(Get-TetraDuplicateInventory -FileData @(Get-Item -LiteralPath $paths))[0]
        $item.ProposedAction='RemoveDuplicateCopies';$item.KeepPath=$paths[0];$item.DeletePaths=@($paths[1],$paths[2])
        $item.Evidence=[PSCustomObject]@{Evidence=[PSCustomObject]@{Evidence=$group}};$item.PotentialReclaimBytes=16
    }
    return [PSCustomObject]@{
        Paths=$paths;Hashes=$hashes;Item=$item
        Plan=[PSCustomObject]@{RecordType='ActionPlanSnapshot';ActionPlanId='integration-plan';ExecutionPerformed=$false;Items=@($item)}
    }
}
function Assert-OriginalBytes {
    param([object]$Fixture)
    foreach($path in $Fixture.Paths){
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing restored file: $path"
        Assert-True ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $Fixture.Hashes[$path]) "Restored bytes differ: $path"
    }
}
function Get-OnlyNewBackup {
    param([string[]]$BeforeIds)
    $new=@(Get-TetraBackupList -Category General | Where-Object {$BeforeIds -notcontains $_.BackupId})
    Assert-True ($new.Count -eq 1) 'Expected exactly one new execution backup before deletion.'
    return $new[0]
}
function Get-VerifiedManifest {
    param([string]$BackupId,[string[]]$ExpectedPaths)
    $integrity=Test-TetraBackupIntegrity -Category General -BackupId $BackupId
    Assert-True $integrity.IsValid 'Actual backup integrity failed.'
    $manifest=Get-TetraBackupManifest -Category General -BackupId $BackupId
    Assert-True (@($manifest.Items).Count -eq $ExpectedPaths.Count) 'Wrong backup item count.'
    foreach($entry in @($manifest.Items)){
        Assert-True ($ExpectedPaths -contains $entry.OriginalPath) 'Unexpected file was backed up.'
        $payload=Resolve-TetraBackupPayloadItemPath -Category General -BackupId $BackupId -StoredRelativePath $entry.StoredRelativePath
        Assert-OwnedPath $payload
        Assert-True ((Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash -eq $entry.Sha256) 'Stored payload does not match manifest.'
    }
    return $manifest
}
function Invoke-IntegrationTest {
    param([string]$Name,[scriptblock]$Body)
    try{& $Body | Out-Null;$integrationResults.Add([PSCustomObject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$integrationResults.Add([PSCustomObject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})}
}
try{
    New-Item -ItemType Directory -Path $isolatedProject,$fixtureRoot | Out-Null
    $moduleFiles=@('Config/PathHelpers.ps1','Config/Config.ps1','Config/ProductInfo.ps1','Config/DeviceIdentity.ps1','Engine/LoggerEngine.ps1','Engine/BackupEngine.ps1','Engine/DuplicateInventoryEngine.ps1','Engine/ExecutionEngine.ps1')
    foreach($relative in $moduleFiles){
        $source=Join-Path $sourceRoot $relative;$destination=Join-Path $isolatedProject $relative
        Assert-OwnedPath $destination
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
        Assert-True ((Get-FileHash -LiteralPath $source).Hash -eq (Get-FileHash -LiteralPath $destination).Hash) 'Copied production module differs.'
        . $destination
    }
    Initialize-TetraConfig | Out-Null
    Assert-True ((Get-TetraBackupDirectory) -eq (Join-Path $isolatedProject 'Backup')) 'Backup storage must be isolated.'
    Assert-True ((Get-TetraLogDirectory) -eq (Join-Path $isolatedProject 'Logs')) 'Logs must be isolated.'

    Invoke-IntegrationTest 'Cleanup uses real backup then manual restore reproduces bytes' {
        $f=New-Fixture
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false
        Assert-True ($r.Results[0].State -eq 'ExecutedVerified') $r.Results[0].Message
        Assert-True (-not (Test-Path -LiteralPath $f.Paths[0])) 'Cleanup did not remove target.'
        $manifest=Get-VerifiedManifest $r.Results[0].BackupId @($f.Paths[0])
        Assert-True ($manifest.Items[0].Sha256 -eq $f.Hashes[$f.Paths[0]]) 'Backup differs from original bytes.'
        $restored=Restore-TetraBackup -Category General -BackupId $r.Results[0].BackupId -Confirm:$false
        Assert-True ($restored.Success -and $restored.ItemsRestored -eq 1) 'Restore must report exactly one file.'
        Assert-True ([string]::IsNullOrEmpty($restored.PreRestoreSnapshotId)) 'Missing target needs no overwrite snapshot.'
        Assert-OriginalBytes $f
    }
    Invoke-IntegrationTest 'Duplicates use real multi-file backup and retain original copy' {
        $f=New-Fixture -Duplicates
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false
        Assert-True ($r.Results[0].State -eq 'ExecutedVerified') $r.Results[0].Message
        Assert-True ((Test-Path -LiteralPath $f.Paths[0]) -and -not (Test-Path -LiteralPath $f.Paths[1]) -and -not (Test-Path -LiteralPath $f.Paths[2])) 'Duplicate selection was not preserved.'
        $manifest=Get-VerifiedManifest $r.Results[0].BackupId @($f.Paths[1],$f.Paths[2])
        $restored=Restore-TetraBackup -Category General -BackupId $r.Results[0].BackupId -Confirm:$false
        Assert-True ($restored.Success -and $restored.ItemsRestored -eq 2) 'Both selected copies must restore.'
        Assert-OriginalBytes $f
    }
    Invoke-IntegrationTest 'Failure on second delete triggers real rollback of first delete' {
        $f=New-Fixture -Duplicates;$script:deleteCalls=0
        $script:beforeBackupIds=@(Get-TetraBackupList -Category General | ForEach-Object {$_.BackupId})
        $delete={param($path,$item)
            $script:deleteCalls++
            if($script:deleteCalls -eq 2){throw 'Injected second-delete failure.'}
            $backup=Get-OnlyNewBackup $script:beforeBackupIds
            $null=Get-VerifiedManifest $backup.BackupId @($item.DeletePaths)
            Assert-OwnedPath $path;Remove-Item -LiteralPath $path -Force
        }
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false -DeleteProvider $delete
        Assert-True ($r.Results[0].State -eq 'RolledBack') $r.Results[0].Message
        Assert-True ($script:deleteCalls -eq 2 -and $r.Results[0].RollbackSucceeded -and $r.MutationAttempted) 'Rollback lifecycle mismatch.'
        Assert-OriginalBytes $f
        $snapshots=@(Get-TetraBackupList -Category General | Where-Object {$_.IsAutoPreRestoreSnapshot -and $script:beforeBackupIds -notcontains $_.BackupId})
        Assert-True ($snapshots.Count -eq 1) 'Existing second copy needs a pre-restore safety snapshot.'
        $null=Get-VerifiedManifest $snapshots[0].BackupId @($f.Paths[2])
    }
    Invoke-IntegrationTest 'Failed deletion verification triggers real restore' {
        $f=New-Fixture
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false -DeleteProvider {param($path,$item)}
        Assert-True ($r.Results[0].State -eq 'RolledBack' -and $r.Results[0].RollbackSucceeded) $r.Results[0].Message
        Assert-OriginalBytes $f
    }
    Invoke-IntegrationTest 'Protected source is refused by real backup before deletion' {
        $f=New-Fixture;$protected=Join-Path $isolatedProject 'Config/protected-fixture.bin'
        Assert-OwnedPath $protected;[IO.File]::WriteAllBytes($protected,[byte[]](11,12,13))
        $f.Item.Target=$protected;$script:deleteCalls=0
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false -DeleteProvider {param($path,$item)$script:deleteCalls++}
        Assert-True ($r.Results[0].State -eq 'ExecutionFailed' -and -not $r.Results[0].BackupCreated) 'Unsafe backup source must fail.'
        Assert-True ($script:deleteCalls -eq 0 -and -not $r.MutationAttempted) 'Delete may not be attempted.'
        Assert-True ([IO.File]::ReadAllBytes($protected)[0] -eq 11) 'Protected file changed.'
    }
    Invoke-IntegrationTest 'Corrupt actual payload makes automatic rollback fail explicitly' {
        $f=New-Fixture
        $script:beforeBackupIds=@(Get-TetraBackupList -Category General | ForEach-Object {$_.BackupId})
        $delete={param($path,$item)
            $backup=Get-OnlyNewBackup $script:beforeBackupIds
            $manifest=Get-VerifiedManifest $backup.BackupId @($path)
            $payload=Resolve-TetraBackupPayloadItemPath -Category General -BackupId $backup.BackupId -StoredRelativePath $manifest.Items[0].StoredRelativePath
            Assert-OwnedPath $path;Assert-OwnedPath $payload
            Remove-Item -LiteralPath $path -Force
            [IO.File]::WriteAllBytes($payload,[byte[]](9,9,9))
            throw 'Injected corruption after deletion.'
        }
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false -DeleteProvider $delete
        Assert-True ($r.Results[0].State -eq 'RollbackFailed' -and $r.Results[0].RollbackAttempted -and -not $r.Results[0].RollbackSucceeded) $r.Results[0].Message
        Assert-True (-not (Test-Path -LiteralPath $f.Paths[0])) 'Corrupt backup must not be restored as valid data.'
        Assert-True (-not (Test-TetraBackupIntegrity -Category General -BackupId $r.Results[0].BackupId).IsValid) 'Corruption must be detected.'
    }
    Invoke-IntegrationTest 'Real restore snapshots overwritten content before restoring original' {
        $f=New-Fixture;$backup=Backup-TetraItem -Path $f.Paths[0] -Category General -Confirm:$false
        [IO.File]::WriteAllBytes($f.Paths[0],[byte[]](5,6,7,8))
        $changedHash=(Get-FileHash -LiteralPath $f.Paths[0]).Hash
        $restored=Restore-TetraBackup -Category General -BackupId $backup.BackupId -Confirm:$false
        Assert-True ($restored.Success -and -not [string]::IsNullOrEmpty($restored.PreRestoreSnapshotId)) 'Overwrite requires a safety snapshot.'
        Assert-OriginalBytes $f
        $snapshot=Get-VerifiedManifest $restored.PreRestoreSnapshotId @($f.Paths[0])
        Assert-True ($snapshot.IsAutoPreRestoreSnapshot -and $snapshot.Items[0].Sha256 -eq $changedHash) 'Safety snapshot must preserve overwritten bytes.'
    }
    Invoke-IntegrationTest 'Manual restore rejects a destination redirected into protected Config' {
        $redirectFolder=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
        Assert-OwnedPath $redirectFolder
        New-Item -ItemType Directory -Path $redirectFolder | Out-Null
        $leaf='restore-guard-'+[guid]::NewGuid().ToString('N')+'.bin'
        $original=Join-Path $redirectFolder $leaf
        [IO.File]::WriteAllText($original,'original backup bytes')
        $backup=Backup-TetraItem -Path @($original) -Category General -Label 'Restore destination safety fixture' -RequestedByModule 'IntegrationTests'
        $protectedFolder=Join-Path $isolatedProject 'Config'
        $protectedFile=Join-Path $protectedFolder $leaf
        Assert-OwnedPath $protectedFile
        [IO.File]::WriteAllText($protectedFile,'protected fixture must remain unchanged')
        $protectedHash=(Get-FileHash -LiteralPath $protectedFile).Hash
        [IO.File]::Delete($original)
        [IO.Directory]::Delete($redirectFolder)
        New-Item -ItemType Junction -Path $redirectFolder -Target $protectedFolder | Out-Null
        try {
            $beforeIds=@(Get-TetraBackupList -Category General).Count
            $rejected=$false
            try { Restore-TetraBackup -Category General -BackupId $backup.BackupId -Confirm:$false | Out-Null }
            catch { $rejected=$_.Exception.Message -match 'reparse point' }
            Assert-True $rejected 'Restore must reject the redirected destination before copying.'
            Assert-True ((Get-FileHash -LiteralPath $protectedFile).Hash -eq $protectedHash) 'Protected fixture was overwritten.'
            Assert-True (@(Get-TetraBackupList -Category General).Count -eq $beforeIds) 'Rejected restore must not create a safety snapshot.'
        } finally {
            # Remove this owned junction without traversing its target before outer cleanup.
            [IO.Directory]::Delete($redirectFolder)
        }
    }
    Invoke-IntegrationTest 'Preview and WhatIf create no real backup and preserve files' {
        $f=New-Fixture -Duplicates;$before=@(Get-TetraBackupList -Category General).Count
        $preview=Invoke-TetraExecution -ActionPlan $f.Plan
        $whatif=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -WhatIf
        Assert-True ($preview.Results[0].State -eq 'Preview' -and $whatif.Results[0].State -eq 'WhatIf') 'Preview/WhatIf lifecycle mismatch.'
        Assert-True (@(Get-TetraBackupList -Category General).Count -eq $before) 'Preview/WhatIf created a backup.'
        Assert-OriginalBytes $f
    }
}finally{
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if((Split-Path $resolved -Parent) -ne $tempBase -or (Split-Path $resolved -Leaf) -ne $runName){throw 'Refusing cleanup outside owned temporary project.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
foreach($r in $integrationResults){Write-Output "[$(if($r.Passed){'PASS'}else{'FAIL'})] $($r.Name)";if(-not $r.Passed){Write-Output $r.Error}}
$passed=@($integrationResults | Where-Object {$_.Passed}).Count
Write-Output "PASS: $passed/$($integrationResults.Count)"
Write-Output "FAIL: $($integrationResults.Count-$passed)/$($integrationResults.Count)"
if($passed -ne $integrationResults.Count){exit 1}
