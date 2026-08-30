#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Duplicate Detection Inventory Engine
.DESCRIPTION
    Detects duplicate-file groups in a read-only manner.

    SAFETY CONTRACT:
        - Never deletes, moves, renames, truncates, or modifies files.
        - Candidate narrowing is size-first.
        - File content is read only for hashing size-matched candidates.
        - No automatic keep/delete choice is made.
        - A duplicate group is reported only when size AND hash match.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-TetraDuplicatePropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function New-TetraDuplicateCandidateRecord {
    param([Parameter(Mandatory=$true)][object]$FileData)
    $path=[string](Get-TetraDuplicatePropertyValue $FileData 'FullName' (Get-TetraDuplicatePropertyValue $FileData 'FullPath' ''))
    $name=[string](Get-TetraDuplicatePropertyValue $FileData 'Name' '')
    $size=0L
    try{$size=[long](Get-TetraDuplicatePropertyValue $FileData 'Length' (Get-TetraDuplicatePropertyValue $FileData 'SizeBytes' 0))}catch{}
    return [PSCustomObject]@{Name=$name;FullPath=$path;SizeBytes=$size;Hash='';HashComputed=$false}
}

function Get-TetraDuplicateHash {
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Candidate,
        [scriptblock]$HashResolver=$null,
        [ValidateSet('SHA256','SHA384','SHA512')][string]$Algorithm='SHA256'
    )
    if($null -ne $HashResolver){
        $resolved=& $HashResolver $Candidate
        if($null -eq $resolved){return ''}
        return ([string]$resolved).Trim().ToUpperInvariant()
    }
    if([string]::IsNullOrWhiteSpace($Candidate.FullPath) -or -not (Test-Path -LiteralPath $Candidate.FullPath -PathType Leaf)){return ''}
    $result=Get-FileHash -LiteralPath $Candidate.FullPath -Algorithm $Algorithm -ErrorAction Stop
    return ([string]$result.Hash).Trim().ToUpperInvariant()
}

function Get-TetraDuplicateInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [AllowEmptyCollection()][object[]]$FileData=$null,
        [AllowEmptyCollection()][string[]]$RootPaths=$null,
        [long]$MinimumSizeBytes=1,
        [int]$MaxFiles=10000,
        [ValidateSet('SHA256','SHA384','SHA512')][string]$Algorithm='SHA256',
        [scriptblock]$HashResolver=$null
    )
    if($MinimumSizeBytes -lt 1){throw 'Get-TetraDuplicateInventory: MinimumSizeBytes must be at least 1.'}
    if($MaxFiles -lt 2){throw 'Get-TetraDuplicateInventory: MaxFiles must be at least 2.'}
    try {
        if($null -eq $FileData){
            if($null -eq $RootPaths -or @($RootPaths).Count -eq 0){throw 'Get-TetraDuplicateInventory: RootPaths must be explicitly supplied for live discovery.'}
            $discovered=[System.Collections.Generic.List[object]]::new()
            foreach($root in @($RootPaths)){
                if([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)){continue}
                foreach($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)){
                    if($file.Length -lt $MinimumSizeBytes){continue}
                    $discovered.Add($file)
                    if($discovered.Count -ge $MaxFiles){break}
                }
                if($discovered.Count -ge $MaxFiles){break}
            }
            $FileData=$discovered.ToArray()
        }

        $candidates=[System.Collections.Generic.List[PSCustomObject]]::new()
        foreach($file in @($FileData)){
            if($null -eq $file){continue}
            $candidate=New-TetraDuplicateCandidateRecord -FileData $file
            if($candidate.SizeBytes -lt $MinimumSizeBytes){continue}
            $candidates.Add($candidate)
            if($candidates.Count -ge $MaxFiles){break}
        }

        $sizeGroups=@($candidates | Group-Object -Property SizeBytes | Where-Object {$_.Count -gt 1})
        $duplicateGroups=[System.Collections.Generic.List[PSCustomObject]]::new()
        $groupNumber=0
        foreach($sizeGroup in $sizeGroups){
            $hashed=[System.Collections.Generic.List[PSCustomObject]]::new()
            foreach($candidate in @($sizeGroup.Group)){
                $hash=Get-TetraDuplicateHash -Candidate $candidate -HashResolver $HashResolver -Algorithm $Algorithm
                if([string]::IsNullOrWhiteSpace($hash)){continue}
                $candidate.Hash=$hash
                $candidate.HashComputed=$true
                $hashed.Add($candidate)
            }
            foreach($hashGroup in @($hashed | Group-Object -Property Hash | Where-Object {$_.Count -gt 1})){
                $groupNumber++
                $paths=@($hashGroup.Group | ForEach-Object {$_.FullPath})
                $size=[long]$hashGroup.Group[0].SizeBytes
                $duplicateGroups.Add([PSCustomObject]@{
                    RecordType='DuplicateGroup';Category='Duplicates';GroupId=("dup-{0:d4}" -f $groupNumber)
                    FileSizeBytes=$size;HashAlgorithm=$Algorithm;Hash=[string]$hashGroup.Name
                    FileCount=$paths.Count;Paths=$paths;PotentialReclaimBytes=($size*($paths.Count-1))
                    KeepPath='';DeletePaths=@();KeepDecisionMade=$false;DeletionApproved=$false
                    EvidenceSource='SizeThenCryptographicHash';ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')
                })
            }
        }
        if(Get-Command Write-TetraLog -ErrorAction SilentlyContinue){try{Write-TetraLog -Level 'Info' -Module 'DuplicateInventoryEngine' -Action 'Inventory' -Target 'ExplicitRoots' -Result 'Success' -Message "Detected $($duplicateGroups.Count) duplicate group(s) using size-first filtering and $Algorithm hashing."|Out-Null}catch{}}
        return $duplicateGroups.ToArray()
    } catch {throw "Get-TetraDuplicateInventory: Failed to detect duplicates - $($_.Exception.Message)"}
}

# Public: Get-TetraDuplicateInventory
