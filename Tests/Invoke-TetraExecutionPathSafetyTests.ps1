#Requires -Version 5.1
[CmdletBinding()]param([string]$EngineRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($EngineRoot)){$EngineRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'Engine'}
. (Join-Path $EngineRoot 'DuplicateInventoryEngine.ps1')
. (Join-Path $EngineRoot 'ExecutionEngine.ps1')
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$runName='TetraPathSafety_'+[guid]::NewGuid().ToString('N')
$runRoot=Join-Path $tempBase $runName
New-Item -ItemType Directory -Path $runRoot | Out-Null
$pathResults=[System.Collections.Generic.List[object]]::new()
$junctions=[System.Collections.Generic.List[string]]::new()
function Assert-True {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Assert-OwnedPath {
    param([string]$Path)
    if(-not [IO.Path]::GetFullPath($Path).StartsWith($runRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path escaped fixture root.'}
}
function New-Fixture {
    param([switch]$Cleanup,[switch]$Nested)
    $folder=Join-Path $runRoot ([guid]::NewGuid().ToString('N'))
    $directories=@((Join-Path $folder 'keep'),(Join-Path $folder 'copy1'),(Join-Path $folder 'copy2'))
    $paths=@()
    foreach($directory in $directories){
        $fileDirectory=if($Nested){Join-Path $directory 'nested'}else{$directory}
        New-Item -ItemType Directory -Path $fileDirectory -Force | Out-Null
        $path=Join-Path $fileDirectory 'data.bin';Assert-OwnedPath $path
        [IO.File]::WriteAllBytes($path,[byte[]](1,2,3,4));$paths+=@($path)
    }
    $group=@(Get-TetraDuplicateInventory -FileData @(Get-Item -LiteralPath $paths))[0]
    $item=[PSCustomObject]@{
        RecordType='ActionPlanItem';PlanItemId='path-safety';PlanState='ReadyForExecution'
        ExecutionReady=$true;UserApproved=$true;RequiresUserApproval=$true;BackupRequired=$true
        RollbackStrategy='BackupBeforeChange';Executed=$false;ProposedAction='RemoveDuplicateCopies'
        Target=$paths[1];KeepPath=$paths[0];DeletePaths=@($paths[1],$paths[2]);PotentialReclaimBytes=8
        Evidence=[PSCustomObject]@{Evidence=[PSCustomObject]@{Evidence=$group}}
    }
    if($Cleanup){$item.ProposedAction='CleanupFile'}
    return [PSCustomObject]@{Paths=$paths;Directories=$directories;Evidence=$group;Item=$item;Plan=[PSCustomObject]@{RecordType='ActionPlanSnapshot';ActionPlanId='paths';ExecutionPerformed=$false;Items=@($item)}}
}
function Redirect-Directory {
    param([string]$Directory,[string]$Target)
    $saved=$Directory+'-original'
    foreach($path in @($Directory,$Target,$saved)){Assert-OwnedPath $path}
    Move-Item -LiteralPath $Directory -Destination $saved
    New-Item -ItemType Junction -Path $Directory -Target $Target | Out-Null
    $junctions.Add($Directory)
    Assert-True ([bool]((Get-Item -LiteralPath $Directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Fixture must contain a real junction.'
}
function Assert-Rejected {
    param([object]$Fixture)
    $p=Test-TetraExecutionPreflight -PlanItem $Fixture.Item
    Assert-True (-not $p.IsValid) 'Unsafe path was accepted.'
    Assert-True (@($p.Errors).Count -gt 0) 'Failure must include a reason.'
}
function New-ProbeProviders {
    $script:deleteCalls=0;$script:rollbackCalls=0;$script:backupCalls=0
    return @{
        BackupProvider={param($paths,$item)$script:backupCalls++;[PSCustomObject]@{Success=$true;BackupId='path-backup'}}
        DeleteProvider={param($path,$item)$script:deleteCalls++;throw 'Unexpected deletion attempt.'}
        RollbackProvider={param($id,$item)$script:rollbackCalls++;[PSCustomObject]@{Success=$false}}
    }
}
function Assert-StoppedBeforeDelete {
    param([object]$Result)
    Assert-True ($Result.Results[0].State -eq 'PreflightFailed') $Result.Results[0].Message
    Assert-True ($script:deleteCalls -eq 0 -and $script:rollbackCalls -eq 0) 'Neither delete nor rollback may run.'
    Assert-True (-not $Result.MutationAttempted -and $Result.Results[0].BackupCreated) 'Post-backup stop metadata is wrong.'
}
function Invoke-Test {
    param([string]$Name,[scriptblock]$Body)
    try{& $Body | Out-Null;$pathResults.Add([PSCustomObject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$pathResults.Add([PSCustomObject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})}
}
try{
    Invoke-Test 'Ordinary cleanup remains executable' {
        $f=New-Fixture -Cleanup;$providers=New-ProbeProviders;$providers.Remove('DeleteProvider')
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providers
        Assert-True ($r.Results[0].State -eq 'ExecutedVerified') $r.Results[0].Message
        Assert-True (-not (Test-Path -LiteralPath $f.Item.Target)) 'Target still exists.'
    }
    Invoke-Test 'Ordinary duplicate copies remain executable' {
        $f=New-Fixture;$providers=New-ProbeProviders;$providers.Remove('DeleteProvider')
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providers
        Assert-True ($r.Results[0].State -eq 'ExecutedVerified') $r.Results[0].Message
        Assert-True (Test-Path -LiteralPath $f.Item.KeepPath) 'KeepPath was lost.'
    }
    Invoke-Test 'DeletePath redirected to KeepPath is rejected despite identical hash' {
        $f=New-Fixture;Redirect-Directory $f.Directories[1] $f.Directories[0];Assert-Rejected $f
    }
    Invoke-Test 'Redirected KeepPath is rejected' {
        $f=New-Fixture;Redirect-Directory $f.Directories[0] $f.Directories[1];Assert-Rejected $f
    }
    Invoke-Test 'Redirected cleanup target is rejected' {
        $f=New-Fixture -Cleanup;Redirect-Directory $f.Directories[1] $f.Directories[0];Assert-Rejected $f
    }
    Invoke-Test 'Junction in a higher ancestor is rejected' {
        $f=New-Fixture -Nested;Redirect-Directory $f.Directories[1] $f.Directories[0];Assert-Rejected $f
    }
    Invoke-Test 'PathExistsProvider cannot bypass a real junction' {
        $f=New-Fixture -Cleanup;Redirect-Directory $f.Directories[1] $f.Directories[0]
        $p=Test-TetraExecutionPreflight -PlanItem $f.Item -PathExistsProvider {$true}
        Assert-True (-not $p.IsValid) 'Synthetic existence bypassed path validation.'
    }
    Invoke-Test 'Redirected selection stops before backup' {
        $f=New-Fixture;Redirect-Directory $f.Directories[1] $f.Directories[0];$providers=New-ProbeProviders
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providers
        Assert-True ($r.Results[0].State -eq 'PreflightFailed' -and $script:backupCalls -eq 0 -and $script:deleteCalls -eq 0) 'Preflight must stop the whole operation.'
    }
    Invoke-Test 'Duplicate redirection during backup stops before deletion' {
        $f=New-Fixture;$providers=New-ProbeProviders
        $providers.BackupProvider={param($paths,$item)Redirect-Directory (Split-Path $paths[0] -Parent) (Split-Path $item.KeepPath -Parent);[PSCustomObject]@{Success=$true;BackupId='path-backup'}}
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providers
        Assert-StoppedBeforeDelete $r;Assert-True (Test-Path -LiteralPath $f.Paths[0]) 'Keep file changed.'
    }
    Invoke-Test 'KeepPath redirection during backup stops before deletion' {
        $f=New-Fixture;$providers=New-ProbeProviders
        $providers.BackupProvider={param($paths,$item)Redirect-Directory (Split-Path $item.KeepPath -Parent) (Split-Path $paths[0] -Parent);[PSCustomObject]@{Success=$true;BackupId='path-backup'}}
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providers
        Assert-StoppedBeforeDelete $r
    }
    Invoke-Test 'Cleanup redirection during backup stops before deletion' {
        $f=New-Fixture -Cleanup;$providers=New-ProbeProviders
        $providers.BackupProvider={param($paths,$item)Redirect-Directory (Split-Path $paths[0] -Parent) (Split-Path $item.KeepPath -Parent);[PSCustomObject]@{Success=$true;BackupId='path-backup'}}
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providers
        Assert-StoppedBeforeDelete $r
    }
    Invoke-Test 'Alternate spelling of KeepPath cannot become a delete target' {
        $f=New-Fixture;$alias=Join-Path $f.Directories[0] '.\data.bin'
        $f.Item.DeletePaths=@($alias);$f.Evidence.Paths=@($f.Paths[0],$alias)
        Assert-Rejected $f
    }
    Invoke-Test 'Alternate spellings of one delete target are rejected' {
        $f=New-Fixture;$alias=Join-Path $f.Directories[1] '.\data.bin'
        $f.Item.DeletePaths=@($f.Paths[1],$alias);$f.Evidence.Paths=@($f.Paths[0],$f.Paths[1],$alias)
        Assert-Rejected $f
    }
    Invoke-Test 'Relative cleanup path cannot change meaning with location' {
        $f=New-Fixture -Cleanup;Push-Location -LiteralPath $f.Directories[1]
        try{$f.Item.Target='.\data.bin';Assert-Rejected $f}finally{Pop-Location}
    }
    Invoke-Test 'Redirection between deletes prevents both next delete and unsafe rollback' {
        $f=New-Fixture;$providers=New-ProbeProviders
        $providers.DeleteProvider={param($path,$item)
            $script:deleteCalls++
            if($script:deleteCalls -gt 1){throw 'Unsafe second deletion reached the provider.'}
            Assert-OwnedPath $path;Remove-Item -LiteralPath $path -Force
            Redirect-Directory (Split-Path $item.DeletePaths[1] -Parent) (Split-Path $item.KeepPath -Parent)
        }
        $r=Invoke-TetraExecution -ActionPlan $f.Plan -Execute -Confirm:$false @providers
        Assert-True ($script:deleteCalls -eq 1) 'Next deletion must be blocked.'
        Assert-True ($script:rollbackCalls -eq 0) 'Restore provider must not receive redirected paths.'
        Assert-True ($r.Results[0].State -eq 'RollbackFailed' -and $r.MutationAttempted -and $r.Results[0].RollbackAttempted) 'Partial execution must report failed safe rollback.'
        Assert-True (Test-Path -LiteralPath $f.Paths[0]) 'Retained file must remain.'
    }
}finally{
    # Unlink only the owned junction objects before recursively cleaning fixtures.
    for($index=$junctions.Count-1;$index -ge 0;$index--){
        $linkPath=$junctions[$index];Assert-OwnedPath $linkPath
        $link=Get-Item -LiteralPath $linkPath -Force -ErrorAction Stop
        if(-not ($link.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Refusing to unlink a normal directory.'}
        [IO.Directory]::Delete($linkPath)
    }
    $resolved=[IO.Path]::GetFullPath($runRoot)
    if((Split-Path $resolved -Parent) -ne $tempBase -or (Split-Path $resolved -Leaf) -ne $runName){throw 'Unsafe test cleanup root.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
foreach($r in $pathResults){Write-Output "[$(if($r.Passed){'PASS'}else{'FAIL'})] $($r.Name)";if(-not $r.Passed){Write-Output $r.Error}}
$passed=@($pathResults | Where-Object {$_.Passed}).Count
Write-Output "PASS: $passed/$($pathResults.Count)"
Write-Output "FAIL: $($pathResults.Count-$passed)/$($pathResults.Count)"
if($passed -ne $pathResults.Count){exit 1}
