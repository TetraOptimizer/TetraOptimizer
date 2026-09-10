#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Storage and File Inventory Engine
.DESCRIPTION
    Collects read-only fixed-volume capacity evidence and file metadata for
    explicitly supplied roots. File content is never read or hashed in V1.

    SAFETY CONTRACT:
        - Read-only. Never delete, move, rename, compress, truncate, or modify files.
        - Live volume discovery is safe by default and uses Win32_LogicalDisk.
        - Recursive file discovery occurs only for roots explicitly supplied by caller.
        - File content is never opened; only filesystem metadata is collected.
        - "Large" means size threshold only. It is not a recommendation to delete.
        - Age is evidence only and must not be interpreted as unused without later correlation.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TetraStoragePropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $property=$InputObject.PSObject.Properties[$Name]
    if($null -eq $property -or $null -eq $property.Value){return $DefaultValue}
    return $property.Value
}

function ConvertTo-TetraStorageTimestamp {
    param([AllowNull()][object]$Value)
    if($null -eq $Value){return ''}
    try {
        # FileInfo *Utc properties already represent UTC. Synthetic DateTime values
        # created from date-only literals are Kind=Unspecified; treating those as
        # local time would shift the calendar date on non-UTC machines. Preserve the
        # supplied clock value and mark it UTC instead of applying a timezone offset.
        $dateValue=$null
        if($Value -is [datetime]){$dateValue=[datetime]$Value}
        else {$dateValue=[datetime]::Parse([string]$Value,[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::RoundtripKind)}
        if($dateValue.Kind -eq [System.DateTimeKind]::Unspecified){
            $dateValue=[datetime]::SpecifyKind($dateValue,[System.DateTimeKind]::Utc)
        } elseif($dateValue.Kind -eq [System.DateTimeKind]::Local){
            $dateValue=$dateValue.ToUniversalTime()
        }
        return $dateValue.ToString('o')
    } catch { return [string]$Value }
}

function New-TetraStorageVolumeRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$VolumeData,[string]$ObservedUtc=((Get-Date).ToUniversalTime().ToString('o')))
    $deviceId=[string](Get-TetraStoragePropertyValue $VolumeData 'DeviceID' '')
    $size=0L;$free=0L
    try{$size=[long](Get-TetraStoragePropertyValue $VolumeData 'Size' 0)}catch{}
    try{$free=[long](Get-TetraStoragePropertyValue $VolumeData 'FreeSpace' 0)}catch{}
    $used=[math]::Max(0L,$size-$free)
    $freePercent=0.0
    if($size -gt 0){$freePercent=[math]::Round(($free/[double]$size)*100,2)}
    return [PSCustomObject]@{
        RecordType='StorageVolume';Category='Storage';DeviceId=$deviceId
        VolumeName=[string](Get-TetraStoragePropertyValue $VolumeData 'VolumeName' '')
        FileSystem=[string](Get-TetraStoragePropertyValue $VolumeData 'FileSystem' '')
        SizeBytes=$size;FreeBytes=$free;UsedBytes=$used;FreePercent=$freePercent
        DriveType=[int](Get-TetraStoragePropertyValue $VolumeData 'DriveType' 0)
        EvidenceSource='Win32_LogicalDisk';EvidenceKey="DeviceId=$deviceId";ObservedUtc=$ObservedUtc
    }
}

function Get-TetraStorageVolumeInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param([AllowEmptyCollection()][object[]]$VolumeData=$null)
    try {
        if($null -eq $VolumeData){$VolumeData=@(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)}
        $utc=(Get-Date).ToUniversalTime().ToString('o')
        $records=[System.Collections.Generic.List[PSCustomObject]]::new()
        foreach($volume in @($VolumeData)){
            if($null -eq $volume){continue}
            $driveType=0;try{$driveType=[int](Get-TetraStoragePropertyValue $volume 'DriveType' 0)}catch{}
            if($driveType -ne 3){continue}
            $records.Add((New-TetraStorageVolumeRecord -VolumeData $volume -ObservedUtc $utc))
        }
        if(Get-Command Write-TetraLog -ErrorAction SilentlyContinue){Write-TetraLog -Level 'Info' -Module 'StorageInventoryEngine' -Action 'VolumeInventory' -Target 'Win32_LogicalDisk' -Result 'Success' -Message "Collected $($records.Count) fixed-volume record(s) without modifying system state."|Out-Null}
        return $records.ToArray()
    } catch { throw "Get-TetraStorageVolumeInventory: Failed to collect volume inventory - $($_.Exception.Message)" }
}

function New-TetraFileInventoryRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$FileData,[long]$MinimumLargeFileBytes=1073741824,[string]$ObservedUtc=((Get-Date).ToUniversalTime().ToString('o')))
    $length=0L;try{$length=[long](Get-TetraStoragePropertyValue $FileData 'Length' 0)}catch{}
    $fullName=[string](Get-TetraStoragePropertyValue $FileData 'FullName' '')
    $name=[string](Get-TetraStoragePropertyValue $FileData 'Name' '')
    $extension=[string](Get-TetraStoragePropertyValue $FileData 'Extension' '')
    $directoryName=[string](Get-TetraStoragePropertyValue $FileData 'DirectoryName' '')
    return [PSCustomObject]@{
        RecordType='FileMetadata';Category='Files';Name=$name;Extension=$extension
        FullPath=$fullName;DirectoryPath=$directoryName;SizeBytes=$length
        IsLarge=($length -ge $MinimumLargeFileBytes);LargeFileThresholdBytes=$MinimumLargeFileBytes
        CreatedUtc=(ConvertTo-TetraStorageTimestamp (Get-TetraStoragePropertyValue $FileData 'CreationTimeUtc' $null))
        LastWriteUtc=(ConvertTo-TetraStorageTimestamp (Get-TetraStoragePropertyValue $FileData 'LastWriteTimeUtc' $null))
        LastAccessUtc=(ConvertTo-TetraStorageTimestamp (Get-TetraStoragePropertyValue $FileData 'LastAccessTimeUtc' $null))
        ContentRead=$false;HashComputed=$false;EvidenceSource='FileSystemMetadata'
        EvidenceKey=$fullName;ObservedUtc=$ObservedUtc
    }
}

function Get-TetraFileInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory=$false)][AllowEmptyCollection()][object[]]$FileData=$null,
        [Parameter(Mandatory=$false)][AllowEmptyCollection()][string[]]$RootPaths=$null,
        [Parameter(Mandatory=$false)][long]$MinimumSizeBytes=0,
        [Parameter(Mandatory=$false)][long]$MinimumLargeFileBytes=1073741824,
        [Parameter(Mandatory=$false)][int]$MaxFiles=5000
    )
    if($MaxFiles -lt 1){throw 'Get-TetraFileInventory: MaxFiles must be at least 1.'}
    try {
        if($null -eq $FileData){
            if($null -eq $RootPaths -or @($RootPaths).Count -eq 0){throw 'Get-TetraFileInventory: RootPaths must be explicitly supplied for live file discovery.'}
            $discovered=[System.Collections.Generic.List[object]]::new()
            foreach($root in @($RootPaths)){
                if([string]::IsNullOrWhiteSpace($root)){continue}
                if(-not (Test-Path -LiteralPath $root -PathType Container)){continue}
                foreach($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)){
                    if($file.Length -lt $MinimumSizeBytes){continue}
                    $discovered.Add($file)
                    if($discovered.Count -ge $MaxFiles){break}
                }
                if($discovered.Count -ge $MaxFiles){break}
            }
            $FileData=$discovered.ToArray()
        }
        $utc=(Get-Date).ToUniversalTime().ToString('o')
        $records=[System.Collections.Generic.List[PSCustomObject]]::new()
        foreach($file in @($FileData)){
            if($null -eq $file){continue}
            $length=0L;try{$length=[long](Get-TetraStoragePropertyValue $file 'Length' 0)}catch{}
            if($length -lt $MinimumSizeBytes){continue}
            $records.Add((New-TetraFileInventoryRecord -FileData $file -MinimumLargeFileBytes $MinimumLargeFileBytes -ObservedUtc $utc))
            if($records.Count -ge $MaxFiles){break}
        }
        if(Get-Command Write-TetraLog -ErrorAction SilentlyContinue){Write-TetraLog -Level 'Info' -Module 'StorageInventoryEngine' -Action 'FileInventory' -Target 'ExplicitRoots' -Result 'Success' -Message "Collected $($records.Count) file metadata record(s); no file content was read."|Out-Null}
        return $records.ToArray()
    } catch { throw "Get-TetraFileInventory: Failed to collect file inventory - $($_.Exception.Message)" }
}

# Public: Get-TetraStorageVolumeInventory, Get-TetraFileInventory
