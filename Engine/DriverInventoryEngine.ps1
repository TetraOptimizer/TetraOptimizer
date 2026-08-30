#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Driver Inventory Engine
.DESCRIPTION
    Collects read-only signed Plug and Play driver evidence from Windows.
    It does not install, update, remove, enable, disable, or otherwise mutate drivers.

    Mapping to the Drivers Knowledge Base is deliberately conservative. V1 emits
    Analyzer observations only for driver classes that provide strong category
    evidence (display/network/printer/bluetooth). Generic chipset and virtual-audio
    labels remain inventory evidence until richer classification exists.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TetraDriverPropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function ConvertTo-TetraDriverDate {
    param([AllowNull()][object]$Value)
    if($null -eq $Value){return ''}
    try {
        if($Value -is [datetime]){return $Value.ToUniversalTime().ToString('o')}
        $text=([string]$Value).Trim()
        if([string]::IsNullOrWhiteSpace($text)){return ''}
        $parsed=[datetime]::Parse($text)
        return $parsed.ToUniversalTime().ToString('o')
    } catch { return [string]$Value }
}

function New-TetraDriverInventoryRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$DriverData,[string]$ObservedUtc=((Get-Date).ToUniversalTime().ToString('o')))
    $deviceName=[string](Get-TetraDriverPropertyValue $DriverData 'DeviceName' '')
    $deviceClass=[string](Get-TetraDriverPropertyValue $DriverData 'DeviceClass' '')
    $provider=[string](Get-TetraDriverPropertyValue $DriverData 'DriverProviderName' '')
    $manufacturer=[string](Get-TetraDriverPropertyValue $DriverData 'Manufacturer' '')
    $version=[string](Get-TetraDriverPropertyValue $DriverData 'DriverVersion' '')
    $inf=[string](Get-TetraDriverPropertyValue $DriverData 'InfName' '')
    $deviceId=[string](Get-TetraDriverPropertyValue $DriverData 'DeviceID' '')
    $isSigned=$false
    try{$isSigned=[bool](Get-TetraDriverPropertyValue $DriverData 'IsSigned' $false)}catch{}
    return [PSCustomObject]@{
        RecordType='Driver';Category='Drivers';DeviceName=$deviceName;DeviceClass=$deviceClass
        DriverProvider=$provider;Manufacturer=$manufacturer;DriverVersion=$version
        DriverDate=(ConvertTo-TetraDriverDate (Get-TetraDriverPropertyValue $DriverData 'DriverDate' $null))
        InfName=$inf;DeviceId=$deviceId;IsSigned=$isSigned
        Signer=[string](Get-TetraDriverPropertyValue $DriverData 'Signer' '')
        EvidenceSource='Win32_PnPSignedDriver';EvidenceKey=(if(-not [string]::IsNullOrWhiteSpace($deviceId)){$deviceId}else{"$deviceClass|$deviceName|$inf"})
        ObservedUtc=$ObservedUtc
    }
}

function Get-TetraDriverInventory {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param([AllowEmptyCollection()][object[]]$DriverData=$null)
    try {
        if($null -eq $DriverData){$DriverData=@(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)}
        $utc=(Get-Date).ToUniversalTime().ToString('o')
        $records=[System.Collections.Generic.List[PSCustomObject]]::new()
        foreach($d in @($DriverData)){if($null -eq $d){continue};$records.Add((New-TetraDriverInventoryRecord -DriverData $d -ObservedUtc $utc))}
        if(Get-Command Write-TetraLog -ErrorAction SilentlyContinue){Write-TetraLog -Level 'Info' -Module 'DriverInventoryEngine' -Action 'DriverInventory' -Target 'Win32_PnPSignedDriver' -Result 'Success' -Message "Collected $($records.Count) driver record(s) without modifying system state."|Out-Null}
        return $records.ToArray()
    } catch {
        if(Get-Command Write-TetraLog -ErrorAction SilentlyContinue){Write-TetraLog -Level 'Error' -Module 'DriverInventoryEngine' -Action 'DriverInventory' -Target 'Win32_PnPSignedDriver' -Result 'Failed' -Message $_.Exception.Message|Out-Null}
        throw "Get-TetraDriverInventory: Failed to collect driver inventory - $($_.Exception.Message)"
    }
}

function Get-TetraDriverKnowledgeBaseIdForRecord {
    param([Parameter(Mandatory=$true)][PSCustomObject]$Record)
    $class=([string]$Record.DeviceClass).Trim().ToLowerInvariant()
    switch($class){
        'display' { return 'driver-gpu' }
        'net' { return 'driver-network-adapter' }
        'printer' { return 'driver-printer' }
        'printqueue' { return 'driver-printer' }
        'bluetooth' { return 'driver-bluetooth' }
        default { return '' }
    }
}

function ConvertTo-TetraDriverSystemState {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][PSCustomObject[]]$InventoryRecords)
    if(-not (Get-Command New-TetraSystemStateObservation -ErrorAction SilentlyContinue)){throw 'ConvertTo-TetraDriverSystemState: AnalyzerEngine is not loaded.'}
    $kb=@{};foreach($item in (Get-TetraKnowledgeBaseItems -Category 'Drivers')){$kb[$item.Id]=$item}
    $groups=@{}
    foreach($r in @($InventoryRecords)){
        if($null -eq $r){continue};$id=Get-TetraDriverKnowledgeBaseIdForRecord $r;if([string]::IsNullOrWhiteSpace($id)-or-not $kb.ContainsKey($id)){continue}
        if(-not $groups.ContainsKey($id)){$groups[$id]=[System.Collections.Generic.List[PSCustomObject]]::new()};$groups[$id].Add($r)
    }
    $out=[System.Collections.Generic.List[PSCustomObject]]::new()
    foreach($id in $groups.Keys){
        $g=$groups[$id];$versions=@($g|ForEach-Object{$_.DriverVersion}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}|Select-Object -Unique)
        $state="Observed; Devices=$($g.Count); Versions=$($versions -join ',')"
        $out.Add((New-TetraSystemStateObservation -Category 'Drivers' -KnowledgeBaseId $id -IsInstalled $true -IsActive $true -CurrentState $state -EvidenceSource 'Win32_PnPSignedDriver'))
    }
    return $out.ToArray()
}

# Public: Get-TetraDriverInventory, ConvertTo-TetraDriverSystemState
