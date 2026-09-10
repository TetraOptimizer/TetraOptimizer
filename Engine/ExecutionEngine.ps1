#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Guarded Execution Engine V1
.DESCRIPTION
    Executes only explicitly approved ActionPlan items that are already in
    ReadyForExecution state. V1 supports exact file cleanup and confirmed
    duplicate-copy removal only.

    SAFETY MODEL:
      1. Execution is disabled unless -Execute is supplied.
      2. Every item is revalidated by a read-only preflight.
      3. Only CleanupFile and RemoveDuplicateCopies are supported in V1.
      4. Exact target paths must exist as files at execution time.
      5. Duplicate paths, size and hash are revalidated against scan evidence,
         including after backup and immediately before each deletion.
      6. A backup is mandatory before any delete operation.
      7. Backup success is required before mutation.
      8. Post-change verification must confirm deleted targets are absent and,
         for duplicate actions, KeepPath is still present.
      9. On execution/verification failure after backup, rollback is attempted.
     10. No service, registry, driver, task, or profile mutation is implemented
         by V1; unresolved action types are rejected by preflight.
#>
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-TetraExecutionStates {
    [CmdletBinding()][OutputType([string[]])]param()
    return @('Preview','Blocked','PreflightFailed','WhatIf','ExecutedVerified','ExecutionFailed','RolledBack','RollbackFailed')
}

function Get-TetraExecutionPropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function Get-TetraExecutionDuplicateEvidencePaths {
    [CmdletBinding()][OutputType([string[]])]
    param([Parameter(Mandatory=$true)][object]$PlanItem)
    $recommendation=Get-TetraExecutionPropertyValue $PlanItem 'Evidence' $null
    $finding=Get-TetraExecutionPropertyValue $recommendation 'Evidence' $null
    $duplicateEvidence=Get-TetraExecutionPropertyValue $finding 'Evidence' $null
    return @(@(Get-TetraExecutionPropertyValue $duplicateEvidence 'Paths' @()) | ForEach-Object {[string]$_})
}

function Test-TetraExecutionPathExists {
    param([Parameter(Mandatory=$true)][string]$Path,[scriptblock]$PathExistsProvider)
    if($null -ne $PathExistsProvider){return [bool](& $PathExistsProvider $Path)}
    return [bool](Test-Path -LiteralPath $Path -PathType Leaf)
}

function Test-TetraExecutionDuplicateContent {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param([object]$Evidence,[Parameter(Mandatory=$true)][string[]]$Paths)
    $errors=[System.Collections.Generic.List[string]]::new()
    $algorithm=[string](Get-TetraExecutionPropertyValue $Evidence 'HashAlgorithm' '')
    $expectedHash=[string](Get-TetraExecutionPropertyValue $Evidence 'Hash' '')
    $sizeText=[string](Get-TetraExecutionPropertyValue $Evidence 'FileSizeBytes' '')
    $expectedSize=0L
    $hashLengths=@{SHA256=64;SHA384=96;SHA512=128}
    if(-not $hashLengths.ContainsKey($algorithm)){$errors.Add('Duplicate evidence requires a supported hash algorithm.')}
    elseif($expectedHash -notmatch ('\A[0-9a-fA-F]{'+$hashLengths[$algorithm]+'}\z')){$errors.Add('Duplicate evidence hash is missing or malformed.')}
    if(-not [long]::TryParse($sizeText,[ref]$expectedSize) -or $expectedSize -lt 1){$errors.Add('Duplicate evidence requires a positive file size.')}
    if($errors.Count -eq 0){
        foreach($path in $Paths){
            $stream=$null;$hasher=$null
            try{
                $file=Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if($file -isnot [System.IO.FileInfo]){throw 'Target is not a filesystem file.'}
                # One read handle supplies both length and hash. Disallow writes
                # and deletes while hashing; this is not a lock through deletion.
                $stream=[System.IO.File]::Open($file.FullName,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
                if($stream.Length -ne $expectedSize){throw 'File size differs from the approved duplicate evidence.'}
                $hasher=[System.Security.Cryptography.HashAlgorithm]::Create($algorithm.ToUpperInvariant())
                $actualHash=[System.BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','')
                if($actualHash -ne $expectedHash){throw 'File content differs from the approved duplicate evidence.'}
            }catch{$errors.Add("Duplicate content check failed for '$path': $($_.Exception.Message)")}
            finally{
                if($null -ne $hasher){$hasher.Dispose()}
                if($null -ne $stream){$stream.Dispose()}
            }
        }
    }
    return [PSCustomObject]@{IsValid=($errors.Count -eq 0);Errors=$errors.ToArray()}
}

function Test-TetraExecutionPreflight {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][object]$PlanItem,
        [scriptblock]$PathExistsProvider
    )
    $errors=[System.Collections.Generic.List[string]]::new()
    if([string](Get-TetraExecutionPropertyValue $PlanItem 'RecordType' '') -ne 'ActionPlanItem'){$errors.Add('Item is not an ActionPlanItem.')}
    if([string](Get-TetraExecutionPropertyValue $PlanItem 'PlanState' '') -ne 'ReadyForExecution'){$errors.Add('PlanState is not ReadyForExecution.')}
    if(-not [bool](Get-TetraExecutionPropertyValue $PlanItem 'ExecutionReady' $false)){$errors.Add('ExecutionReady is false.')}
    if(-not [bool](Get-TetraExecutionPropertyValue $PlanItem 'UserApproved' $false)){$errors.Add('UserApproved is false.')}
    if(-not [bool](Get-TetraExecutionPropertyValue $PlanItem 'RequiresUserApproval' $false)){$errors.Add('Executable V1 changes must originate from an approval-required recommendation.')}
    if(-not [bool](Get-TetraExecutionPropertyValue $PlanItem 'BackupRequired' $false)){$errors.Add('BackupRequired is false; V1 refuses file deletion without backup.')}
    if([string](Get-TetraExecutionPropertyValue $PlanItem 'RollbackStrategy' '') -ne 'BackupBeforeChange'){$errors.Add('RollbackStrategy must be BackupBeforeChange.')}
    if([bool](Get-TetraExecutionPropertyValue $PlanItem 'Executed' $false)){$errors.Add('Item is already marked Executed.')}

    $action=[string](Get-TetraExecutionPropertyValue $PlanItem 'ProposedAction' '')
    $targets=[System.Collections.Generic.List[string]]::new()
    $keep=''
    $duplicateEvidence=$null
    if($action -eq 'CleanupFile'){
        $target=[string](Get-TetraExecutionPropertyValue $PlanItem 'Target' '')
        if([string]::IsNullOrWhiteSpace($target)){$errors.Add('CleanupFile requires an exact Target path.')}
        elseif(-not (Test-TetraExecutionPathExists -Path $target -PathExistsProvider $PathExistsProvider)){$errors.Add("Cleanup target does not exist as a file: $target")}
        else{$targets.Add($target)}
    }
    elseif($action -eq 'RemoveDuplicateCopies'){
        $keep=[string](Get-TetraExecutionPropertyValue $PlanItem 'KeepPath' '')
        $delete=@(@(Get-TetraExecutionPropertyValue $PlanItem 'DeletePaths' @()) | ForEach-Object {[string]$_})
        $evidencePaths=@(Get-TetraExecutionDuplicateEvidencePaths -PlanItem $PlanItem)
        if([string]::IsNullOrWhiteSpace($keep)){$errors.Add('RemoveDuplicateCopies requires KeepPath.')}
        elseif($evidencePaths -notcontains $keep){$errors.Add('KeepPath is outside confirmed duplicate evidence.')}
        elseif(-not (Test-TetraExecutionPathExists -Path $keep -PathExistsProvider $PathExistsProvider)){$errors.Add("KeepPath does not exist as a file: $keep")}
        if(@($delete).Count -lt 1){$errors.Add('RemoveDuplicateCopies requires at least one DeletePath.')}
        foreach($p in @($delete)){
            if([string]::IsNullOrWhiteSpace($p)){$errors.Add('DeletePaths contains an empty path.');continue}
            if($p -eq $keep){$errors.Add('KeepPath may not appear in DeletePaths.');continue}
            if($evidencePaths -notcontains $p){$errors.Add("DeletePath is outside confirmed duplicate evidence: $p");continue}
            if(-not (Test-TetraExecutionPathExists -Path $p -PathExistsProvider $PathExistsProvider)){$errors.Add("DeletePath does not exist as a file: $p");continue}
            if($targets -contains $p){$errors.Add("Duplicate DeletePath was supplied more than once: $p");continue}
            $targets.Add($p)
        }
        if(@($evidencePaths).Count -lt 2){$errors.Add('Confirmed duplicate evidence contains fewer than two paths.')}
        if($errors.Count -eq 0){
            $recommendation=Get-TetraExecutionPropertyValue $PlanItem 'Evidence' $null
            $finding=Get-TetraExecutionPropertyValue $recommendation 'Evidence' $null
            $source=Get-TetraExecutionPropertyValue $finding 'Evidence' $null
            # Capture scalar evidence before invoking any execution providers.
            $duplicateEvidence=[PSCustomObject]@{
                HashAlgorithm=[string](Get-TetraExecutionPropertyValue $source 'HashAlgorithm' '')
                Hash=[string](Get-TetraExecutionPropertyValue $source 'Hash' '')
                FileSizeBytes=[string](Get-TetraExecutionPropertyValue $source 'FileSizeBytes' '')
            }
            $content=Test-TetraExecutionDuplicateContent -Evidence $duplicateEvidence -Paths (@($keep)+$targets.ToArray())
            foreach($message in $content.Errors){$errors.Add($message)}
        }
    }
    else{$errors.Add("Unsupported V1 execution action: '$action'.")}

    return [PSCustomObject]@{
        IsValid=($errors.Count -eq 0)
        ProposedAction=$action
        Targets=$targets.ToArray()
        KeepPath=$keep
        DuplicateEvidence=$duplicateEvidence
        Errors=$errors.ToArray()
    }
}

function New-TetraExecutionResult {
    param([object]$Item,[string]$State,[string]$Message,[object]$Preflight=$null,[string]$BackupId='',[bool]$BackupCreated=$false,[bool]$RollbackAttempted=$false,[bool]$RollbackSucceeded=$false,[long]$BytesReclaimed=0)
    return [PSCustomObject]@{
        RecordType='ExecutionResult'
        PlanItemId=[string](Get-TetraExecutionPropertyValue $Item 'PlanItemId' '')
        RecommendationId=[string](Get-TetraExecutionPropertyValue $Item 'RecommendationId' '')
        Subject=[string](Get-TetraExecutionPropertyValue $Item 'Subject' '')
        ProposedAction=[string](Get-TetraExecutionPropertyValue $Item 'ProposedAction' '')
        State=$State
        Message=$Message
        BackupCreated=$BackupCreated
        BackupId=$BackupId
        RollbackAttempted=$RollbackAttempted
        RollbackSucceeded=$RollbackSucceeded
        BytesReclaimed=$BytesReclaimed
        Preflight=$Preflight
        Verified=($State -eq 'ExecutedVerified')
        ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
}

function Invoke-TetraExecution {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$ActionPlan,
        [switch]$Execute,
        [scriptblock]$BackupProvider,
        [scriptblock]$DeleteProvider,
        [scriptblock]$RollbackProvider,
        [scriptblock]$PathExistsProvider
    )
    if([string](Get-TetraExecutionPropertyValue $ActionPlan 'RecordType' '') -ne 'ActionPlanSnapshot'){throw 'Invoke-TetraExecution: Input must be an ActionPlanSnapshot.'}
    if([bool](Get-TetraExecutionPropertyValue $ActionPlan 'ExecutionPerformed' $true)){throw 'Invoke-TetraExecution: ActionPlan must not already report execution performed.'}

    $started=(Get-Date).ToUniversalTime();$results=[System.Collections.Generic.List[PSCustomObject]]::new()
    foreach($item in @(Get-TetraExecutionPropertyValue $ActionPlan 'Items' @())){
        if($null -eq $item){continue}
        if([string](Get-TetraExecutionPropertyValue $item 'PlanState' '') -ne 'ReadyForExecution'){
            $results.Add((New-TetraExecutionResult -Item $item -State 'Blocked' -Message 'Item is not ReadyForExecution and was not considered for mutation.'));continue
        }
        $preflight=Test-TetraExecutionPreflight -PlanItem $item -PathExistsProvider $PathExistsProvider
        if(-not $preflight.IsValid){$results.Add((New-TetraExecutionResult -Item $item -State 'PreflightFailed' -Message ($preflight.Errors -join ' | ') -Preflight $preflight));continue}
        if(-not $Execute.IsPresent){$results.Add((New-TetraExecutionResult -Item $item -State 'Preview' -Message 'Preflight passed, but -Execute was not supplied. No changes made.' -Preflight $preflight));continue}

        $targetSummary=(@($preflight.Targets) -join '; ')
        if(-not $PSCmdlet.ShouldProcess($targetSummary,"Execute $($preflight.ProposedAction) after verified backup")){
            $results.Add((New-TetraExecutionResult -Item $item -State 'WhatIf' -Message 'Execution declined or WhatIf requested. No backup or mutation performed.' -Preflight $preflight));continue
        }

        $backup=$null;$backupId='';$backupCreated=$false
        try{
            if($null -ne $BackupProvider){$backup=& $BackupProvider @($preflight.Targets) $item}
            else{
                if(-not (Get-Command Backup-TetraItem -ErrorAction SilentlyContinue)){throw 'Backup-TetraItem is unavailable.'}
                $backup=Backup-TetraItem -Path @($preflight.Targets) -Category General -Label "Pre-execution backup for $($item.PlanItemId)" -RequestedByModule 'ExecutionEngine' -Confirm:$false
            }
            if($null -eq $backup -or -not [bool](Get-TetraExecutionPropertyValue $backup 'Success' $false)){throw 'Mandatory pre-change backup did not report success.'}
            $backupId=[string](Get-TetraExecutionPropertyValue $backup 'BackupId' '')
            if([string]::IsNullOrWhiteSpace($backupId)){throw 'Mandatory pre-change backup returned no BackupId.'}
            $backupCreated=$true
        }catch{
            $results.Add((New-TetraExecutionResult -Item $item -State 'ExecutionFailed' -Message "Backup failed; zero deletion was attempted. $($_.Exception.Message)" -Preflight $preflight));continue
        }

        $mutationFailed=$false;$failureMessage='';$deleteAttempted=$false
        try{
            if($preflight.ProposedAction -eq 'RemoveDuplicateCopies'){
                # Check the entire selection after backup before deleting any copy.
                $content=Test-TetraExecutionDuplicateContent -Evidence $preflight.DuplicateEvidence -Paths (@($preflight.KeepPath)+@($preflight.Targets))
                if(-not $content.IsValid){throw ($content.Errors -join ' | ')}
            }
            foreach($path in @($preflight.Targets)){
                if($preflight.ProposedAction -eq 'RemoveDuplicateCopies'){
                    # Recheck this pair between deletes without repeatedly hashing
                    # all remaining copies or revisiting already-deleted targets.
                    $content=Test-TetraExecutionDuplicateContent -Evidence $preflight.DuplicateEvidence -Paths @($preflight.KeepPath,$path)
                    if(-not $content.IsValid){throw ($content.Errors -join ' | ')}
                }
                $deleteAttempted=$true
                if($null -ne $DeleteProvider){& $DeleteProvider $path $item | Out-Null}
                else{Remove-Item -LiteralPath $path -Force -ErrorAction Stop}
            }
            foreach($path in @($preflight.Targets)){if(Test-TetraExecutionPathExists -Path $path -PathExistsProvider $PathExistsProvider){throw "Verification failed: deleted target still exists: $path"}}
            if($preflight.ProposedAction -eq 'RemoveDuplicateCopies' -and -not (Test-TetraExecutionPathExists -Path $preflight.KeepPath -PathExistsProvider $PathExistsProvider)){throw "Verification failed: KeepPath is missing after duplicate cleanup: $($preflight.KeepPath)"}
        }catch{$mutationFailed=$true;$failureMessage=$_.Exception.Message}

        if($mutationFailed -and -not $deleteAttempted){
            # A changed file belongs to the user: do not overwrite it by rolling
            # back when this engine has not attempted any deletion.
            $results.Add((New-TetraExecutionResult -Item $item -State 'PreflightFailed' -Message "Post-backup content check failed; zero deletion was attempted. $failureMessage" -Preflight $preflight -BackupId $backupId -BackupCreated $true));continue
        }

        if(-not $mutationFailed){
            $reclaim=0L;try{$reclaim=[long](Get-TetraExecutionPropertyValue $item 'PotentialReclaimBytes' 0)}catch{}
            $results.Add((New-TetraExecutionResult -Item $item -State 'ExecutedVerified' -Message 'Execution completed and post-change verification passed.' -Preflight $preflight -BackupId $backupId -BackupCreated $true -BytesReclaimed $reclaim));continue
        }

        $rollbackOk=$false;$rollbackMessage=''
        try{
            if($null -ne $RollbackProvider){$rb=& $RollbackProvider $backupId $item;$rollbackOk=[bool](Get-TetraExecutionPropertyValue $rb 'Success' $false)}
            else{
                if(-not (Get-Command Restore-TetraBackup -ErrorAction SilentlyContinue)){throw 'Restore-TetraBackup is unavailable.'}
                $rb=Restore-TetraBackup -Category General -BackupId $backupId -Confirm:$false
                $rollbackOk=[bool](Get-TetraExecutionPropertyValue $rb 'Success' $false)
            }
            if(-not $rollbackOk){$rollbackMessage='Rollback provider did not report success.'}
        }catch{$rollbackOk=$false;$rollbackMessage=$_.Exception.Message}
        if($rollbackOk){$results.Add((New-TetraExecutionResult -Item $item -State 'RolledBack' -Message "Execution failed and backup was restored successfully. Failure: $failureMessage" -Preflight $preflight -BackupId $backupId -BackupCreated $true -RollbackAttempted $true -RollbackSucceeded $true))}
        else{$results.Add((New-TetraExecutionResult -Item $item -State 'RollbackFailed' -Message "Execution failed and rollback also failed. Execution: $failureMessage | Rollback: $rollbackMessage" -Preflight $preflight -BackupId $backupId -BackupCreated $true -RollbackAttempted $true -RollbackSucceeded $false))}
    }

    $completed=(Get-Date).ToUniversalTime();$arr=@($results.ToArray())
    $counts=[PSCustomObject]@{Results=$arr.Count;Preview=@($arr|Where-Object{$_.State-eq'Preview'}).Count;Blocked=@($arr|Where-Object{$_.State-eq'Blocked'}).Count;PreflightFailed=@($arr|Where-Object{$_.State-eq'PreflightFailed'}).Count;WhatIf=@($arr|Where-Object{$_.State-eq'WhatIf'}).Count;ExecutedVerified=@($arr|Where-Object{$_.State-eq'ExecutedVerified'}).Count;ExecutionFailed=@($arr|Where-Object{$_.State-eq'ExecutionFailed'}).Count;RolledBack=@($arr|Where-Object{$_.State-eq'RolledBack'}).Count;RollbackFailed=@($arr|Where-Object{$_.State-eq'RollbackFailed'}).Count}
    return [PSCustomObject]@{RecordType='ExecutionSnapshot';ExecutionRunId=[guid]::NewGuid().ToString();SourceActionPlanId=[string](Get-TetraExecutionPropertyValue $ActionPlan 'ActionPlanId' '');ExecuteRequested=$Execute.IsPresent;StartedUtc=$started.ToString('o');CompletedUtc=$completed.ToString('o');DurationMs=[math]::Round(($completed-$started).TotalMilliseconds,2);Counts=$counts;Results=$arr;MutationAttempted=(@($arr|Where-Object{$_.State-in@('ExecutedVerified','RolledBack','RollbackFailed')}).Count -gt 0)}
}

# Public: Get-TetraExecutionStates, Test-TetraExecutionPreflight, Invoke-TetraExecution
