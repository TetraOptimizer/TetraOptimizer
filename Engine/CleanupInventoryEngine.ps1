#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Cleanup and Leftovers Inventory Engine
.DESCRIPTION
    Classifies supplied filesystem metadata into cleanup candidates without
    deleting, moving, modifying, hashing, or opening file content.

    V1 deliberately limits live discovery to explicit roots supplied by the caller.
    Classification is evidence-based: temporary/cache location or extension can
    produce a cleanup candidate; age alone remains evidence and never proves a
    file is abandoned or safe to delete.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-TetraCleanupPropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function ConvertTo-TetraCleanupTimestamp {
    param([AllowNull()][object]$Value)
    if($null -eq $Value){return ''}
    try {
        if($Value -is [datetime]){$d=[datetime]$Value}
        else {$d=[datetime]::Parse([string]$Value,[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::RoundtripKind)}
        if($d.Kind -eq [System.DateTimeKind]::Unspecified){$d=[datetime]::SpecifyKind($d,[System.DateTimeKind]::Utc)}
        elseif($d.Kind -eq [System.DateTimeKind]::Local){$d=$d.ToUniversalTime()}
        return $d.ToString('o')
    } catch { return [string]$Value }
}

function Test-TetraCleanupPathEvidence {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){return $false}
    $normalized=$Path.Replace('/','\').ToLowerInvariant()
    return ($normalized -match '\\temp(\\|$)' -or $normalized -match '\\tmp(\\|$)' -or $normalized -match '\\cache(\\|$)' -or $normalized -match '\\caches(\\|$)' -or $normalized -match '\\code cache(\\|$)' -or $normalized -match '\\gpucache(\\|$)')
}

function New-TetraCleanupInventoryRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$FileData,
        [int]$StaleAfterDays=30,
        [datetime]$ReferenceUtc=(Get-Date).ToUniversalTime(),
        [string]$ObservedUtc=((Get-Date).ToUniversalTime().ToString('o'))
    )
    $fullPath=[string](Get-TetraCleanupPropertyValue $FileData 'FullName' (Get-TetraCleanupPropertyValue $FileData 'FullPath' ''))
    $name=[string](Get-TetraCleanupPropertyValue $FileData 'Name' '')
    $extension=[string](Get-TetraCleanupPropertyValue $FileData 'Extension' '')
    $length=0L;try{$length=[long](Get-TetraCleanupPropertyValue $FileData 'Length' (Get-TetraCleanupPropertyValue $FileData 'SizeBytes' 0))}catch{}
    $lastWriteRaw=Get-TetraCleanupPropertyValue $FileData 'LastWriteTimeUtc' (Get-TetraCleanupPropertyValue $FileData 'LastWriteUtc' $null)
    $lastWrite=ConvertTo-TetraCleanupTimestamp $lastWriteRaw
    $ageDays=$null
    if(-not [string]::IsNullOrWhiteSpace($lastWrite)){
        try{$ageDays=[math]::Max(0,[math]::Floor(($ReferenceUtc.ToUniversalTime()-([datetime]::Parse($lastWrite,[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()).TotalDays))}catch{}
    }
    $pathEvidence=Test-TetraCleanupPathEvidence $fullPath
    $extensionEvidence=(@('.tmp','.temp','.dmp','.etl') -contains $extension.ToLowerInvariant())
    $isCandidate=($pathEvidence -or $extensionEvidence)
    $classification='Unknown'
    $reason='Insufficient evidence for cleanup classification.'
    $confidence='Low'
    if($pathEvidence){$classification='TemporaryOrCacheCandidate';$reason='Path is inside a recognized temporary or cache location.';$confidence='High'}
    elseif($extensionEvidence){$classification='TemporaryFileCandidate';$reason="Extension '$extension' is commonly temporary/diagnostic evidence.";$confidence='Medium'}
    elseif($null -ne $ageDays -and $ageDays -ge $StaleAfterDays){$classification='OldFileEvidence';$reason="Last-write age is $ageDays day(s); age alone does not prove the file is unused or safe to delete.";$confidence='Low'}
    return [PSCustomObject]@{
        RecordType='CleanupCandidate';Category='Cleanup';Name=$name;Extension=$extension;FullPath=$fullPath;SizeBytes=$length
        Classification=$classification;IsCleanupCandidate=$isCandidate;Confidence=$confidence;Reason=$reason
        AgeDays=$ageDays;StaleAfterDays=$StaleAfterDays;LastWriteUtc=$lastWrite
        PathEvidence=$pathEvidence;ExtensionEvidence=$extensionEvidence
        SafeToDelete=$false;DeletionApproved=$false;ContentRead=$false;HashComputed=$false
        EvidenceSource='FileSystemMetadata';EvidenceKey=$fullPath;ObservedUtc=$ObservedUtc
    }
}

function Get-TetraCleanupInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [AllowEmptyCollection()][object[]]$FileData=$null,
        [AllowEmptyCollection()][string[]]$RootPaths=$null,
        [int]$StaleAfterDays=30,
        [long]$MinimumSizeBytes=0,
        [int]$MaxFiles=5000,
        [datetime]$ReferenceUtc=(Get-Date).ToUniversalTime()
    )
    if($StaleAfterDays -lt 1){throw 'Get-TetraCleanupInventory: StaleAfterDays must be at least 1.'}
    if($MaxFiles -lt 1){throw 'Get-TetraCleanupInventory: MaxFiles must be at least 1.'}
    try {
        if($null -eq $FileData){
            if($null -eq $RootPaths -or @($RootPaths).Count -eq 0){throw 'Get-TetraCleanupInventory: RootPaths must be explicitly supplied for live discovery.'}
            $items=[System.Collections.Generic.List[object]]::new()
            foreach($root in @($RootPaths)){
                if([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)){continue}
                foreach($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)){
                    if($file.Length -lt $MinimumSizeBytes){continue}
                    $items.Add($file);if($items.Count -ge $MaxFiles){break}
                }
                if($items.Count -ge $MaxFiles){break}
            }
            $FileData=$items.ToArray()
        }
        $utc=(Get-Date).ToUniversalTime().ToString('o')
        $records=[System.Collections.Generic.List[PSCustomObject]]::new()
        foreach($file in @($FileData)){
            if($null -eq $file){continue}
            $size=0L;try{$size=[long](Get-TetraCleanupPropertyValue $file 'Length' (Get-TetraCleanupPropertyValue $file 'SizeBytes' 0))}catch{}
            if($size -lt $MinimumSizeBytes){continue}
            $records.Add((New-TetraCleanupInventoryRecord -FileData $file -StaleAfterDays $StaleAfterDays -ReferenceUtc $ReferenceUtc -ObservedUtc $utc))
            if($records.Count -ge $MaxFiles){break}
        }
        if(Get-Command Write-TetraLog -ErrorAction SilentlyContinue){
            try{Write-TetraLog -Level 'Info' -Module 'CleanupInventoryEngine' -Action 'Inventory' -Target 'ExplicitRoots' -Result 'Success' -Message "Classified $($records.Count) filesystem metadata record(s) without deleting or modifying files."|Out-Null}catch{}
        }
        return $records.ToArray()
    } catch {throw "Get-TetraCleanupInventory: Failed to collect cleanup inventory - $($_.Exception.Message)"}
}

# Public: Get-TetraCleanupInventory
