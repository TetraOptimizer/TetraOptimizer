#Requires -Version 5.1
[CmdletBinding()]
param([string]$EngineRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($EngineRoot)){$EngineRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'Engine'}
. (Join-Path $EngineRoot 'DuplicateInventoryEngine.ps1')
. (Join-Path $EngineRoot 'ExecutionEngine.ps1')
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$runName='TetraDuplicateSafety_'+[guid]::NewGuid().ToString('N')
$runRoot=Join-Path $tempBase $runName
New-Item -ItemType Directory -Path $runRoot | Out-Null
$results=[System.Collections.Generic.List[object]]::new()
function Assert-True {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Assert-FixturePath {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith($runRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path escaped this test run.'}
}
function New-Fixture {
    param([string]$Algorithm='SHA256')
    $folder=Join-Path $runRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $keep=Join-Path $folder 'keep.bin';$first=Join-Path $folder 'copy1.bin';$second=Join-Path $folder 'copy2.bin'
    foreach($path in @($keep,$first,$second)){Assert-FixturePath $path;[IO.File]::WriteAllBytes($path,[byte[]](1,2,3,4))}
    $groups=@(Get-TetraDuplicateInventory -FileData @(Get-Item -LiteralPath $keep,$first,$second) -Algorithm $Algorithm)
    Assert-True ($groups.Count -eq 1) 'Fixture must be a real confirmed duplicate group.'
    $item=[PSCustomObject]@{
        RecordType='ActionPlanItem';PlanItemId='safety-item';PlanState='ReadyForExecution'
        ExecutionReady=$true;UserApproved=$true;RequiresUserApproval=$true;BackupRequired=$true
        RollbackStrategy='BackupBeforeChange';Executed=$false;ProposedAction='RemoveDuplicateCopies'
        KeepPath=$keep;DeletePaths=@($first,$second);PotentialReclaimBytes=8
        Evidence=[PSCustomObject]@{Evidence=[PSCustomObject]@{Evidence=$groups[0]}}
    }
    return [PSCustomObject]@{Keep=$keep;First=$first;Second=$second;Item=$item;Evidence=$groups[0];Plan=[PSCustomObject]@{RecordType='ActionPlanSnapshot';ActionPlanId='safety-plan';ExecutionPerformed=$false;Items=@($item)}}
}
function Change-Content {param([string]$Path)Assert-FixturePath $Path;[IO.File]::WriteAllBytes($Path,[byte[]](5,6,7,8))}
function Assert-Rejected {
    param([object]$Fixture)
    $check=Test-TetraExecutionPreflight -PlanItem $Fixture.Item
    Assert-True (-not $check.IsValid) 'Stale or invalid evidence must fail preflight.'
    Assert-True (@($check.Errors).Count -gt 0) 'Failure must explain its cause.'
}
function Invoke-Test {
    param([string]$Name,[scriptblock]$Body)
    try{& $Body | Out-Null;$results.Add([PSCustomObject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$results.Add([PSCustomObject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})}
}
function New-ProviderArguments {
    $script:backupCalls=0;$script:deleteCalls=0;$script:rollbackCalls=0
    return @{
        BackupProvider={param($paths,$item)$script:backupCalls++;[PSCustomObject]@{Success=$true;BackupId='fixture-backup'}}
        DeleteProvider={param($path,$item)$script:deleteCalls++;throw 'Unexpected deletion.'}
        RollbackProvider={param($id,$item)$script:rollbackCalls++;[PSCustomObject]@{Success=$false}}
    }
}
function Assert-NoDeleteOrRollback {
    param([object]$Result,[bool]$BackupExpected)
    Assert-True ($Result.Results[0].State -eq 'PreflightFailed') 'Expected PreflightFailed.'
    Assert-True ($script:deleteCalls -eq 0 -and $script:rollbackCalls -eq 0) 'No deletion or rollback may run.'
    Assert-True (-not $Result.MutationAttempted) 'Must report zero mutation attempted.'
    Assert-True ($Result.Results[0].BackupCreated -eq $BackupExpected) 'BackupCreated mismatch.'
    Assert-True (-not $Result.Results[0].RollbackAttempted) 'RollbackAttempted must be false.'
}
try{
    foreach($algorithm in @('SHA256','SHA384','SHA512')){
        Invoke-Test "Unchanged $algorithm evidence passes" {
            $f=New-Fixture -Algorithm $algorithm
            Assert-True (Test-TetraExecutionPreflight -PlanItem $f.Item).IsValid 'Valid content must pass.'
        }
    }
    Invoke-Test 'Changed delete copy with unchanged size is rejected' {$f=New-Fixture;Change-Content $f.First;Assert-Rejected $f}
    Invoke-Test 'Changed retained copy is rejected' {$f=New-Fixture;Change-Content $f.Keep;Assert-Rejected $f}
    Invoke-Test 'All copies matching each other but not original evidence are rejected' {
        $f=New-Fixture;foreach($path in @($f.Keep,$f.First,$f.Second)){Change-Content $path};Assert-Rejected $f
    }
    Invoke-Test 'Changed file size is rejected' {$f=New-Fixture;[IO.File]::WriteAllBytes($f.First,[byte[]](1,2,3));Assert-Rejected $f}
    Invoke-Test 'Missing hash evidence is rejected' {$f=New-Fixture;$f.Evidence.PSObject.Properties.Remove('Hash');Assert-Rejected $f}
    Invoke-Test 'Malformed hash is rejected' {$f=New-Fixture;$f.Evidence.Hash='not-a-hash';Assert-Rejected $f}
    Invoke-Test 'Unsupported hash algorithm is rejected' {$f=New-Fixture;$f.Evidence.HashAlgorithm='MD5';Assert-Rejected $f}
    Invoke-Test 'Invalid or missing size evidence is rejected' {
        foreach($value in @($null,'invalid',0,-1,'4.5')){$f=New-Fixture;$f.Evidence.FileSizeBytes=$value;Assert-Rejected $f}
    }
    Invoke-Test 'Unreadable content fails closed' {
        $f=New-Fixture;$lock=[IO.File]::Open($f.First,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{Assert-Rejected $f}finally{$lock.Dispose()}
    }
    Invoke-Test 'PathExistsProvider cannot bypass missing real content' {
        $f=New-Fixture;Assert-FixturePath $f.First;Remove-Item -LiteralPath $f.First
        $p=Test-TetraExecutionPreflight -PlanItem $f.Item -PathExistsProvider {$true}
        Assert-True (-not $p.IsValid) 'Synthetic existence must not bypass hashing.'
    }
    Invoke-Test 'Stale preflight prevents backup and deletion' {
        $f=New-Fixture;Change-Content $f.First;$providerArgs=New-ProviderArguments
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providerArgs
        Assert-NoDeleteOrRollback $r $false;Assert-True ($script:backupCalls -eq 0) 'No backup expected.'
    }
    Invoke-Test 'Copy changed during backup stops without rollback' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments
        $providerArgs.BackupProvider={param($paths,$item)$script:backupCalls++;Change-Content $paths[0];[PSCustomObject]@{Success=$true;BackupId='fixture-backup'}}
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providerArgs
        Assert-NoDeleteOrRollback $r $true;Assert-True ($script:backupCalls -eq 1) 'One backup expected.'
        Assert-True ([IO.File]::ReadAllBytes($f.First)[0] -eq 5) 'New content must remain intact.'
        Assert-True ($r.Results[0].BackupId -eq 'fixture-backup') 'Backup must remain discoverable.'
    }
    Invoke-Test 'Keep changed during backup stops without rollback' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments
        $providerArgs.BackupProvider={param($paths,$item)Change-Content $item.KeepPath;[PSCustomObject]@{Success=$true;BackupId='fixture-backup'}}
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providerArgs
        Assert-NoDeleteOrRollback $r $true
    }
    Invoke-Test 'Last copy changed during backup prevents even first deletion' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments
        $providerArgs.BackupProvider={param($paths,$item)Change-Content $paths[1];[PSCustomObject]@{Success=$true;BackupId='fixture-backup'}}
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providerArgs
        Assert-NoDeleteOrRollback $r $true
        Assert-True (Test-Path -LiteralPath $f.First) 'First copy must remain intact.'
    }
    Invoke-Test 'Keep disappearing during backup stops without rollback' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments
        $providerArgs.BackupProvider={param($paths,$item)Assert-FixturePath $item.KeepPath;Remove-Item -LiteralPath $item.KeepPath;[PSCustomObject]@{Success=$true;BackupId='fixture-backup'}}
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providerArgs
        Assert-NoDeleteOrRollback $r $true
    }
    Invoke-Test 'Backup provider cannot replace captured evidence with new hash' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments
        $providerArgs.BackupProvider={param($paths,$item)
            foreach($path in (@($item.KeepPath)+@($paths))){Change-Content $path}
            $item.Evidence.Evidence.Evidence.Hash=(Get-FileHash -LiteralPath $item.KeepPath -Algorithm SHA256).Hash
            [PSCustomObject]@{Success=$true;BackupId='fixture-backup'}
        }
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providerArgs
        Assert-NoDeleteOrRollback $r $true
    }
    Invoke-Test 'Preview performs no backup or deletion' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments;$r=Invoke-TetraExecution -ActionPlan $f.Plan @providerArgs
        Assert-True ($r.Results[0].State -eq 'Preview') 'Expected Preview.'
        Assert-True ($script:backupCalls -eq 0 -and $script:deleteCalls -eq 0) 'Preview must not mutate.'
    }
    Invoke-Test 'WhatIf performs no backup or deletion' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments;$r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -WhatIf @providerArgs
        Assert-True ($r.Results[0].State -eq 'WhatIf') 'Expected WhatIf.'
        Assert-True ($script:backupCalls -eq 0 -and $script:deleteCalls -eq 0) 'WhatIf must not mutate.'
    }
    Invoke-Test 'Unchanged multiple copies execute and preserve KeepPath' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments;$providerArgs.Remove('DeleteProvider')
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providerArgs
        Assert-True ($r.Results[0].State -eq 'ExecutedVerified') 'Expected verified deletion.'
        Assert-True ((Test-Path -LiteralPath $f.Keep) -and -not (Test-Path -LiteralPath $f.First) -and -not (Test-Path -LiteralPath $f.Second)) 'Only selected copies may be removed.'
    }
    Invoke-Test 'Change between deletes blocks next delete and attempts rollback' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments
        $providerArgs.DeleteProvider={param($path,$item)$script:deleteCalls++;Assert-FixturePath $path;Remove-Item -LiteralPath $path;Change-Content $item.DeletePaths[1]}
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providerArgs
        Assert-True ($script:deleteCalls -eq 1) 'Changed second target must not be deleted.'
        Assert-True ($script:rollbackCalls -eq 1 -and $r.Results[0].RollbackAttempted) 'Partial execution must attempt rollback.'
        Assert-True ($r.Results[0].State -eq 'RollbackFailed' -and $r.MutationAttempted) 'Injected rollback failure must be explicit.'
        Assert-True (Test-Path -LiteralPath $f.Second) 'Second target must remain.'
    }
    Invoke-Test 'Backup failure still prevents deletion' {
        $f=New-Fixture;$providerArgs=New-ProviderArguments;$providerArgs.BackupProvider={[PSCustomObject]@{Success=$false}}
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providerArgs
        Assert-True ($r.Results[0].State -eq 'ExecutionFailed' -and $script:deleteCalls -eq 0) 'Backup failure must prevent deletion.'
    }
}finally{
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if((Split-Path $resolved -Parent) -ne $tempBase -or (Split-Path $resolved -Leaf) -ne $runName){throw 'Refusing cleanup outside the owned fixture root.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
foreach($r in $results){Write-Output "[$(if($r.Passed){'PASS'}else{'FAIL'})] $($r.Name)";if(-not $r.Passed){Write-Output $r.Error}}
$passed=@($results | Where-Object {$_.Passed}).Count
Write-Output "PASS: $passed/$($results.Count)"
Write-Output "FAIL: $($results.Count-$passed)/$($results.Count)"
if($passed -ne $results.Count){exit 1}
